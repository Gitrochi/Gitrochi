import Foundation

/// 계정과 목적지·원본을 고정한 확인 창을 거쳐서만 브랜치를 올린다.
extension RepoStore {
    @discardableResult
    func requestPushReview(branch: String, force: Bool = false, remoteOverride: String? = nil) async -> Bool {
        guard url != nil, busy == nil, pushReviewCompletion == nil else { return false }
        pushReview = nil
        pushReviewError = nil
        return await withCheckedContinuation { continuation in
            pushReviewCompletion = { continuation.resume(returning: $0) }
            sheet = .pushReview(branch: branch, force: force, remoteOverride: remoteOverride)
        }
    }

    func cancelPushReview() {
        pushReviewGeneration += 1
        pushReviewLoading = false
        let complete = pushReviewCompletion
        pushReviewCompletion = nil
        pushReview = nil
        complete?(false)
    }

    func loadPushReview(branch: String, force: Bool, remoteOverride: String?) async {
        pushReviewGeneration += 1
        let generation = pushReviewGeneration
        pushReviewLoading = true
        pushReview = nil
        pushReviewError = nil
        defer { if generation == pushReviewGeneration { pushReviewLoading = false } }
        do {
            let plan = try await buildPushReview(branch: branch, force: force, remoteOverride: remoteOverride)
            if generation == pushReviewGeneration { pushReview = plan }
        } catch {
            if generation == pushReviewGeneration { pushReviewError = PushReview.displayURL(describe(error)) }
        }
    }

    private func buildPushReview(branch: String, force: Bool, remoteOverride: String?) async throws -> PushReviewPlan {
        guard let repo = url else { throw PushReview.Failure(message: "The repository was closed. Open it and review the push again.") }
        @Sendable func g(_ args: [String]) async throws -> String { try await Git.run(args, in: repo).output }
        async let configOutput = g(["config", "--null", "--list"])
        async let remoteOutput = g(["remote"])
        async let sourceOutput = g(["rev-parse", "--verify", "refs/heads/\(branch)^{commit}"])
        async let current = Git.run(["symbolic-ref", "--quiet", "--short", "HEAD"], in: repo, ok: [0, 1])
        async let statusOutput = Gitch.status(in: repo)
        async let checks = Gitch.preflight(in: repo, fetch: false)
        let (rawConfig, rawRemotes, rawSource, rawCurrent, status, preflight) = try await (configOutput, remoteOutput, sourceOutput, current, statusOutput, checks)
        let config = PushReview.config(rawConfig), sourceOID = rawSource.trimmed
        let resolved = try PushReview.destination(config: config, remotes: rawRemotes.split(separator: "\n").map(String.init), branch: branch,
                                                 currentBranch: rawCurrent.output.trimmed, remoteOverride: remoteOverride)
        let urls = try await g(["remote", "get-url", "--push", "--all", resolved.remote]).split(separator: "\n").map(String.init)
        guard urls.count == 1 else { throw PushReview.Failure(message: "Multiple push URLs cannot be reviewed as a single destination. Configure one push URL.") }
        let pushURL = urls[0]
        let target = Hosting.target(remotes: [resolved.remote], urls: [resolved.remote: pushURL], gitlabHosts: AccountStore.shared.accounts.map(\.host), sshAliases: AccountStore.shared.sshHostAliases)
        let env = AccountStore.shared.gitEnvironment(target: target, repoPath: repo.path)
        let refs = try await Git.run(["ls-remote", "--refs", "--", pushURL, resolved.destination], in: repo, env: env)
        let destinationOID = refs.output.split(whereSeparator: \.isWhitespace).first.map(String.init)
        if let destinationOID {
            guard destinationOID.range(of: "^[a-fA-F0-9]{40,64}$", options: .regularExpression) != nil else {
                throw PushReview.Failure(message: "The remote branch could not be read. Refresh and review the push again.")
            }
            let object = try await Git.raw(["cat-file", "-e", destinationOID + "^{commit}"], in: repo)
            guard object.status == 0 else { throw PushReview.Failure(message: "Fetch this remote first so the outgoing commits and files can be reviewed accurately.") }
        }
        var range = destinationOID.map { [$0 + ".." + sourceOID] } ?? [sourceOID]
        var comparisonBase = destinationOID
        var observedHeads: [String] = []
        if destinationOID == nil {
            let allRefs = try await Git.run(["ls-remote", "--symref", "--", pushURL, "HEAD", "refs/heads/*"], in: repo, env: env)
            let rows = allRefs.output.split(separator: "\n").map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
            func isOID(_ value: String) -> Bool { value.range(of: "^[a-fA-F0-9]{40,64}$", options: .regularExpression) != nil }
            observedHeads = Array(Set(rows.filter { $0.count == 2 && isOID($0[0]) && $0[1].hasPrefix("refs/heads/") }.map { $0[0] })).sorted()
            let defaultOID = rows.first { $0.count == 2 && isOID($0[0]) && $0[1] == "HEAD" }?.first
            if !observedHeads.isEmpty {
                let objects = try await Git.run(["cat-file", "--batch-check"], in: repo, input: observedHeads.joined(separator: "\n") + "\n")
                let objectRows = objects.output.split(separator: "\n")
                guard objectRows.count == observedHeads.count, objectRows.allSatisfy({ $0.range(of: "^[a-fA-F0-9]{40,64} commit [0-9]+$", options: .regularExpression) != nil }) else {
                    throw PushReview.Failure(message: "Fetch this remote first so the outgoing commits and files can be reviewed accurately.")
                }
                range = [sourceOID, "--not"] + observedHeads
                let reference = defaultOID.flatMap { observedHeads.contains($0) ? $0 : nil } ?? observedHeads[0]
                let base = try await Git.run(["merge-base", sourceOID, reference], in: repo, ok: [0, 1])
                comparisonBase = base.output.trimmed.isEmpty ? nil : base.output.trimmed
            }
        }
        let commitRange = range
        let fileArguments = comparisonBase.map { ["diff", "--name-only", "-z", $0, sourceOID, "--"] } ?? ["ls-tree", "-r", "--name-only", "-z", sourceOID]
        async let logOutput = g(["log", "-200", "--format=%H%x1f%an%x1f%ae%x1f%s"] + commitRange + ["--"])
        async let countOutput = g(["rev-list", "--count"] + commitRange + ["--"])
        async let fileOutput = g(fileArguments)
        let (log, count, names) = try await (logOutput, countOutput, fileOutput)
        let connected = target.flatMap { AccountStore.shared.account(for: $0, repoPath: repo.path) }
        let account = status?.lockedAccount ?? connected?.username ?? status?.pushAccount ?? status?.account ?? String(localized: "System Git credentials")
        let credentialAccount = connected?.username ?? String(localized: "System Git credentials")
        let author = [config["user.name"]?.last, config["user.email"]?.last.map { "<" + $0 + ">" }].compactMap { $0 }.joined(separator: " ")
        let stampParts: [Any] = [PushReview.configStamp(config), sourceOID, resolved.remote, resolved.destination, pushURL, destinationOID ?? "", account, credentialAccount, author, AccountStore.shared.revision, remoteOverride ?? "", observedHeads, comparisonBase ?? ""]
        let stamp = String(decoding: try JSONSerialization.data(withJSONObject: stampParts), as: UTF8.self)
        let commits = log.split(separator: "\n").compactMap { line -> PushReviewPlan.Commit? in
            let parts = line.components(separatedBy: "\u{1f}")
            guard parts.count >= 4 else { return nil }
            return .init(sha: parts[0], subject: parts[3...].joined(separator: "\u{1f}"), author: parts[1], email: parts[2])
        }
        let files = names.split(separator: "\0").map(String.init)
        return PushReviewPlan(repo: repo, branch: branch, sourceOID: sourceOID, remote: resolved.remote, destination: resolved.destination,
                              pushURL: pushURL, destinationOID: destinationOID, force: force, setUpstream: resolved.setUpstream, stamp: stamp,
                              author: author.isEmpty ? String(localized: "Not configured") : author, account: account, credentialAccount: credentialAccount,
                              preflight: preflight.map { value in Gitch.Preflight(result: value.result, checks: value.checks.map { .init(level: $0.level, code: $0.code, message: PushReview.displayURL($0.message)) }) } ?? .init(result: "STOP", checks: [.init(level: "STOP", code: "unavailable", message: String(localized: "The gitch preflight check is unavailable. Open Settings → CLI and repair gitch before pushing."))]),
                              commits: commits, commitCount: Int(count.trimmed) ?? 0, files: Array(files.prefix(500)), fileCount: files.count, fileScope: comparisonBase == nil ? "snapshot" : "changes", comparisonBase: comparisonBase)
    }

    @discardableResult
    func confirmPushReview() async -> Bool {
        guard let plan = pushReview, !pushReviewLoading, busy == nil, plan.preflight.result != "STOP",
              case .pushReview(_, _, let remoteOverride) = sheet else { return false }
        let generation = pushReviewGeneration
        func active() -> Bool {
            guard generation == pushReviewGeneration, url == plan.repo,
                  case .pushReview(let branch, let force, let remote) = sheet else { return false }
            return branch == plan.branch && force == plan.force && remote == remoteOverride
        }
        pushReviewLoading = true
        pushReviewError = nil
        defer { if generation == pushReviewGeneration { pushReviewLoading = false } }
        do {
            let fresh = try await buildPushReview(branch: plan.branch, force: plan.force, remoteOverride: remoteOverride)
            guard active() else { return false }
            pushReview = fresh
            guard fresh.stamp == plan.stamp else {
                pushReviewError = String(localized: "The branch, account or push destination changed. Review the updated details and confirm again.")
                return false
            }
            guard fresh.preflight.result != "STOP" else { return false }
            let target = Hosting.target(remotes: [plan.remote], urls: [plan.remote: plan.pushURL], gitlabHosts: AccountStore.shared.accounts.map(\.host), sshAliases: AccountStore.shared.sshHostAliases)
            let env = AccountStore.shared.gitEnvironment(target: target, repoPath: plan.repo.path)
            let success = await run(String(localized: "Pushing…"), fresh.arguments, network: true, env: env)
            guard active() else { return false }
            guard success else {
                pushReviewError = pushReviewError ?? errorMessage.map(PushReview.displayURL)
                errorMessage = nil
                return false
            }
            if fresh.setUpstream, url == fresh.repo {
                // SHA 를 올렸을 때 Git 이 생략한 추적 설정은 성공 뒤에만 기록한다.
                try await Git.run(["config", "branch.\(fresh.branch).remote", fresh.remote], in: fresh.repo)
                guard active() else { return false }
                try await Git.run(["config", "branch.\(fresh.branch).merge", fresh.destination], in: fresh.repo)
                guard active() else { return false }
                await reload(quiet: true)
                guard active() else { return false }
            }
            await loadPullRequests()
            guard active() else { return false }
            await refreshCIBadges()
            guard active() else { return false }
            let complete = pushReviewCompletion
            pushReviewCompletion = nil
            pushReview = nil
            sheet = nil
            complete?(true)
            return true
        } catch {
            if active() { pushReviewError = PushReview.displayURL(describe(error)) }
            return false
        }
    }
}
