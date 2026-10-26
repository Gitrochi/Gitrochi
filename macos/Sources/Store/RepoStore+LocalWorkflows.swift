import Foundation

/// 안전 사본은 별도 인덱스로 만들고 ref 에 보관해 작업 파일을 움직이거나 사용자 인덱스를 덮어쓰지 않는다.
extension RepoStore {
    func loadLocalWorkflows() async {
        guard let url else { return }
        let generation = UUID()
        localWorkflows.generation = generation; localWorkflows.loading = true; localWorkflows.error = nil
        defer { if self.url == url && localWorkflows.generation == generation { localWorkflows.loading = false } }
        do {
            let safetyPrefix = try await localSafetyPrefix(in: url)
            async let refs = Git.raw(["for-each-ref", "--format=%(refname) %(objectname)", safetyPrefix], in: url)
            async let reflog = Git.raw(["reflog", "show", "--all", "-n", "300", "--format=%H%x1f%gd%x1f%gs%x1f%aI"], in: url)
            async let lfs = Git.raw(["lfs", "version"], in: url)
            async let files = Git.raw(["lfs", "ls-files"], in: url)
            async let patterns = Git.raw(["lfs", "track"], in: url)
            async let modules = Git.raw(["submodule", "status"], in: url)
            async let config = Git.raw(["config", "--file", ".gitmodules", "--get-regexp", "^submodule\\..*\\.(path|url)$"], in: url)
            async let bisect = Git.raw(["bisect", "log"], in: url)
            async let head = Git.raw(["log", "-1", "--format=%h %s"], in: url)
            async let indexEntries = Git.raw(["ls-files", "--stage", "-z"], in: url)
            let (r, log, l, f, p, m, c, b, h, i) = try await (refs, reflog, lfs, files, patterns, modules, config, bisect, head, indexEntries)
            guard self.url == url && localWorkflows.generation == generation else { return }
            localWorkflows.recovery = LocalWorkflowState.parseSafety(r.output)
            localWorkflows.reflog = log.output.split(separator: "\n").compactMap { line in
                let parts = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 4 else { return nil }
                return RecoveryReflog(sha: parts[0], selector: parts[1], message: parts[2], date: parts[3])
            }
            localWorkflows.lfsAvailable = l.status == 0; localWorkflows.lfsFiles = f.status == 0 ? f.output : ""; localWorkflows.lfsPatterns = p.status == 0 ? p.output : ""
            var entries: [String: [String: String]] = [:]
            for line in c.output.split(separator: "\n") {
                let values = line.split(separator: " ", maxSplits: 1).map(String.init)
                guard values.count == 2, let dot = values[0].lastIndex(of: ".") else { continue }
                entries[String(values[0][..<dot]), default: [:]][String(values[0][values[0].index(after: dot)...])] = values[1]
            }
            var recorded: [String: String] = [:]
            for line in i.output.split(separator: "\0") { let values = line.split(separator: "\t", maxSplits: 1).map(String.init); guard values.count == 2 else { continue }; let info = values[0].split(separator: " ").map(String.init); if info.count == 3 && info[0] == "160000" && info[2] == "0" { recorded[values[1]] = info[1] } }
            localWorkflows.submodules = m.output.split(separator: "\n").compactMap { line in
                guard line.count > 42 else { return nil }
                let status = String(line.prefix(1)), body = line.dropFirst()
                let values = body.split(separator: " ", maxSplits: 1).map(String.init)
                guard values.count == 2 else { return nil }
                let path = values[1].components(separatedBy: " (").first ?? values[1]
                let config = entries.first { $0.value["path"] == path }
                return ManagedSubmodule(path: path, sha: recorded[path] ?? values[0], status: status, url: config?.value["url"] ?? "", configName: config.map { String($0.key.dropFirst("submodule.".count)) } ?? "")
            }
            localWorkflows.bisectActive = b.status == 0; localWorkflows.bisectLog = b.status == 0 ? b.output : ""; localWorkflows.bisectCurrent = h.output.trimmed
            localWorkflows.bisectResult = b.output.components(separatedBy: "\n").last { $0.hasPrefix("# first 'bad' commit: ") || $0.hasPrefix("# first bad commit: ") }?.replacingOccurrences(of: "# first 'bad' commit: ", with: "").replacingOccurrences(of: "# first bad commit: ", with: "") ?? ""
        } catch { if self.url == url && localWorkflows.generation == generation { localWorkflows.error = describe(error) } }
    }

    func preserveDiscardedChanges(paths: [String]? = nil) async -> Bool {
        guard let url, let gitDir, busy == nil, status.conflicted.isEmpty, paths?.allSatisfy(LocalWorkflowState.safePath) != false else { return false }
        let generation = localWorkflows.generation
        let indexFile = gitDir.appendingPathComponent("gitrochi-safety-index-" + UUID().uuidString)
        let env = ["GIT_INDEX_FILE": indexFile.path]
        defer { try? FileManager.default.removeItem(at: indexFile) }
        do {
            let headResult = try await Git.raw(["rev-parse", "--verify", "HEAD"], in: url)
            let head = headResult.status == 0 ? headResult.output.trimmed : try await Git.run(["hash-object", "-w", "-t", "tree", "--stdin"], in: url, input: "").output.trimmed
            let index = try await Git.run(["write-tree"], in: url).output.trimmed
            let names = try await Git.run(["ls-files", "-co", "--exclude-standard", "-z"], in: url).output.split(separator: "\0").map(String.init)
            guard names.count <= 20_000, names.allSatisfy(LocalWorkflowState.safePath) else { throw GitError(command: "safety", message: String(localized: "The safety copy exceeds the supported file count or contains an unsafe path.")) }
            var size = 0
            for name in Set(names) { size += ((try? FileManager.default.attributesOfItem(atPath: url.appendingPathComponent(name).path)[.size]) as? NSNumber)?.intValue ?? 0 }
            guard size <= 200_000_000 else { throw GitError(command: "safety", message: String(localized: "The safety copy exceeds 200 MB. Preserve these changes manually before discarding.")) }
            try await Git.run(["read-tree", head], in: url, env: env)
            try await Git.run(["add", "-A", "--", "."], in: url, env: env)
            let tree = try await Git.run(["write-tree"], in: url, env: env).output.trimmed
            try await Git.run(["add", "-A", "--", "."], in: url, env: env)
            let verify = try await Git.run(["write-tree"], in: url, env: env).output.trimmed
            let currentIndex = try await Git.run(["write-tree"], in: url).output.trimmed
            let current = try await Git.raw(["rev-parse", "--verify", "HEAD"], in: url)
            let currentHead = current.status == 0 ? current.output.trimmed : head
            guard self.url == url, localWorkflows.generation == generation, tree == verify, index == currentIndex, head == currentHead else { throw GitError(command: "safety", message: String(localized: "The repository changed while making the safety copy. Try again.")) }
            let id = "\(Int64(Date().timeIntervalSince1970 * 1000))-" + UUID().uuidString.lowercased()
            let prefix = try await localSafetyPrefix(in: url) + "/" + id
            try await Git.run(["update-ref", "--stdin"], in: url, input: "start\ncreate \(prefix)/worktree \(tree)\ncreate \(prefix)/index \(index)\ncreate \(prefix)/head \(head)\nprepare\ncommit\n")
            guard self.url == url, localWorkflows.generation == generation else { return false }
            try await Git.run(["add", "-A", "--", "."], in: url, env: env)
            let finalTree = try await Git.run(["write-tree"], in: url, env: env).output.trimmed
            let finalIndex = try await Git.run(["write-tree"], in: url).output.trimmed
            let finalHead = try await Git.raw(["rev-parse", "--verify", "HEAD"], in: url)
            guard self.url == url, localWorkflows.generation == generation, finalTree == tree, finalIndex == index, finalHead.status == 0 ? finalHead.output.trimmed == head : headResult.status != 0 else { throw GitError(command: "safety", message: String(localized: "The repository changed while making the safety copy. Try again.")) }
            localWorkflows.notice = String(localized: "A local safety copy was saved in Repository tools → Recovery.")
            return true
        } catch { if self.url == url && localWorkflows.generation == generation { errorMessage = String(localized: "Changes were not discarded because a safety copy could not be saved.\n\n") + describe(error) }; return false }
    }

    func previewRecovery(_ entry: SafetyCopy) async {
        guard let url else { return }; let generation = localWorkflows.generation
        do {
            async let worktree = Git.run(["diff", "--no-ext-diff", "--no-textconv", "--stat", "--patch", entry.head, entry.worktree, "--"], in: url)
            async let index = Git.run(["diff", "--no-ext-diff", "--no-textconv", "--stat", "--patch", entry.head, entry.index, "--"], in: url)
            let (w, i) = try await (worktree, index)
            if self.url == url && localWorkflows.generation == generation {
                let preview = String(localized: "Saved index") + "\n" + i.output + "\n" + String(localized: "Saved working tree") + "\n" + w.output
                localWorkflows.preview = String(preview.prefix(200_000)) + (preview.count > 200_000 ? "\n" + String(localized: "Preview truncated. The complete safety copy is retained.") : "")
            }
        } catch { if self.url == url && localWorkflows.generation == generation { localWorkflows.error = describe(error) } }
    }
    func restoreSafetyCopy(_ entry: SafetyCopy) {
        guard let url else { return }; let generation = localWorkflows.generation
        confirm = ConfirmRequest(title: String(localized: "Restore the saved working tree and index?"), message: String(localized: "Restoring requires a clean working tree at the original commit. The saved staged and unstaged changes, including new files, will return."), actionTitle: String(localized: "Restore safety copy"), destructive: false) { [weak self] in
            guard let self, self.url == url, self.localWorkflows.generation == generation else { return }
            do {
                let status = try await Git.run(["status", "--porcelain=v2", "--untracked-files=all"], in: url).output.trimmed
                let headResult = try await Git.raw(["rev-parse", "--verify", "HEAD"], in: url)
                let head = headResult.status == 0 ? headResult.output.trimmed : try await Git.run(["hash-object", "-w", "-t", "tree", "--stdin"], in: url, input: "").output.trimmed
                guard status.isEmpty, head == entry.head, self.repoState == .clean else { self.errorMessage = String(localized: "Return to the original commit with a clean working tree before restoring. The safety copy is kept."); return }
                let prefix = try await self.localSafetyPrefix(in: url) + "/" + entry.id
                let refs = try await Git.run(["for-each-ref", "--format=%(refname) %(objectname)", prefix], in: url).output
                guard LocalWorkflowState.parseSafety(refs).contains(entry), self.url == url, self.localWorkflows.generation == generation else { return }
                if await self.run(String(localized: "Restoring safety copy…"), ["restore", "--source=\(entry.worktree)", "--worktree", "--", "."]) { await self.run(String(localized: "Restoring index…"), ["restore", "--source=\(entry.index)", "--staged", "--", "."]) }
                await self.loadLocalWorkflows()
            } catch { if self.url == url { self.errorMessage = describe(error) } }
        }
    }
    func recoverCommit(_ sha: String, branch: String) async {
        guard let url, sha.range(of: "^[a-f0-9]{40,64}$", options: .regularExpression) != nil, !branch.isEmpty, !branch.hasPrefix("-") else { return }
        do { try await Git.run(["check-ref-format", "--branch", branch], in: url); guard self.url == url else { return }; await run(String(localized: "Creating recovery branch…"), ["branch", branch, sha]) } catch { errorMessage = describe(error) }
    }
    func lfsTrack(_ pattern: String, remove: Bool = false) async {
        guard !pattern.trimmed.isEmpty, !pattern.hasPrefix("-"), !pattern.contains("\n"), !pattern.contains("\0"), localWorkflows.lfsAvailable else { return }
        await run(String(localized: "Updating LFS patterns…"), ["lfs", remove ? "untrack" : "track", "--", pattern.trimmed]); await loadLocalWorkflows()
    }
    func checkLFS() async { await localTool(["lfs", "fsck"]) }
    func loadLFSLocks() async {
        guard let url else { return }; let generation = localWorkflows.generation
        do {
            let result = try await Git.run(["lfs", "locks", "--json"], in: url, env: AccountStore.shared.gitEnvironment(target: target, repoPath: url.path))
            let json = try JSONSerialization.jsonObject(with: result.data) as? [String: Any]
            guard self.url == url, localWorkflows.generation == generation else { return }
            localWorkflows.lfsLocks = (json?["locks"] as? [[String: Any]] ?? []).compactMap { value in
                guard let id = value["id"] as? String, let path = value["path"] as? String else { return nil }
                return ManagedLFSLock(id: id, path: path, owner: (value["owner"] as? [String: Any])?["name"] as? String ?? "")
            }
        } catch { if self.url == url && localWorkflows.generation == generation { errorMessage = describe(error) } }
    }
    func lockLFS(_ path: String) async { if LocalWorkflowState.safePath(path) { await localTool(["lfs", "lock", path], network: true) } }
    func unlockLFS(_ id: String) {
        guard id.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil else { return }
        let original = url, generation = localWorkflows.generation
        confirm = ConfirmRequest(title: String(localized: "Unlock this LFS file?"), message: String(localized: "The server lock will be removed. No force unlock is used."), actionTitle: String(localized: "Unlock"), destructive: true) { [weak self] in guard let self, self.url == original, self.localWorkflows.generation == generation else { return }; await self.localTool(["lfs", "unlock", "--id=\(id)"], network: true) }
    }
    func updateSubmodule(_ entry: ManagedSubmodule) {
        guard let url, LocalWorkflowState.safePath(entry.path), LocalWorkflowState.safeURL(entry.url), !entry.configName.isEmpty, entry.configName.rangeOfCharacter(from: .controlCharacters) == nil, !entry.configName.contains("=") else { errorMessage = String(localized: "Only validated HTTPS or SSH submodule URLs are allowed. Review .gitmodules first."); return }
        let generation = localWorkflows.generation
        confirm = ConfirmRequest(title: String(localized: "Initialize or update this submodule?"), message: entry.path + "\n" + entry.url + "\n" + String(localized: "Check out the exact commit recorded by the parent repository. Local submodule changes block the update."), actionTitle: String(localized: "Update submodule"), destructive: false) { [weak self] in
            guard let self, self.url == url, self.localWorkflows.generation == generation else { return }
            do {
                let resolved = url.appendingPathComponent(entry.path).resolvingSymlinksInPath().standardizedFileURL.path
                guard resolved.hasPrefix(url.resolvingSymlinksInPath().standardizedFileURL.path + "/") else { self.errorMessage = String(localized: "The submodule path resolves outside this repository. Review its folder first."); return }
                let config = try await Git.run(["config", "--file", ".gitmodules", "--get-regexp", "^submodule\\..*\\.(path|url)$"], in: url).output
                guard config.components(separatedBy: "\n").contains("submodule.\(entry.configName).url \(entry.url)"), config.components(separatedBy: "\n").contains("submodule.\(entry.configName).path \(entry.path)") else { self.errorMessage = String(localized: "Submodule configuration changed. Refresh before updating."); return }
                let recorded = try await Git.run(["ls-files", "--stage", "-z", "--", entry.path], in: url).output
                guard recorded.hasPrefix("160000 \(entry.sha) 0\t") else { self.errorMessage = String(localized: "Submodule configuration changed. Refresh before updating."); return }
                let status = try await Git.raw(["-C", entry.path, "status", "--porcelain=v2", "--untracked-files=all"], in: url)
                guard entry.status == "-" || (status.status == 0 && status.output.trimmed.isEmpty) else { self.errorMessage = String(localized: "Commit or stash changes inside the submodule first."); return }
                if entry.status != "-" {
                    let remote = try await Git.raw(["-C", entry.path, "remote", "get-url", "origin"], in: url)
                    guard remote.status == 0 && remote.output.trimmed == entry.url else { self.errorMessage = String(localized: "The submodule remote differs from the reviewed URL. Review its origin configuration first."); return }
                }
                guard self.url == url, self.localWorkflows.generation == generation else { return }
                await self.localTool(["-c", "protocol.file.allow=never", "-c", "protocol.ext.allow=never", "-c", "submodule.\(entry.configName).url=\(entry.url)", "submodule", "update", "--init", "--checkout", "--", entry.path])
            } catch { if self.url == url { self.errorMessage = describe(error) } }
        }
    }
    func startBisect(good: String, bad: String) async {
        guard let url, busy == nil, !good.isEmpty, !bad.isEmpty, !good.hasPrefix("-"), !bad.hasPrefix("-") else { return }
        do {
            let status = try await Git.run(["status", "--porcelain=v2", "--untracked-files=all"], in: url).output.trimmed
            guard self.url == url, status.isEmpty, repoState == .clean, !localWorkflows.bisectActive else { errorMessage = String(localized: "Start bisect with a clean working tree and no operation in progress."); return }
            let a = try await Git.run(["rev-parse", "--verify", good + "^{commit}"], in: url).output.trimmed
            let b = try await Git.run(["rev-parse", "--verify", bad + "^{commit}"], in: url).output.trimmed
            let ancestor = try await Git.raw(["merge-base", "--is-ancestor", a, b], in: url)
            guard ancestor.status == 0 else { errorMessage = String(localized: "The good commit must be an ancestor of the bad commit."); return }
            let originalHead = try await Git.run(["rev-parse", "HEAD"], in: url).output.trimmed, generation = localWorkflows.generation
            confirm = ConfirmRequest(title: String(localized: "Start finding the first bad commit?"), message: String(localized: "Git will temporarily check out commits for you to test. Mark each commit good, bad, or skip. Reset bisect returns to the original branch."), actionTitle: String(localized: "Start bisect"), destructive: false) { [weak self] in
                guard let self, self.url == url, self.localWorkflows.generation == generation else { return }
                do {
                    let head = try await Git.run(["rev-parse", "HEAD"], in: url).output.trimmed
                    let clean = try await Git.run(["status", "--porcelain=v2", "--untracked-files=all"], in: url).output.trimmed
                    let active = try await Git.raw(["bisect", "log"], in: url)
                    guard self.url == url, self.localWorkflows.generation == generation else { return }
                    guard head == originalHead, clean.isEmpty, active.status != 0, self.repoState == .clean else { self.errorMessage = String(localized: "The repository changed. Refresh before starting bisect."); return }
                    await self.localTool(["bisect", "start", b, a])
                } catch { if self.url == url { self.errorMessage = describe(error) } }
            }
        } catch { if self.url == url { errorMessage = describe(error) } }
    }
    func markBisect(_ mark: String) async {
        guard let url, localWorkflows.bisectActive, localWorkflows.bisectResult.isEmpty, ["good", "bad", "skip"].contains(mark) else { return }
        let generation = localWorkflows.generation, current = localWorkflows.bisectCurrent
        do {
            let status = try await Git.run(["status", "--porcelain=v2", "--untracked-files=all"], in: url).output.trimmed
            let head = try await Git.run(["log", "-1", "--format=%h %s"], in: url).output.trimmed
            let active = try await Git.raw(["bisect", "log"], in: url)
            guard self.url == url, localWorkflows.generation == generation else { return }
            guard status.isEmpty, current == head, active.status == 0 else { errorMessage = String(localized: "Keep the working tree clean and refresh the current test commit before marking it."); return }
            await localTool(["bisect", mark])
        } catch { if self.url == url { errorMessage = describe(error) } }
    }
    func resetBisect() async { if localWorkflows.bisectActive { await localTool(["bisect", "reset"]) } }
    private func localTool(_ args: [String], network: Bool = false) async { let original = url; await run(String(localized: "Running repository tool…"), args, network: network); if url == original { await loadLocalWorkflows() } }
    private func localSafetyPrefix(in url: URL) async throws -> String {
        let directory = try await Git.run(["rev-parse", "--absolute-git-dir"], in: url).output.trimmed
        let scope = try await Git.run(["hash-object", "--stdin"], in: url, input: directory).output.trimmed
        return "refs/gitrochi/safety/" + scope
    }
}
