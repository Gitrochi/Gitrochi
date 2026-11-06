import Foundation

/// A branch or tag the current branch can be moved onto (the Rebase page's list). (Windows: RebaseBase)
struct RebaseBase: Identifiable, Equatable {
    enum Kind: String { case branch, remote, tag }
    let name: String
    let kind: Kind
    /// Commits it has that the current branch lacks; 0 means it is already in this branch, nil that Git did not say
    let incoming: Int?
    var id: String { kind.rawValue + ":" + name }

    /// One line per ref: its full name, then how far it is ahead of and behind HEAD (Git 2.41 and later)
    static let listArgs = ["for-each-ref", "--format=%(refname)%09%(ahead-behind:HEAD)", "refs/heads", "refs/remotes", "refs/tags"]

    /// The current branch and the remotes' HEAD pointers are left out. The usual bases come first, then local
    /// branches, remote branches and tags.
    static func parse(_ output: String, current: String?) -> [RebaseBase] {
        var found: [RebaseBase] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard let ref = parts.first.map(String.init) else { continue }
            let counts = parts.count > 1 ? parts[1].split(separator: " ").compactMap { Int($0) } : []
            let incoming = counts.count == 2 ? counts[0] : nil
            if ref.hasPrefix("refs/heads/") {
                let name = String(ref.dropFirst("refs/heads/".count))
                if name != current { found.append(RebaseBase(name: name, kind: .branch, incoming: incoming)) }
            } else if ref.hasPrefix("refs/remotes/") {
                let name = String(ref.dropFirst("refs/remotes/".count))
                if !name.hasSuffix("/HEAD") { found.append(RebaseBase(name: name, kind: .remote, incoming: incoming)) }
            } else if ref.hasPrefix("refs/tags/") {
                found.append(RebaseBase(name: String(ref.dropFirst("refs/tags/".count)), kind: .tag, incoming: incoming))
            }
        }
        let usual = ["origin/main", "main", "origin/master", "master"]
        func rank(_ base: RebaseBase) -> Int {
            if base.kind != .tag, let index = usual.firstIndex(of: base.name) { return index }
            switch base.kind {
            case .branch: return usual.count
            case .remote: return usual.count + 1
            case .tag: return usual.count + 2
            }
        }
        return found.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    static func matches(_ base: RebaseBase, search: String) -> Bool {
        let words = search.trimmingCharacters(in: .whitespaces)
        return words.isEmpty || base.name.localizedCaseInsensitiveContains(words)
    }
}

struct RebasePreview {
    struct Commit: Identifiable { let id: String; let subject: String; var date: Date? = nil }
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
        async let logRead = read(["log", "-n", "12", "--format=%H%x09%s%x09%ct", target + ".." + original, "--"], repo)
        let (counts, log) = try await (countRead, logRead), values = counts.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        guard values.count == 2, values.allSatisfy({ $0 >= 0 }) else { throw RepositoryBrowserError(message: String(localized: "The branch summary could not be read. Refresh and try again.")) }
        let commits: [RebasePreview.Commit] = log.split(separator: "\n").compactMap { (line: Substring) -> RebasePreview.Commit? in
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, RepositoryBrowser.objectID(String(parts[0])) else { return nil }
            // the commit time follows the subject; a subject may hold tabs of its own
            var subject = String(parts[1]), date: Date? = nil
            if let tab = subject.lastIndex(of: "\t"), let seconds = TimeInterval(subject[subject.index(after: tab)...]) {
                date = Date(timeIntervalSince1970: seconds)
                subject = String(subject[..<tab])
            }
            return RebasePreview.Commit(id: String(parts[0]), subject: subject, date: date)
        }

        return RebasePreview(base: target, head: original, incoming: values[0], replay: values[1], commits: commits)
    }
}
