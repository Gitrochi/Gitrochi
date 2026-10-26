import SwiftUI
import AppKit

/// git 작업: 실행·Fetch·Pull·Push·브랜치·태그·스태시·스테이지·커밋·머지/리베이스
extension RepoStore {
    // MARK: - 작업 실행

    /// git 명령 하나를 실행하고 저장소를 다시 읽는다. 실패하면 git 의 메시지를 그대로 보여 준다.
    /// 전후로 브랜치·태그·HEAD 를 기록해 두어 '되돌리기'로 되돌릴 수 있게 한다(머지·리베이스가 진행 중일 때는 빼고).
    @discardableResult
    func run(_ label: String, _ args: [String], network: Bool = false, input: String? = nil, env: [String: String]? = nil) async -> Bool {
        guard let url, busy == nil else { return false }
        let generation = pushReviewGeneration
        func active() -> Bool { self.url == url && pushReviewGeneration == generation }
        operationNotice = nil
        busy = label
        defer { if active() { busy = nil } }
        do {
            let before = repoState == .clean ? await refSnapshot() : nil
            guard active() else { return false }
            try await Git.run(args, in: url, input: input, timeout: network ? 900 : 300,
                              env: env ?? (network ? AccountStore.shared.gitEnvironment(target: target, repoPath: url.path) : [:]))
            guard active() else { return false }
            let after = before != nil ? await refSnapshot() : nil
            guard active() else { return false }
            if let before, let after { recordUndo(args: args, input: input, before: before, after: after) }
            await reload()
            guard active() else { return false }
            operationNotice = String(localized: "Operation completed")
            return true
        } catch {
            guard active() else { return false }
            if case .pushReview? = sheet { pushReviewError = PushReview.displayURL(describe(error)) }
            else { errorMessage = describe(error) }
            await reload(quiet: true)
            return false
        }
    }

    private var defaultRemote: String? {
        remotes.contains("origin") ? "origin" : remotes.first
    }

    func fetch() async {
        if await run(String(localized: "Fetching…"), ["fetch", "--all", "--prune"], network: true) {
            await loadPullRequests()
            await refreshCIBadges()
        }
    }

    func pull(_ mode: PullMode = .standard) async {
        var args = ["pull"]
        switch mode {
        case .standard: break
        case .fastForward: args.append("--ff-only")
        case .merge: args.append("--no-rebase")
        case .rebase: args.append("--rebase")
        }
        await run(String(localized: "Pulling…"), args, network: true)
    }

    @discardableResult
    func push(force: Bool = false) async -> Bool {
        guard let branch = headBranch, headHash != nil else {
            errorMessage = String(localized: "There's no branch to push. HEAD is detached or there are no commits yet.")
            return false
        }
        return await requestPushReview(branch: branch, force: force)
    }

    @discardableResult
    func pushBranch(_ b: Branch) async -> Bool {
        guard !b.isRemote else { return false }
        return await requestPushReview(branch: b.name)
    }

    func checkout(_ b: Branch) async {
        if !b.isRemote, let w = worktree(using: b.name) {
            confirm = ConfirmRequest(title: String(localized: "'\(b.name)' is in use by another worktree"),
                                     message: String(localized: "\(w.path)\nA branch can be checked out in only one worktree. Open that worktree?"),
                                     actionTitle: String(localized: "Open worktree"), destructive: false) { [weak self] in
                await self?.switchWorktree(to: w.path)
            }
            return
        }
        if b.isRemote {
            let short = b.shortName
            if localBranches.contains(where: { $0.name == short }) {
                await run(String(localized: "Checking out…"), ["switch", short])
            } else {
                await run(String(localized: "Checking out…"), ["switch", "-c", short, "--track", b.name])
            }
        } else if !b.isCurrent {
            await run(String(localized: "Checking out…"), ["switch", b.name])
        }
    }

    func checkoutDetached(_ sha: String) async {
        await run(String(localized: "Checking out…"), ["switch", "--detach", sha])
    }

    func requestNewBranch(from start: String? = nil, label: String? = nil) {
        let s = start ?? headHash ?? "HEAD"
        sheet = .newBranch(start: s, label: label ?? headBranch ?? String(s.prefix(7)))
    }

    func createBranch(_ name: String, at start: String, checkout: Bool) async {
        let args = checkout ? ["switch", "-c", name, start] : ["branch", name, start]
        await run(String(localized: "Creating branch…"), args)
    }

    func confirmDelete(_ b: Branch) {
        if b.isRemote {
            guard let remote = b.remote else { return }
            confirm = ConfirmRequest(title: String(localized: "Delete remote branch '\(b.name)'?"),
                                     message: String(localized: "The branch will be deleted on the \(remote) server. Be careful if others use it too."),
                                     actionTitle: String(localized: "Delete from remote")) { [weak self] in
                await self?.run(String(localized: "Deleting remote branch…"), ["push", remote, "--delete", b.shortName], network: true)
            }
        } else {
            confirm = ConfirmRequest(title: String(localized: "Delete branch '\(b.name)'?"),
                                     message: String(localized: "git refuses to delete a branch with unmerged commits. Use 'Force delete' in that case."),
                                     actionTitle: String(localized: "Delete")) { [weak self] in
                await self?.run(String(localized: "Deleting branch…"), ["branch", "-d", b.name])
            }
        }
    }

    func confirmForceDelete(_ b: Branch) {
        confirm = ConfirmRequest(title: String(localized: "Force delete branch '\(b.name)'?"),
                                 message: String(localized: "Unmerged commits are discarded too."),
                                 actionTitle: String(localized: "Force delete")) { [weak self] in
            await self?.run(String(localized: "Deleting branch…"), ["branch", "-D", b.name])
        }
    }

    func merge(_ name: String) async {
        await run(String(localized: "Merging…"), ["merge", name])
    }

    func rebase(onto name: String) async {
        await run(String(localized: "Rebasing…"), ["rebase", name])
    }

    func cherryPick(_ sha: String) async {
        await run(String(localized: "Cherry-picking…"), ["cherry-pick", sha])
    }

    func revert(_ sha: String) async {
        await run(String(localized: "Reverting…"), ["revert", "--no-edit", sha])
    }

    func reset(to sha: String, mode: ResetMode) {
        let action: @MainActor () async -> Void = { [weak self] in
            await self?.run(String(localized: "Resetting…"), ["reset", "--\(mode.rawValue)", sha])
        }
        if mode == .hard {
            confirm = ConfirmRequest(title: String(localized: "Hard reset to \(String(sha.prefix(7)))?"),
                                     message: String(localized: "Uncommitted changes and later commits are removed from the current branch."),
                                     actionTitle: "Hard reset", action: action)
        } else {
            Task { await action() }
        }
    }

    func createTag(_ name: String, message: String, at sha: String) async {
        let args = message.trimmed.isEmpty ? ["tag", name, sha] : ["tag", "-a", name, "-m", message, sha]
        await run(String(localized: "Creating tag…"), args)
    }

    func deleteTag(_ t: Tag) {
        confirm = ConfirmRequest(title: String(localized: "Delete tag '\(t.name)'?"),
                                 message: String(localized: "Only the local tag is deleted."), actionTitle: String(localized: "Delete")) { [weak self] in
            await self?.run(String(localized: "Deleting tag…"), ["tag", "-d", t.name])
        }
    }

    func pushTag(_ t: Tag) async {
        guard let remote = defaultRemote else { errorMessage = String(localized: "No remote repository."); return }
        await run(String(localized: "Pushing tag…"), ["push", remote, "refs/tags/" + t.name], network: true)
    }

    // MARK: 스태시

    func stash(message: String, includeUntracked: Bool) async {
        var args = ["stash", "push"]
        if includeUntracked { args.append("--include-untracked") }
        if !message.trimmed.isEmpty { args += ["-m", message.trimmed] }
        await run(String(localized: "Stashing…"), args)
    }

    func stashApply(_ s: Stash) async { await run(String(localized: "Applying stash…"), ["stash", "apply", s.ref]) }

    func stashPop(_ s: Stash? = nil) async {
        await run(String(localized: "Popping stash…"), ["stash", "pop"] + (s.map { [$0.ref] } ?? []))
    }

    func stashDrop(_ s: Stash) {
        confirm = ConfirmRequest(title: String(localized: "Discard \(s.ref)?"), message: s.message,
                                 actionTitle: String(localized: "Discard")) { [weak self] in
            await self?.run(String(localized: "Dropping stash…"), ["stash", "drop", s.ref])
        }
    }

    // MARK: 스테이지·커밋

    func stage(_ changes: [FileChange]) async {
        guard !changes.isEmpty else { return }
        await run(String(localized: "Staging…"), ["add", "-A", "--"] + changes.flatMap(\.paths))
    }

    func unstage(_ changes: [FileChange]) async {
        guard !changes.isEmpty else { return }
        let paths = changes.flatMap(\.paths)
        if headHash == nil {
            await run(String(localized: "Unstaging…"), ["rm", "--cached", "-r", "-q", "--"] + paths)
        } else {
            await run(String(localized: "Unstaging…"), ["restore", "--staged", "--"] + paths)
        }
    }

    func stageAll() async { await run(String(localized: "Staging…"), ["add", "-A"]) }

    func unstageAll() async {
        if headHash == nil {
            await run(String(localized: "Unstaging…"), ["rm", "--cached", "-r", "-q", "."])
        } else {
            await run(String(localized: "Unstaging…"), ["reset", "-q"])
        }
    }

    func confirmDiscard(_ c: FileChange) {
        confirm = ConfirmRequest(title: String(localized: "Discard changes to '\(c.fileName)'?"),
                                 message: c.kind == .untracked ? String(localized: "Untracked new files will be deleted.") : String(localized: "Your edits in the working tree will be lost."),
                                 actionTitle: String(localized: "Discard changes")) { [weak self] in
            guard let self, let repository = self.url,
                  await self.preserveDiscardedChanges(paths: c.paths), self.url == repository else { return }
            if c.kind == .untracked {
                await self.run(String(localized: "Discarding changes…"), ["clean", "-f", "-q", "--", c.path])
            } else {
                await self.run(String(localized: "Discarding changes…"), ["restore", "--worktree", "--"] + c.paths)
            }
        }
    }

    func confirmDiscardAll() {
        confirm = ConfirmRequest(title: String(localized: "Discard all changes?"),
                                 message: String(localized: "A local recovery copy is saved before discarding staged, unstaged and untracked changes."),
                                 actionTitle: String(localized: "Discard all")) { [weak self] in
            guard let self, let repository = self.url,
                  await self.preserveDiscardedChanges(paths: nil), self.url == repository else { return }
            if self.headHash != nil {
                guard await self.run(String(localized: "Undoing…"), ["reset", "--hard", "-q"]) else { return }
            } else {
                guard await self.run(String(localized: "Undoing…"), ["read-tree", "--empty"]) else { return }
            }
            await self.run(String(localized: "Cleaning up…"), ["clean", "-fd", "-q"])
        }
    }

    var canCommit: Bool {
        busy == nil && !summary.trimmed.isEmpty
            && (!status.staged.isEmpty || amend || repoState == .merging)
            && status.conflicted.isEmpty
            && !gitchChecking && gitchPreflight?.result != "STOP"
    }

    /// 비활성 버튼 옆에서 현재 필요한 다음 행동을 안내한다. Git 실행 조건은 canCommit 에 유지한다.
    var commitGuidance: String {
        if let busy { return busy }
        if !status.conflicted.isEmpty { return String(localized: "Resolve conflicts before committing.") }
        if gitchChecking { return String(localized: "Checking the Git account and repository…") }
        if gitchPreflight?.result == "STOP" { return String(localized: "Resolve the gitch checks below before committing.") }
        if status.staged.isEmpty && !amend && repoState != .merging {
            return String(localized: "Stage the files you want to include.")
        }
        if summary.trimmed.isEmpty { return String(localized: "Write a summary to enable commit.") }
        return String(localized: "Ready to commit staged changes.")
    }

    func setAmend(_ on: Bool) async {
        amend = on
        guard on, summary.isEmpty, message.isEmpty, let url, headHash != nil,
              let r = try? await Git.run(["log", "-1", "--format=%B"], in: url) else { return }
        let text = r.output.trimmed
        let first = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        summary = first
        message = String(text.dropFirst(first.count)).trimmed
    }

    func commit() async {
        guard canCommit else { return }
        let text = [summary.trimmed, message.trimmed].filter { !$0.isEmpty }.joined(separator: "\n\n")
        var args = ["commit", "-F", "-"]
        if amend { args.append("--amend") }
        if await run(String(localized: "Committing…"), args, input: text + "\n") {
            summary = ""
            message = ""
            amend = false
            mergeMessageFilled = false
        }
    }

    // MARK: 진행 중인 머지·리베이스

    func abortOperation() {
        let args: [String]
        switch repoState {
        case .merging: args = ["merge", "--abort"]
        case .rebasing: args = ["rebase", "--abort"]
        case .cherryPicking: args = ["cherry-pick", "--abort"]
        case .reverting: args = ["revert", "--abort"]
        case .clean: return
        }
        confirm = ConfirmRequest(title: String(localized: "Abort the current operation (\(repoState.title))?"),
                                 message: String(localized: "Returns to the state before the operation started."), actionTitle: String(localized: "Abort")) { [weak self] in
            await self?.run(String(localized: "Aborting…"), args)
            self?.summary = ""
            self?.message = ""
        }
    }

    func continueOperation() async {
        switch repoState {
        case .rebasing: await run(String(localized: "Continuing rebase…"), ["rebase", "--continue"])
        case .cherryPicking: await run(String(localized: "Continuing cherry-pick…"), ["cherry-pick", "--continue"])
        case .reverting: await run(String(localized: "Continuing revert…"), ["revert", "--continue"])
        case .merging: await commit()
        case .clean: break
        }
    }

    // MARK: - 기타

    func revealInFinder(_ c: FileChange) { revealInFinder(path: c.path) }

    /// 저장소 안 경로를 Finder 에서 고른다. 지워진 파일이면 남아 있는 가장 가까운 폴더를 연다.
    func revealInFinder(path: String) {
        guard let url else { return }
        var target = url.appendingPathComponent(path)
        while !FileManager.default.fileExists(atPath: target.path), target.path.count > url.path.count {
            target = target.deletingLastPathComponent()
        }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
