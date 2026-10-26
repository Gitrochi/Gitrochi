import SwiftUI

extension RepoStore {
    /// gitch 가 보는 이 저장소의 계정과 점검을 다시 읽는다. fetch 면 원격을 받아 받을 커밋까지 본다(몇 초).
    func refreshGitch(fetch: Bool = false) async {
        guard let url, Gitch.hasConfig else {
            if gitchStatus != nil { gitchStatus = nil }
            if gitchPreflight != nil { gitchPreflight = nil }
            if !gitchAccounts.isEmpty { gitchAccounts = [] }
            if !gitchProtected.isEmpty { gitchProtected = [] }
            return
        }
        gitchChecking = true
        async let s = Gitch.status(in: url)
        async let p = Gitch.preflight(in: url, fetch: fetch)
        async let a = Gitch.accounts()
        async let b = Git.run(["config", "--get-all", "gitswitch.protect"], in: url, ok: [0, 1])
        let (status, preflight, accounts, protected) = await (s, p, a, try? b)
        gitchChecking = false
        guard self.url == url else { return }
        let managed = status?.inRepo == true ? status : nil
        let checks = managed == nil ? nil : preflight
        let branches = Set((protected?.output ?? "").split(separator: "\n").map(String.init))
        // 같은 값이면 다시 넣지 않는다(화면을 다시 그리지 않게)
        if gitchStatus != managed { gitchStatus = managed }
        if gitchPreflight != checks { gitchPreflight = checks }
        if gitchAccounts != accounts { gitchAccounts = accounts }
        if gitchProtected != branches { gitchProtected = branches }
    }

    /// gitch 명령으로 이 저장소를 바꾸고 작성자·그래프·gitch 상태를 다시 읽는다. 실패하면 gitch 가 낸 문구를 보여 준다.
    /// gitch 는 브랜치를 옮기기 전에 스스로 백업하므로(gitch rescue) 앱의 되돌리기 기록에는 넣지 않는다.
    @discardableResult
    func runGitch(_ args: [String]) async -> Bool {
        guard let url, busy == nil else { return false }
        busy = String(localized: "Running gitch…")
        defer { busy = nil }
        var ok = true
        do {
            try await Gitch.run(args, in: url, timeout: 900)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            ok = false
        }
        await loadRepoInfo(in: url)
        await reload(quiet: !ok)
        await refreshGitch()
        return ok
    }

    /// 이 저장소를 다른 gitch 계정으로(gitch use): 작성자·원격 주소·잠금이 바뀐다
    func useGitchAccount(_ id: String) async { await runGitch(["use", id]) }

    /// 계정 잠금 풀기(작성자 설정은 그대로)
    func unlockGitch() async { await runGitch(["unlock", "--yes"]) }

    /// gitch 검사(작성자·비밀값·push)에서 빼거나 되돌리기
    func setGitchIgnored(_ ignored: Bool) async { await runGitch(ignored ? ["ignore", "--yes"] : ["ignore", "--off"]) }

    /// 직접 push 를 막는 브랜치로(다른 브랜치에서 PR 로만 합치게)
    func setGitchProtected(_ branch: String, _ protected: Bool) async {
        await runGitch(protected ? ["protect", branch] : ["protect", "--rm", branch])
    }

    /// 기본 브랜치 최신을 따라가기(gitch up): push 전이면 rebase, push 한 브랜치면 merge
    func gitchUp() async { await runGitch(["up"]) }

    /// 포크를 원본(upstream) 최신으로(gitch sync)
    func gitchSync() async { await runGitch(["sync"]) }

    /// push 안 한 커밋 중 작성자가 이 저장소 계정이 아닌 것. 고칠 것이 있으면 needsFix 와 gitch 가 낸 목록
    func gitchFixPreview() async -> (needsFix: Bool, text: String)? {
        guard let url else { return nil }
        do {
            let r = try await Gitch.runRaw(["fix"], in: url)
            // 2 = 고칠 커밋이 있어 확인이 필요(목록은 출력에), 0 = 고칠 것 없음
            if r.status == 2 { return (true, r.output.replacingOccurrences(of: "\n확인이 필요합니다.*", with: "", options: .regularExpression)) }
            if r.status == 0 { return (false, r.output) }
            errorMessage = r.output
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        return nil
    }

    func gitchFix() async { await runGitch(["fix", "--yes"]) }

    func gitchBackups() async -> [Gitch.Backup] {
        guard let url else { return [] }
        return await Gitch.backups(in: url)
    }

    /// 백업으로 되돌리기(지금 상태도 먼저 백업) 또는 새 브랜치로 꺼내기. 번호는 실행 직전에 다시 찾는다(그 사이 백업이 늘 수 있어서).
    @discardableResult
    func gitchRestore(_ backup: Gitch.Backup, toBranch branch: String?) async -> Bool {
        guard let index = await gitchBackups().firstIndex(where: { $0.ref == backup.ref }) else {
            errorMessage = String(localized: "That backup no longer exists.")
            return false
        }
        let pick = String(index + 1)
        if let branch { return await runGitch(["rescue", pick, "--branch", branch]) }
        return await runGitch(["rescue", pick, "--restore", "--yes"])
    }

    /// gitch graph 로 만드는 페이지 — 한 번에 하나(그동안 구조 그래프 메뉴의 항목을 끈다)
    enum GraphJob: Equatable {
        case draw(Gitch.GraphRelation)
        case diff(Gitch.GraphRelation)
        case checkPage
    }

    /// 의존 규칙 검사 창이 보여 줄 것
    enum GraphCheckState {
        case running
        /// rules: 규칙 줄 수(0 이면 --init 이 만든 예시 그대로 — 모두 주석)
        case done(Gitch.GraphCheck, rules: Int)
        case failed(String)
    }

    /// gitch graph 가 페이지를 만드는 동안 툴바에 보일 글(관계 이름까지 넣으면 툴바 버튼이 밀려나서 짧게)
    var graphProgress: String? {
        switch graphJob {
        case .draw?, .checkPage?: return String(localized: "Drawing the structure graph…")
        case .diff?: return String(localized: "Comparing dependencies…")
        case nil: return nil
        }
    }

    /// 구조 그래프(gitch graph)를 html 로 만들어 기본 브라우저로 연다. 실패하면 gitch 가 낸 문구를 보여 준다.
    func openStructureGraph(_ relation: Gitch.GraphRelation, precise: Bool = false) async {
        guard let url, graphJob == nil else { return }
        graphJob = .draw(relation)
        defer { graphJob = nil }
        // 메뉴가 닫히고 브라우저가 뜨기까지 몇 초 걸릴 수 있어 VoiceOver 에 먼저 알린다
        if let text = graphProgress { AccessibilityNotification.Announcement(text).post() }
        do {
            let page = try await Gitch.graph(relation, in: url, precise: precise)
            guard self.url == url else { return }
            if page.nodes == 0 {
                // 빈 페이지를 띄우기보다 gitch 가 찾지 못한 것을 먼저 알린다
                confirm = ConfirmRequest(title: String(localized: "Nothing to draw"),
                                         message: page.hint ?? String(localized: "gitch found nothing to draw for \(relation.title)."),
                                         actionTitle: String(localized: "Open anyway"), destructive: false) { [weak self] in
                    await self?.openGraphPage(page.liveURL ?? page.file)
                }
            } else {
                await openGraphPage(page.liveURL ?? page.file)
            }
        } catch {
            guard self.url == url else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 수정한 파일과 그것을 참조하는 파일을 함께 추려 그린다.
    func openAffectedGraph(base: String? = nil) async {
        guard let url, graphJob == nil else { return }
        graphJob = .draw(.files)
        defer { graphJob = nil }
        do {
            let page = try await Gitch.affectedGraph(base: base, in: url)
            guard self.url == url else { return }
            await openGraphPage(page.liveURL ?? page.file)
        } catch {
            guard self.url == url else { return }
            errorMessage = describe(error)
        }
    }

    /// 이 브랜치에서 바뀐 의존(gitch graph diff)을 html 로 만들어 기본 브라우저로 연다.
    /// base 가 nil 이면 gitch 의 기본값(기본 브랜치와 갈라진 곳), 있으면 그 브랜치 · 태그와 이 브랜치가 갈라진 곳과 비교한다.
    func openGraphDiff(_ relation: Gitch.GraphRelation, base: String? = nil) async {
        guard let url, graphJob == nil else { return }
        graphJob = .diff(relation)
        defer { graphJob = nil }
        if let text = graphProgress { AccessibilityNotification.Announcement(text).post() }
        do {
            let file = try await Gitch.graphDiff(relation, base: base, in: url)
            guard self.url == url else { return }
            await openGraphPage(file)
        } catch {
            guard self.url == url else { return }
            errorMessage = describe(error)
        }
    }

    /// 의존 규칙 검사(gitch graph check): 규칙 파일이 없으면 예시로 만들지 묻고, 있으면 결과 창을 띄우고 검사한다.
    /// 검사가 돌고 있으면(창을 닫았다 바로 다시 연 때) 새로 돌리지 않고 그 결과를 기다린다
    func checkGraphRules() {
        guard let url else { return }
        guard FileManager.default.fileExists(atPath: Gitch.graphRulesFile(in: url).path) else {
            confirm = ConfirmRequest(title: String(localized: "No dependency rules yet"),
                                     message: String(localized: "gitch graph check reads its rules from .gitch/graph.rules in this repository. Create the file with commented-out examples (gitch graph check --init) and open it?"),
                                     actionTitle: String(localized: "Create rules file"), destructive: false) { [weak self] in
                await self?.createGraphRules()
            }
            return
        }
        if case .running? = graphCheck {} else { graphCheck = nil }   // 지난 결과가 잠깐 보이지 않게
        sheet = .graphCheck
        Task { await runGraphCheck() }
    }

    /// 규칙 검사를 (다시) 돌려 결과 창에 넣는다. 위반이 있어 gitch 가 1 로 끝나도 결과다.
    func runGraphCheck() async {
        guard let url else { return }
        if case .running? = graphCheck { return }
        graphCheck = .running
        // 그동안 저장소가 바뀌면 결과를 버리되, 「검사하는 중」으로 남아 다시 검사를 막지 않게 비운다
        do {
            let result = try await Gitch.graphCheck(in: url)
            guard self.url == url else { graphCheck = nil; return }
            graphCheck = .done(result, rules: Gitch.graphRuleCount(in: url))
        } catch {
            guard self.url == url else { graphCheck = nil; return }
            graphCheck = .failed(describe(error))
        }
    }

    /// gitch graph check --init 으로 예시가 든 규칙 파일을 만들고 글 편집기로 연다(예시는 모두 주석이라 고친 뒤에 검사한다)
    func createGraphRules() async {
        guard let url else { return }
        do {
            try await Gitch.graphRulesInit(in: url)
            await openGraphRules()
        } catch {
            errorMessage = describe(error)
        }
    }

    func openGraphRules() async {
        guard let url else { return }
        do {
            try await Launcher.openInTextEditor(Gitch.graphRulesFile(in: url))
        } catch {
            errorMessage = describe(error)
        }
    }

    /// 규칙 위반을 그린 페이지(gitch graph check --format html)를 기본 브라우저로 연다. 결과 창에서 부르므로 실패하면 그 문구를 돌려준다
    func openGraphCheckPage() async -> String? {
        guard let url, graphJob == nil else { return nil }
        graphJob = .checkPage
        defer { graphJob = nil }
        if let text = graphProgress { AccessibilityNotification.Announcement(text).post() }
        do {
            let file = try await Gitch.graphCheckPage(in: url)
            guard self.url == url else { return nil }
            try await Launcher.openInBrowser(file)
            return nil
        } catch {
            return describe(error)
        }
    }

    func openGraphPage(_ file: URL) async {
        do {
            try await Launcher.openInBrowser(file)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
