import Foundation
import GitrochiCore

/// The shared SQLite repository index (crates/gitrochi-index), reached through the Rust core.
/// It answers the search bar's deeper step from the database instead of running git log.
/// Windows: windows/src/shared/platform/repo-index.ts.
enum RepoIndex {
    /// Commits indexed per background pass, so a very large history fills in over several passes
    /// instead of one long one; searches use git until the index is complete.
    static let passLimit = 20_000

    /// `GITROCHI_INDEX=0` turns the index off (searches then always use git).
    static var enabled: Bool { ProcessInfo.processInfo.environment["GITROCHI_INDEX"] != "0" }

    /// `GITROCHI_TRACE=1` prints index calls next to the store's refresh timings. Usable off the
    /// main actor, unlike RepoStore.trace.
    private static let tracing = ProcessInfo.processInfo.environment["GITROCHI_TRACE"] == "1"
    static func trace(_ s: @autoclosure () -> String) {
        if tracing { FileHandle.standardError.write(Data("[gitrochi] \(s())\n".utf8)) }
    }

    /// Sends one command; nil when the index answered with an error, so callers fall back to git.
    static func call(_ command: String, repo: URL, args: [String: Any] = [:]) -> [String: Any]? {
        let request: [String: Any] = ["repo": repo.path, "command": command, "args": args]
        guard let data = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        let output = data.withUnsafeBytes { bytes in
            gitrochi_index_call(bytes.bindMemory(to: UInt8.self).baseAddress!, data.count)
        }
        let count = Int(UInt64(littleEndian: UnsafeRawPointer(output).loadUnaligned(as: UInt64.self)))
        defer { gitrochi_index_free(output, count + 8) }
        guard let response = try? JSONSerialization.jsonObject(with: Data(bytes: output.advanced(by: 8), count: count)) as? [String: Any]
        else { return nil }
        if let error = response["error"] as? [String: Any] {
            trace("index \(command): \(error["code"] as? String ?? "") \(error["message"] as? String ?? "")")
            return nil
        }
        return response["result"] as? [String: Any]
    }

    /// Brings the index up to date in the background. Requests that arrive during a pass fold
    /// into one more pass for that repository.
    static func refresh(_ repo: URL) {
        guard enabled else { return }
        Task.detached(priority: .utility) { await Refresher.shared.request(repo) }
    }

    /// The deeper search step from the index: SHAs for the commits and files scopes (the same
    /// matching as git's --grep and the icase path glob), and a cached `git log -G` for code.
    /// Nil when the index is off, missing or behind the repository, so the caller runs git.
    static func searchMatches(_ repo: URL, scope: SearchScope, query: String, codePattern: String) async -> Set<String>? {
        guard enabled else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> Set<String>? in
            switch scope {
            case .commits, .files:
                let args: [String: Any] = ["query": query, "scope": scope == .commits ? "commits" : "files", "limit": 20_000]
                guard let result = call("match", repo: repo, args: args), result["stale"] as? Bool == false,
                      let shas = result["shas"] as? [String] else { return nil }
                return Set(shas)
            case .code:
                // Only when the index is current: the cache keys results by the ref tips.
                guard let status = call("status", repo: repo), status["stale"] as? Bool == false,
                      let result = call("cache", repo: repo, args: ["action": "pickaxe", "text": codePattern, "regex": true, "limit": 1000]),
                      let commits = result["commits"] as? [[String: Any]] else { return nil }
                return Set(commits.compactMap { $0["sha"] as? String })
            }
        }.value
    }
}

/// One background sync per repository at a time.
private actor Refresher {
    static let shared = Refresher()
    private var running = Set<String>()
    private var again = Set<String>()

    func request(_ repo: URL) async {
        let key = repo.standardizedFileURL.path
        guard !running.contains(key) else {
            again.insert(key)
            return
        }
        running.insert(key)
        repeat {
            again.remove(key)
            let started = ContinuousClock.now
            // Only a Sendable count crosses back into the actor.
            let added = await Task.detached(priority: .utility) {
                RepoIndex.call("sync", repo: repo, args: ["limit": RepoIndex.passLimit])?["newCommits"] as? Int
            }.value
            RepoIndex.trace("index sync \(added ?? -1) new in \(ContinuousClock.now - started)")
        } while again.contains(key)
        running.remove(key)
    }
}
