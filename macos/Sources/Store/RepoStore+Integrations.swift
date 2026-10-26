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

    /// 워크트리마다 변경 파일 수와 원격 대비 ↑↓ (에이전트 패널 카드)
    func refreshWorktreeStats() async {
        let list = worktrees.filter { !$0.prunable }
        var result: [String: WorktreeStats] = [:]
        await withTaskGroup(of: (String, WorktreeStats?).self) { group in
            for w in list {
                group.addTask {
                    let r = try? await Git.run(["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=normal"],
                                               in: URL(fileURLWithPath: w.path, isDirectory: true))
                    return (w.path, r.map { WorktreeStats(Parsers.status($0.data)) })
                }
            }
            for await (path, stats) in group {
                if let stats { result[path] = stats }
            }
        }
        if result != worktreeStats { worktreeStats = result }
    }
}

// MARK: - GitHub / GitLab

extension RepoStore {
    /// 이 저장소의 PR·MR 에 쓰는 계정(같은 서버에 여럿이면 저장소마다 고른 것)
    var hostingAccount: HostAccount? {
        target.flatMap { AccountStore.shared.account(for: $0, repoPath: url?.path) }
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
    }

    func loadPullRequests() async {
        guard let t = target else { pullRequests = []; prState = .idle; return }
        let accounts = AccountStore.shared
        // 연결된 계정 서버의 다른 주소(같은 IP)면 그 계정으로 확인해 이어 쓴다
        if hostingAccount == nil, !accounts.accounts(for: t.provider).isEmpty {
            await accounts.discoverAlias(for: t, sameAddressOnly: true)
        }
        guard let acct = hostingAccount, let token = accounts.token(for: acct) else {
            // 사내 GitLab 이면 설정 화면에 그 서버 주소를 미리 채워 둔다
            if t.provider == .gitlab { accounts.suggestedGitLabServer = "https://\(t.host)" }
            pullRequests = []
            prState = .needsAccount
            return
        }
        prState = .loading
        do {
            let list = try await Hosting.pullRequests(t, token: token, apiBase: acct.apiBase)
            guard target == t else { return }
            pullRequests = list
            prState = .loaded
        } catch {
            guard target == t else { return }
            prState = .failed(describe(error))
        }
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
        guard let t = target, let branch = headBranch else { return }
        guard let acct = hostingAccount, let token = AccountStore.shared.token(for: acct) else {
            errorMessage = String(localized: "Connect a \(t.provider.title) (\(t.host)) account first (Settings > Accounts).")
            return
        }
        // 원격에 브랜치가 없거나 올리지 않은 커밋이 있으면 먼저 push
        if status.upstream == nil {
            guard await run(String(localized: "Pushing…"), ["push", "-u", t.remote, branch], network: true) else { return }
        } else if status.ahead > 0 {
            guard await run(String(localized: "Pushing…"), ["push"], network: true) else { return }
        }
        busy = String(localized: "Creating \(t.provider.requestShort)…")
        defer { busy = nil }
        do {
            let pr = try await Hosting.createPullRequest(t, token: token, apiBase: acct.apiBase,
                                                         title: title, body: body, source: branch, target: base, draft: draft)
            await loadPullRequests()
            select(.pullRequest(pr.number))
            if let u = URL(string: pr.url) { NSWorkspace.shared.open(u) }
        } catch {
            errorMessage = describe(error)
        }
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
