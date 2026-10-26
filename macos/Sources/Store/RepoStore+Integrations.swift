import SwiftUI
import AppKit

// MARK: - 워크트리

extension RepoStore {
    /// 지금 열린 곳이 아닌 다른 워크트리가 이 브랜치를 쓰고 있으면 그 워크트리
    func worktree(using branch: String) -> Worktree? {
        worktrees.first { $0.branch == branch && $0.path != url?.path }
    }

    /// 기본 위치: <저장소 상위>/<저장소 이름>-worktrees/<브랜치>
    func defaultWorktreePath(for branch: String) -> String {
        guard let url else { return "" }
        let safe = branch.replacingOccurrences(of: "/", with: "-")
        return url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent)-worktrees", isDirectory: true)
            .appendingPathComponent(safe, isDirectory: true).path
    }

    func addWorktree(path: String, branch: String, createNew: Bool, start: String?, launchClaude: Bool, task: String) async {
        var args = ["worktree", "add"]
        if createNew {
            args += ["-b", branch, path] + (start.map { [$0] } ?? [])
        } else {
            args += [path, branch]
        }
        guard await run(String(localized: "Creating worktree…"), args) else { return }
        if launchClaude { startAgent(in: path, task: task) }
    }

    /// Shows another worktree of this repository in this tab, like GitKraken (a tab already showing it comes forward instead).
    /// Terminals stay; the newest one opened in that worktree is selected.
    func switchWorktree(to path: String) async {
        let target = URL(fileURLWithPath: path, isDirectory: true)
        let key = { (p: String) in URL(fileURLWithPath: p).resolvingSymlinksInPath().standardizedFileURL.path }
        guard key(path) != url.map({ key($0.path) }), !Workspace.shared.bringForward(showing: target, except: self) else { return }
        await openInPlace(target, quick: true)
        // a worktree may sit inside another one, so the longest matching path owns the terminal
        let roots = worktrees.map { key($0.path) }
        func owner(_ dir: String) -> String? {
            let d = key(dir)
            return roots.filter { d == $0 || d.hasPrefix($0 + "/") }.max { $0.count < $1.count }
        }
        if let s = terminals.last(where: { owner($0.directory) == key(path) }) { selectTerminal(s) }
    }

    func confirmRemove(_ w: Worktree, force: Bool = false) {
        confirm = ConfirmRequest(title: String(localized: "Remove worktree '\(w.name)'?"),
                                 message: force
                                    ? String(localized: "\(w.path)\nUncommitted changes are deleted too.")
                                    : String(localized: "\(w.path)\nThe folder is deleted; the branch and commits stay. git refuses if there are uncommitted changes."),
                                 actionTitle: force ? String(localized: "Force remove") : String(localized: "Remove")) { [weak self] in
            await self?.run(String(localized: "Removing worktree…"), ["worktree", "remove"] + (force ? ["--force"] : []) + [w.path])
        }
    }

    func pruneWorktrees() async {
        await run(String(localized: "Pruning worktrees…"), ["worktree", "prune"])
    }

    /// 코딩 에이전트(Claude Code·Codex·Gemini CLI)를 아래 터미널(설정에 따라 Terminal 앱)에서 시작
    func startAgent(in path: String, task: String = "", permissionMode: String? = nil, kind: AgentKind? = nil) {
        let center = AgentCenter.shared
        do { try center.start(kind ?? center.defaultKind, in: path, task: task, permissionMode: permissionMode, host: self) } catch { errorMessage = describe(error) }
    }

    /// 워크트리마다 변경 파일 수와 원격 대비 ↑↓ (에이전트 패널 카드), and other worktrees' changes for their graph rows
    func refreshWorktreeStats() async {
        guard let url else { return }
        let here = url.path
        let list = worktrees.filter { !$0.prunable }
        var stats: [String: WorktreeStats] = [:]
        var status: [String: WorkingStatus] = [:]
        for w in list where Self.samePath(w.path, here) { stats[w.path] = WorktreeStats(self.status) }
        await withTaskGroup(of: (String, WorkingStatus?).self) { group in
            for w in list where !Self.samePath(w.path, here) {
                group.addTask {
                    let r = try? await Git.run(["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=normal"],
                                               in: URL(fileURLWithPath: w.path, isDirectory: true))
                    return (w.path, r.map { Parsers.status($0.data) })
                }
            }
            for await (path, st) in group {
                guard let st else { continue }
                status[path] = st
                stats[path] = WorktreeStats(st)
            }
        }
        guard self.url?.path == here else { return }
        if stats != worktreeStats { worktreeStats = stats }
        if status != worktreeStatus {
            worktreeStatus = status
            // a worktree gained or lost its changes (or moved its HEAD): redraw the graph with its row
            if let drawn = drawnPendingKey, drawn != Self.pendingKey(pendingWorktrees(worktrees)) {
                Task { await reload(quiet: true) }
            }
        }
    }
}

// MARK: - GitHub / GitLab

extension RepoStore {
    /// 이 저장소의 PR·MR 에 쓰는 계정(같은 서버에 여럿이면 저장소마다 고른 것)
    var hostingAccount: HostAccount? {
        target.flatMap { AccountStore.shared.account(for: $0, repoPath: url?.path) }
    }

    /// The repository account whose token is still being read or waits for the user to allow keychain access.
    var pendingCredentialAccount: HostAccount? {
        hostingAccount.flatMap { AccountStore.shared.awaitsAccess($0) ? $0 : nil }
    }

    /// The list state for an account whose token could not be read: still answering, needs approval, or holds no token.
    func credentialLoadState(for account: HostAccount) -> LoadState {
        switch AccountStore.shared.credentialState(for: account) {
        case .loading: return .loading
        case .authorizationRequired: return .authorizationRequired
        case .ready, .unavailable: return .needsAccount
        }
    }

    /// 첫 계정을 연결한 직후에도 SSH 별칭을 다시 판별한다. 전체 그래프는 다시 읽지 않는다.
    func refreshHostingAccount() async {
        let accounts = AccountStore.shared
        let next = Hosting.target(remotes: remotes, urls: remoteURLs,
                                  gitlabHosts: accounts.accounts(for: .gitlab).map(\.host), sshAliases: accounts.sshHostAliases)
        if next != target {
            target = next
            resetCI()
            if let next, next.provider == .github { AvatarStore.shared.noteGitHubRepo(next.path) }
        }
        await loadPullRequests()
        await refreshCIBadges()
    }

    /// 사용자가 눌렀을 때: 이미 연결한 계정이 이 저장소 서버에도 통하는지 직접 확인
    func tryExistingAccounts() async {
        guard let t = target else { return }
        if await AccountStore.shared.discoverAlias(for: t, sameAddressOnly: false) == nil {
            errorMessage = String(localized: "The connected \(t.provider.title) account can't access \(t.host). Add an account with a token for this server.")
        } else {
            await loadPullRequests()
        }
    }

    func useAccount(_ a: HostAccount) {
        guard let path = url?.path else { return }
        AccountStore.shared.setPreferred(a, for: path)
        collaboration.reset()
        reviewLoadID = UUID(); reviewActionID = nil; reviewBusy = false; review = nil
        Task { await loadPullRequests() }
    }

    func loadPullRequests(append: Bool = false) async {
        let state = collaboration, context = collaboration.contextID, loadID = UUID(), repoURL = url
        state.listID = loadID
        guard let t = target else { pullRequests = []; prState = .idle; return }
        let current = { self.url == repoURL && self.target == t && state.contextID == context && state.listID == loadID }
        let accounts = AccountStore.shared
        if hostingAccount == nil, !accounts.accounts(for: t.provider).isEmpty { await accounts.discoverAlias(for: t, sameAddressOnly: true) }
        guard current() else { return }
        guard let acct = hostingAccount else {
            if t.provider == .gitlab { accounts.suggestedGitLabServer = "https://\(t.host)" }
            pullRequests = []; prState = .needsAccount; return
        }
        // The keychain may still be asking the user; that is loading, not a missing account.
        prState = .loading
        let token = await accounts.loadToken(for: acct)
        guard current() else { return }
        guard let token else { pullRequests = []; prState = credentialLoadState(for: acct); return }
        var query = state.query; query.page = append ? query.page + 1 : 1
        do {
            let (items, more, warning) = try await CollaborationAPI.requests(ReviewAccess(target: t, token: token, apiBase: acct.apiBase, me: acct.username, isCurrent: current), query)
            guard current() else { return }
            pullRequests = append ? pullRequests + items.filter { item in !pullRequests.contains(where: { $0.number == item.number }) } : items
            state.query = query; state.more = more; state.warning = warning; prState = .loaded
        } catch { if current() { prState = .failed(describe(error)) } }
    }

    /// PR 브랜치 체크아웃: 같은 저장소 브랜치면 추적 브랜치로, 포크면 pr/번호 로컬 브랜치로 가져온다.
    func checkoutPullRequest(_ pr: PullRequest) async {
        guard let t = target else { return }
        let remoteName = "\(t.remote)/\(pr.source)"
        if !pr.fromFork {
            if remoteBranches.first(where: { $0.name == remoteName }) == nil {
                guard await run(String(localized: "Fetching…"), ["fetch", t.remote, pr.source], network: true) else { return }
            }
            if let b = remoteBranches.first(where: { $0.name == remoteName }) {
                await checkout(b)
                return
            }
        }
        let ref = t.provider == .github ? "refs/pull/\(pr.number)/head" : "refs/merge-requests/\(pr.number)/head"
        let local = "\(t.provider.requestShort.lowercased())/\(pr.number)"
        if headBranch == local {
            await run(String(localized: "Fetching…"), ["pull", "--ff-only", t.remote, ref], network: true)
        } else if await run(String(localized: "Fetching…"), ["fetch", t.remote, "+\(ref):refs/heads/\(local)"], network: true) {
            await run(String(localized: "Checking out…"), ["switch", local])
        }
    }

    /// PR 대상 브랜치 후보: 원격 브랜치 이름(원격 접두사 제외)
    func pullRequestBaseCandidates() -> [String] {
        guard let t = target else { return [] }
        return remoteBranches.filter { $0.remote == t.remote && $0.shortName != headBranch }.map(\.shortName)
    }

    func defaultBaseBranch() async -> String? {
        let candidates = pullRequestBaseCandidates()
        if let t = target, let acct = hostingAccount, let token = AccountStore.shared.token(for: acct),
           let b = try? await Hosting.defaultBranch(t, token: token, apiBase: acct.apiBase),
           candidates.contains(b) {
            return b
        }
        return ["main", "master", "develop"].first { candidates.contains($0) } ?? candidates.first
    }

    func createPullRequest(title: String, body: String, base: String, draft: Bool) async {
        guard let t = target, let branch = headBranch, let originalURL = url, busy == nil else { return }
        let workflow = UUID()
        pullRequestWorkflowID = workflow
        let current = { self.pullRequestWorkflowID == workflow && self.url == originalURL && self.target == t }
        let originalHead = headHash
        newPullRequestDraft = NewPullRequestDraft(branch: branch, title: title, body: body, base: base, draft: draft)
        guard let acct = hostingAccount, let token = AccountStore.shared.token(for: acct) else {
            errorMessage = String(localized: "Connect a \(t.provider.title) (\(t.host)) account first (Settings > Accounts).")
            return
        }
        guard await validatePullRequestPushTarget(t, in: originalURL, account: acct, workflow: workflow), current() else { return }
        // PR 서버와 다른 pushRemote가 설정되어 있어도, 검토한 PR 원격에만 게시한다.
        guard await requestPushReview(branch: branch, remoteOverride: t.remote) else { return }
        guard current() else { return }
        guard headBranch == branch, headHash == originalHead, hostingAccount?.id == acct.id, busy == nil else {
            errorMessage = String(localized: "The repository or branch changed. Review the pull request again; your draft has been kept.")
            return
        }
        guard await validatePullRequestPushTarget(t, in: originalURL, account: acct, workflow: workflow), current() else { return }
        busy = String(localized: "Creating \(t.provider.requestShort)…")
        defer { if current() { busy = nil } }
        do {
            let pr = try await Hosting.createPullRequest(t, token: token, apiBase: acct.apiBase,
                                                         title: title, body: body, source: branch, target: base, draft: draft)
            guard current() else { return }
            newPullRequestDraft = nil
            await loadPullRequests()
            guard current() else { return }
            select(.pullRequest(pr.number))
            if let u = URL(string: pr.url) { NSWorkspace.shared.open(u) }
        } catch {
            if current() { errorMessage = describe(error) }
        }
    }
}

extension RepoStore {
    /// 같은 remote도 fetch와 push가 다른 저장소일 수 있으므로 PR 게시 전에 실제 주소를 확인한다.
    private func validatePullRequestPushTarget(_ request: RepoTarget, in repo: URL, account: HostAccount, workflow: UUID) async -> Bool {
        do {
            let urls = try await Git.run(["remote", "get-url", "--push", "--all", request.remote], in: repo).output
                .split(separator: "\n").map(String.init)
            guard url == repo, pullRequestWorkflowID == workflow else { return false }
            if urls.count == 1, let destination = Hosting.parseRemote(urls[0]), destination.path == request.path {
                if destination.host == request.host { return true }
                let aliasTarget = RepoTarget(provider: request.provider, remote: request.remote, host: destination.host, path: destination.path)
                if AccountStore.shared.account(for: aliasTarget, repoPath: repo.path)?.id == account.id { return true }
            }
            errorMessage = String(localized: "The push URL points to a different repository than this pull request. Check the remote configuration; your draft has been kept.")
        } catch {
            if url == repo, pullRequestWorkflowID == workflow { errorMessage = PushReview.displayURL(describe(error)) }
        }
        return false
    }
}

// MARK: - Claude

extension RepoStore {
    func generateCommitMessage() async {
        guard let url, aiWorking == nil else { return }
        aiWorking = String(localized: "\(AIStore.shared.short(for: .commit)) is writing the commit message…")
        aiNotice = nil
        defer { aiWorking = nil }
        do {
            let diff = try await Git.run(["diff", "--cached", "--no-ext-diff", "-M", "--stat", "--patch"], in: url).output
            guard !diff.trimmed.isEmpty else {
                errorMessage = String(localized: "No staged changes. Stage files first.")
                return
            }
            let recent = (try? await Git.run(["log", "-15", "--format=%s"], in: url).output.trimmed) ?? ""
            let clipped = AIPrompts.clip(diff)
            let prompt = """
            Branch: \(headBranch ?? "(detached HEAD)")

            Recent commit messages (style reference):
            \(recent.isEmpty ? "(none)" : recent)

            Staged changes:
            \(clipped.text)
            """
            let text = try await AIStore.shared.write(.commit, base: AIPrompts.commit, prompt: prompt, effort: "low")
            let parts = AIPrompts.split(text)
            summary = parts.0
            message = parts.1
            if clipped.omitted > 0 { aiNotice = String(localized: "The diff was long, so only the beginning was sent to \(AIStore.shared.short(for: .commit)) (\(clipped.omitted / 1000)K characters omitted).") }
        } catch {
            errorMessage = describe(error)
        }
    }

    func explainCommit(_ sha: String) async {
        guard let url, !explaining.contains(sha) else { return }
        explaining.insert(sha)
        defer { explaining.remove(sha) }
        do {
            let show = try await Git.run(["show", "--stat", "--patch", "--diff-merges=first-parent", "--no-ext-diff",
                                          "--format=commit %H%nAuthor: %an%nDate: %ad%n%n%B", sha], in: url).output
            let clipped = AIPrompts.clip(show)
            var text = try await AIStore.shared.write(.explain, base: AIPrompts.explain, prompt: clipped.text, effort: "medium")
            if clipped.omitted > 0 { text += String(localized: "\n\n(The diff was long, so only the beginning was explained.)") }
            explanations[sha] = text
        } catch {
            errorMessage = describe(error)
        }
    }

    /// PR 제목·본문 초안: base 이후 커밋들과 diff 로 작성
    func draftPullRequest(base: String) async -> (title: String, body: String)? {
        guard let url, let t = target else { return nil }
        let baseRef = remoteBranches.contains { $0.name == "\(t.remote)/\(base)" } ? "\(t.remote)/\(base)" : base
        do {
            let log = try await Git.run(["log", "--format=- %s%n%b", "\(baseRef)..HEAD"], in: url).output
            let diff = try await Git.run(["diff", "--no-ext-diff", "--stat", "--patch", "\(baseRef)...HEAD"], in: url).output
            guard !log.trimmed.isEmpty || !diff.trimmed.isEmpty else {
                errorMessage = String(localized: "No new commits compared with '\(base)'.")
                return nil
            }
            let clipped = AIPrompts.clip(diff)
            let prompt = """
            Branch \(headBranch ?? "") into \(base).

            Commits:
            \(log.trimmed)

            Diff:
            \(clipped.text)
            """
            let text = try await AIStore.shared.write(.pullRequest, base: AIPrompts.pullRequest, prompt: prompt, effort: "low")
            let parts = AIPrompts.split(text)
            return (parts.0, parts.1)
        } catch {
            errorMessage = describe(error)
            return nil
        }
    }
}

// MARK: - 나눠서 커밋: AI 가 변경 파일을 주요 내용별로 묶고, 확인한 뒤 차례로 커밋한다

struct SplitGroup: Identifiable, Hashable {
    let id = UUID()
    var message: String
    var files: [String]
}

extension RepoStore {
    /// 나눌 수 있는 변경(충돌 파일 제외, 스테이지 여부 상관없이)
    var splittableChanges: [FileChange] {
        var seen = Set<String>()
        return (status.staged + status.unstaged).filter { seen.insert($0.path).inserted }
    }

    func planSplit() async {
        guard let url, aiWorking == nil else { return }
        let changes = splittableChanges
        guard changes.count >= 2 else { errorMessage = String(localized: "Splitting needs changes in at least two files."); return }
        guard status.conflicted.isEmpty else { errorMessage = String(localized: "Resolve the conflicts first."); return }
        let ai = AIStore.shared
        aiWorking = String(localized: "\(ai.short(for: .commit)) is splitting the changes by topic…")
        aiNotice = nil
        defer { aiWorking = nil }
        do {
            // 스테이지 여부와 상관없이 HEAD 와 비교한 변경 + 새 파일 내용
            let tracked = try await Git.run(headHash != nil ? ["diff", "HEAD", "--no-ext-diff", "-M", "--stat", "--patch"]
                                                            : ["diff", "--cached", "--no-ext-diff", "--stat", "--patch"], in: url).output
            var newFiles = ""
            for c in changes.filter({ $0.kind == .untracked }).prefix(40) {
                let data = (try? FileHandle(forReadingFrom: url.appendingPathComponent(c.path)).readData(ofLength: 6000)) ?? Data()
                let text = data.contains(0) ? "(binary)" : String(decoding: data, as: UTF8.self)
                newFiles += "\n=== \(c.path) (new file) ===\n\(text)\n"
            }
            let recent = (try? await Git.run(["log", "-15", "--format=%s"], in: url).output.trimmed) ?? ""
            let list = changes.map { c in "- \(c.path)" + (c.oldPath.map { " (renamed from \($0))" } ?? "") + " [\(c.kind)]" }.joined(separator: "\n")
            let clipped = AIPrompts.clip(tracked + newFiles, limit: 300_000)
            let prompt = """
            Branch: \(headBranch ?? "(detached HEAD)")

            Recent commit messages (style reference):
            \(recent.isEmpty ? "(none)" : recent)

            Changed files (use these exact paths):
            \(list)

            Changes:
            \(clipped.text)
            """
            let text = try await ai.write(.commit, base: AIPrompts.split, prompt: prompt, effort: "medium")
            splitPlan = try Self.parseSplitPlan(text, changes: changes)
            if clipped.omitted > 0 { aiNotice = String(localized: "The diff was long, so only the beginning was used for splitting (\(clipped.omitted / 1000)K characters omitted).") }
            sheet = .splitCommits
        } catch {
            errorMessage = describe(error)
        }
    }

    /// AI 의 JSON 답을 계획으로. 모르는 경로는 버리고, 빠진 파일은 마지막 묶음으로 모은다.
    static func parseSplitPlan(_ text: String, changes: [FileChange]) throws -> [SplitGroup] {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let obj = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any] else {
            throw AIError.failed("AI", String(localized: "Couldn't read the split result (not JSON). Please try again."))
        }
        var known: [String: String] = [:]
        for c in changes {
            known[c.path] = c.path
            if let o = c.oldPath { known[o] = c.path }
        }
        var used = Set<String>()
        var groups: [SplitGroup] = []
        for c in obj["commits"] as? [[String: Any]] ?? [] {
            var files: [String] = []
            for f in c["files"] as? [String] ?? [] {
                var key = f.replacingOccurrences(of: "\\", with: "/")
                if key.hasPrefix("./") { key.removeFirst(2) }
                if let p = known[key], used.insert(p).inserted { files.append(p) }
            }
            if !files.isEmpty { groups.append(SplitGroup(message: (c["message"] as? String ?? "").trimmed, files: files)) }
        }
        let rest = changes.map(\.path).filter { !used.contains($0) }
        if !rest.isEmpty { groups.append(SplitGroup(message: groups.isEmpty ? String(localized: "Chore: update") : "", files: rest)) }
        guard !groups.isEmpty else { throw AIError.failed("AI", String(localized: "Couldn't split the commits.")) }
        return groups
    }

    /// 확인한 계획대로: 인덱스를 비우고 묶음마다 스테이지 → 커밋
    func applySplit(_ groups: [SplitGroup]) async {
        let plan = groups.filter { !$0.files.isEmpty && !$0.message.trimmed.isEmpty }
        guard let url, !plan.isEmpty, busy == nil else { return }
        let byPath = Dictionary(splittableChanges.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        busy = String(localized: "Splitting commits…")
        var done = 0
        do {
            if headHash != nil { try await Git.run(["reset", "-q"], in: url) }
            else { try await Git.run(["rm", "--cached", "-r", "-q", "--ignore-unmatch", "."], in: url) }
            for g in plan {
                busy = String(localized: "Creating commit \(done + 1)/\(plan.count)…")
                let paths = g.files.flatMap { p in byPath[p]?.oldPath.map { [$0, p] } ?? [p] }
                try await Git.run(["add", "-A", "--"] + paths, in: url, env: ["GIT_LITERAL_PATHSPECS": "1"])
                try await Git.run(["commit", "-F", "-"], in: url, input: g.message.trimmed + "\n", timeout: 300)
                done += 1
            }
            summary = ""
            message = ""
            splitPlan = nil
        } catch {
            errorMessage = String(localized: "Committed \(done) of \(plan.count) and stopped.\n\n\(describe(error))")
        }
        busy = nil
        await reload(quiet: true)
    }
}
