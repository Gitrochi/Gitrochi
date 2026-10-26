import Foundation

/// CI/CD 패널: GitLab 파이프라인·GitHub Actions 실행을 보고, 수동 작업 실행·다시 실행·취소·승인
extension RepoStore {
    struct CIAccess {
        let target: RepoTarget
        let token: String
        let apiBase: String
    }

    /// PR·MR 과 같은 계정을 쓴다
    var ciAccess: CIAccess? {
        guard let t = target, let a = hostingAccount, let token = AccountStore.shared.token(for: a) else { return nil }
        return CIAccess(target: t, token: token, apiBase: a.apiBase)
    }

    func resetCI() {
        ciPipelines = []
        ciJobs = [:]
        ciDeployments = [:]
        ciState = .idle
    }

    /// 서버에서의 현재 브랜치 이름(추적 브랜치가 있으면 그 이름)
    var ciCurrentRef: String? {
        guard let b = currentBranch else { return nil }
        if let up = b.upstream, let slash = up.firstIndex(of: "/") { return String(up[up.index(after: slash)...]) }
        return b.name
    }

    /// 실행할 수 있는 브랜치: 이 저장소 원격의 브랜치(현재 브랜치가 맨 앞)
    var ciBranches: [String] {
        guard let t = target else { return [] }
        var names = remoteBranches.filter { $0.remote == t.remote && !$0.shortName.hasSuffix("HEAD") }.map(\.shortName)
        if let cur = ciCurrentRef, let i = names.firstIndex(of: cur) { names.insert(names.remove(at: i), at: 0) }
        return names
    }

    /// 그래프·PR 목록의 CI 표시: 최근 파이프라인만(작업 목록은 읽지 않음). 실행 중인 게 있으면 20초마다 다시.
    func refreshCIBadges() async {
        guard target != nil, hostingAccount != nil else { return }
        await loadCI(silent: true, withJobs: false)
        guard ciPipelines.contains(where: { $0.status.isActive }), ciBadgeTask == nil else { return }
        ciBadgeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard let self, !Task.isCancelled else { return }
                if self.isActive { await self.loadCI(silent: true, withJobs: false) }
                if !self.ciPipelines.contains(where: { $0.status.isActive }) { break }
            }
            self?.ciBadgeTask = nil
        }
    }

    func loadCI(silent: Bool = false, withJobs: Bool = true) async {
        guard let t = target else { resetCI(); return }
        let accounts = AccountStore.shared
        if hostingAccount == nil, !accounts.accounts(for: t.provider).isEmpty {
            await accounts.discoverAlias(for: t, sameAddressOnly: true)
        }
        guard let a = hostingAccount else {
            if t.provider == .gitlab { accounts.suggestedGitLabServer = "https://\(t.host)" }
            ciPipelines = []
            ciState = .needsAccount
            return
        }
        if !silent || ciState != .loaded { ciState = .loading }
        // The keychain may still be asking the user; that is loading, not a missing account.
        let token = await accounts.loadToken(for: a)
        guard target == t else { return }
        guard let token else {
            ciPipelines = []
            ciState = credentialLoadState(for: a)
            return
        }
        let c = CIAccess(target: t, token: token, apiBase: a.apiBase)
        do {
            let list = try await CIAPI.pipelines(t, token: c.token, apiBase: c.apiBase, ref: ciCurrentBranchOnly ? ciCurrentRef : nil)
            guard target == t else { return }
            let before = Dictionary(ciPipelines.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
            ciPipelines = list
            ciState = .loaded
            let ids = Set(list.map(\.id))
            ciJobs = ciJobs.filter { ids.contains($0.key) }
            ciDeployments = ciDeployments.filter { ids.contains($0.key) }
            // 최근 파이프라인은 작업까지 읽어 둔다(수동 실행 대기 ▶ 표시·승인 대기)
            let recent = !withJobs ? [] : t.provider == .gitlab ? Array(list.prefix(5)) : list.filter { $0.status == .waiting }
            for p in recent where ciJobs[p.id] == nil || before[p.id] != p.status || p.status.isActive {
                await loadJobs(p, silent: true)
            }
        } catch {
            guard target == t else { return }
            // 자동 새로 고침이 한 번 실패한 것으로 목록을 지우지 않는다
            if !silent || ciPipelines.isEmpty { ciState = .failed(describe(error)) }
        }
    }

    func loadJobs(_ p: CIPipeline, silent: Bool = false) async {
        guard let c = ciAccess else { return }
        do {
            let jobs = try await CIAPI.jobs(c.target, token: c.token, apiBase: c.apiBase, pipeline: p.id)
            guard target == c.target else { return }
            ciJobs[p.id] = jobs
            let current = ciPipelines.first { $0.id == p.id } ?? p
            if c.target.provider == .github, current.status == .waiting {
                ciDeployments[p.id] = (try? await CIAPI.pendingDeployments(c.target, token: c.token, apiBase: c.apiBase, run: p.id)) ?? []
            } else {
                ciDeployments[p.id] = nil
            }
        } catch {
            if ciJobs[p.id] == nil { ciJobs[p.id] = [] }
            if !silent { errorMessage = ciError(error, c.target.provider) }
        }
    }

    // MARK: 버튼

    func playJob(_ job: CIJob, in p: CIPipeline) {
        confirm = ConfirmRequest(title: String(localized: "Run the '\(job.name)' job?"),
                                 message: String(localized: "\(p.ref) · pipeline #\(p.number)") + (job.stage.isEmpty ? "" : String(localized: " · \(job.stage) stages")),
                                 actionTitle: String(localized: "Run"), destructive: false) { [weak self] in
            await self?.ciAction("job:\(job.id)", refresh: p) { c in
                try await CIAPI.play(c.target, token: c.token, apiBase: c.apiBase, job: job.id)
            }
        }
    }

    func retryJob(_ job: CIJob, in p: CIPipeline) async {
        await ciAction("job:\(job.id)", refresh: p) { c in
            try await CIAPI.retry(c.target, token: c.token, apiBase: c.apiBase, job: job.id)
        }
    }

    func cancelJob(_ job: CIJob, in p: CIPipeline) async {
        await ciAction("job:\(job.id)", refresh: p) { c in
            try await CIAPI.cancel(c.target, token: c.token, apiBase: c.apiBase, job: job.id)
        }
    }

    func retryPipeline(_ p: CIPipeline, failedOnly: Bool) async {
        await ciAction("pipeline:\(p.id)", refresh: p) { c in
            try await CIAPI.retry(c.target, token: c.token, apiBase: c.apiBase, pipeline: p.id, failedOnly: failedOnly)
        }
    }

    func cancelPipeline(_ p: CIPipeline) {
        confirm = ConfirmRequest(title: String(localized: "Cancel pipeline #\(p.number)?"),
                                 message: String(localized: "Running work in \(p.ref) will stop."),
                                 actionTitle: String(localized: "Cancel run")) { [weak self] in
            await self?.ciAction("pipeline:\(p.id)", refresh: p) { c in
                try await CIAPI.cancel(c.target, token: c.token, apiBase: c.apiBase, pipeline: p.id)
            }
        }
    }

    /// GitHub 환경 보호 규칙의 배포 승인·거부
    func reviewDeployment(_ p: CIPipeline, _ deployments: [CIDeployment], approve: Bool) {
        let names = deployments.map(\.environment).joined(separator: ", ")
        confirm = ConfirmRequest(title: approve ? String(localized: "Approve the '\(names)' deployment?") : String(localized: "Reject the '\(names)' deployment?"),
                                 message: "\(p.name) #\(p.number) · \(p.ref)",
                                 actionTitle: approve ? String(localized: "Approve") : String(localized: "Reject"), destructive: !approve) { [weak self] in
            await self?.ciAction("pipeline:\(p.id)", refresh: p) { c in
                try await CIAPI.review(c.target, token: c.token, apiBase: c.apiBase, run: p.id,
                                       environments: deployments.map(\.environmentID), approve: approve)
            }
        }
    }

    /// GitLab: 새 파이프라인
    func runPipeline(ref: String, variables: [(String, String)]) async {
        await ciAction("run", refresh: nil) { c in
            try await CIAPI.runPipeline(c.target, token: c.token, apiBase: c.apiBase, ref: ref, variables: variables)
        }
    }

    /// GitHub: workflow_dispatch 실행(실행 목록에 나타나기까지 몇 초 걸려 한 번 더 읽는다)
    func runWorkflow(_ w: CIWorkflow, ref: String, inputs: [String: String]) async {
        await ciAction("run", refresh: nil) { c in
            try await CIAPI.dispatch(c.target, token: c.token, apiBase: c.apiBase, workflow: w.id, ref: ref, inputs: inputs)
        }
        try? await Task.sleep(for: .seconds(4))
        await loadCI(silent: true)
    }

    func ciWorkflows(ref: String) async throws -> [CIWorkflow] {
        guard let c = ciAccess else { return [] }
        return try await CIAPI.workflows(c.target, token: c.token, apiBase: c.apiBase, ref: ref)
    }

    /// .gitlab-ci.yml 에서 설명이 붙은 변수(파이프라인 실행 화면에 미리 채움)
    func gitlabPipelineVariables() -> [CIInput] {
        guard let url, let text = try? String(contentsOf: url.appendingPathComponent(".gitlab-ci.yml"), encoding: .utf8) else { return [] }
        return MiniYAML.pipelineVariables(text)
    }

    private func ciAction(_ key: String, refresh p: CIPipeline?, _ work: @escaping (CIAccess) async throws -> Void) async {
        guard let c = ciAccess, !ciBusy.contains(key) else { return }
        ciBusy.insert(key)
        defer { ciBusy.remove(key) }
        do {
            try await work(c)
        } catch {
            errorMessage = ciError(error, c.target.provider)
            return
        }
        try? await Task.sleep(for: .milliseconds(700))
        await loadCI(silent: true)
        if let p { await loadJobs(p, silent: true) }
    }

    func ciError(_ error: Error, _ provider: Provider) -> String {
        let base = describe(error)
        guard let h = error as? HostingError, h.status == 403 || h.status == 404 else { return base }
        switch provider {
        case .gitlab:
            return base + String(localized: "\n\nTo run it, your token needs the api scope (read_api is not enough) and you need Developer or higher on the project. Protected branches and environments need those permissions too.")
        case .github:
            return base + String(localized: "\n\nTo run it, your token needs write access to Actions (classic token: repo; fine-grained token: Actions: Read and write). Try reconnecting the account in Settings.")
        }
    }
}
