import Foundation

struct RebasePreview {
    struct Commit: Identifiable { let id: String; let subject: String }
    let base: String; let head: String; let incoming: Int; let replay: Int; let commits: [Commit]
    static func defaultBase(names: [String], current: String?, upstream: String?) -> String {
        (["origin/main", "main", "origin/master", "master"] + [upstream].compactMap { $0 } + names).first { names.contains($0) && $0 != current } ?? upstream ?? names.first ?? "main"
    }
    /// 이름을 고정 SHA로 바꾼 뒤 읽기 명령으로만 후보를 확인한다.
    static func load(in repo: URL, base: String, head: String, read: ([String], URL) async throws -> String = { try await Git.run($0, in: $1).output }) async throws -> RebasePreview {
        guard RepositoryBrowser.validRevision(base), RepositoryBrowser.validRevision(head) else { throw RepositoryBrowserError(message: String(localized: "Choose a valid base branch to preview its commits.")) }
        async let baseRead = read(["rev-parse", "--verify", base + "^{commit}"], repo)
        async let headRead = read(["rev-parse", "--verify", head + "^{commit}"], repo)
        let (onto, current) = try await (baseRead, headRead), target = onto.trimmingCharacters(in: .whitespacesAndNewlines), original = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard RepositoryBrowser.objectID(target), RepositoryBrowser.objectID(original) else { throw RepositoryBrowserError(message: String(localized: "Choose a valid base branch to preview its commits.")) }
        async let countRead = read(["rev-list", "--left-right", "--count", target + "..." + original], repo)
        async let logRead = read(["log", "-n", "12", "--format=%H%x09%s", target + ".." + original, "--"], repo)
        let (counts, log) = try await (countRead, logRead), values = counts.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        guard values.count == 2, values.allSatisfy({ $0 >= 0 }) else { throw RepositoryBrowserError(message: String(localized: "The branch summary could not be read. Refresh and try again.")) }
        let commits: [RebasePreview.Commit] = log.split(separator: "\n").compactMap { (line: Substring) -> RebasePreview.Commit? in
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, RepositoryBrowser.objectID(String(parts[0])) else { return nil }
            return RebasePreview.Commit(id: String(parts[0]), subject: String(parts[1]))
        }

        return RebasePreview(base: target, head: original, incoming: values[0], replay: values[1], commits: commits)
    }
}
