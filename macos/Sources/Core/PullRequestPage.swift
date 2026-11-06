import Foundation

/// The rules of the Pull requests page that need no view: widths, when the header compacts, sorting, the check groups
/// and what a job log marks as an error. (Windows: widgets/inspector/lib/pull-request-page.ts, tested in
/// windows/tests/pull-request-page.test.ts)
enum PullRequestPage {
    static let listWidth: CGFloat = 312
    static let listStripWidth: CGFloat = 40
    static let compactWidth: CGFloat = 916
    static let splitMinimumWidth: CGFloat = 1000
    /// The one-row Changed files header needs this much; a narrower column keeps the tall header
    static let oneRowMinimumWidth: CGFloat = 720
    /// A longer job log shows its end first; the rest waits behind "Show N earlier lines"
    static let logTail = 200

    enum Sort: String, CaseIterable { case updated, newest, comments }

    /// Compact: the file tree narrows and Show in graph / Open in browser move into the More menu. `width` is the
    /// detail column's.
    static func isCompact(listShown: Bool, width: CGFloat) -> Bool { listShown || width <= compactWidth }

    static func treeWidth(compact: Bool) -> CGFloat { compact ? 280 : 340 }

    /// Changed files trades the tall header for one 44pt row, on the page (not in the repository's inspector) and when it fits
    static func headerInOneRow(onPage: Bool, tab: String, width: CGFloat) -> Bool { onPage && tab == "files" && width >= oneRowMinimumWidth }

    /// Two columns of code need room; below this Split is disabled and says why
    static func splitAllowed(diffWidth: CGFloat) -> Bool { diffWidth >= splitMinimumWidth }

    /// `updated` keeps the order the server sent (most recently updated first)
    static func sorted(_ requests: [PullRequest], by sort: Sort) -> [PullRequest] {
        switch sort {
        case .updated: return requests
        case .newest: return requests.sorted { $0.number > $1.number }
        case .comments:
            // a stable sort: unknown counts last, ties in the loaded order
            return requests.enumerated().sorted { a, b in
                let x = a.element.comments ?? -1, y = b.element.comments ?? -1
                return x == y ? a.offset < b.offset : x > y
            }.map(\.element)
        }
    }

    static func reviewRequestedCount(_ requests: [PullRequest]) -> Int { requests.filter(\.reviewRequested).count }

    /// The list's count, or the open review's when the list response carries none (GitHub)
    static func commentCount(_ request: PullRequest, review: PullRequestReview?) -> Int? {
        if let count = request.comments { return count }
        guard let review, review.number == request.number else { return nil }
        return review.comments.filter { $0.kind != .system }.count
    }

    /// "This branch → main" for the checked-out branch's own request, the head's name otherwise
    static func branchLabel(_ request: PullRequest, currentBranch: String?, thisBranch: String) -> String {
        let own = !request.fromFork && currentBranch == request.source
        return (own ? thisBranch : request.source) + " → " + request.target
    }

    /// The folder of a path, shortened from the start by whole segments: "…/Views/Search"
    static func folderLabel(_ path: String) -> String {
        let folders = path.split(separator: "/").dropLast()
        guard folders.count > 2 else { return folders.joined(separator: "/") }
        return "…/" + folders.suffix(2).joined(separator: "/")
    }

    /// The labels a view may show for a path's folder, longest first; when none fits the folder is hidden
    static func folderLabels(_ path: String) -> [String] {
        let folders = path.split(separator: "/").dropLast()
        guard let last = folders.last else { return [] }
        let short = (folders.count > 1 ? "…/" : "") + last
        let label = folderLabel(path)
        return label == short ? [label] : [label, short]
    }

    struct CheckGroups {
        var failed: [RequestCheck] = []
        var running: [RequestCheck] = []
        var passed: [RequestCheck] = []
    }

    static func checkGroups(_ checks: [RequestCheck]) -> CheckGroups {
        var groups = CheckGroups()
        for check in checks {
            switch check.status {
            case .failed: groups.failed.append(check)
            case .success, .neutral, .skipped: groups.passed.append(check)
            default: groups.running.append(check)
            }
        }
        return groups
    }

    enum ChecksBadge: Equatable { case failed(Int), running(Int) }

    /// The Checks tab counts only what needs attention; nothing when every check passed
    static func checksBadge(_ checks: [RequestCheck]) -> ChecksBadge? {
        let groups = checkGroups(checks)
        if !groups.failed.isEmpty { return .failed(groups.failed.count) }
        if !groups.running.isEmpty { return .running(groups.running.count) }
        return nil
    }

    struct LogLine: Identifiable, Equatable {
        let number: Int
        let text: String
        let isError: Bool
        var id: Int { number }
    }

    private static let exitCode = try? NSRegularExpression(pattern: #"exit code [1-9]"#)

    static func logLines(_ body: String) -> [LogLine] {
        // the same reading as the Actions page, so a log says the same thing on both
        var lines = JobLog.lines(body)
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines.enumerated().map { index, text in
            let failed = exitCode?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            return LogLine(number: index + 1, text: text, isError: JobLog.isError(text) || failed)
        }
    }

    static func firstError(_ lines: [LogLine]) -> LogLine? { lines.first(where: \.isError) }

    /// What the summary card says about the current branch
    enum BranchSummary: Equatable {
        case noRequest(commits: Int)
        case moved(incoming: Int, commits: Int)
        case upToDate(commits: Int)
        case notPushed(onServer: Int, local: Int)
    }

    /// `commits` are the branch's own over its base, `incoming` the base's new ones, `ahead` those not pushed yet
    static func branchSummary(hasRequest: Bool, ahead: Int, incoming: Int, commits: Int) -> BranchSummary {
        guard hasRequest else { return .noRequest(commits: commits) }
        if ahead > 0 { return .notPushed(onServer: max(0, commits - ahead), local: ahead) }
        return incoming > 0 ? .moved(incoming: incoming, commits: commits) : .upToDate(commits: commits)
    }

    private static let closingPattern = try? NSRegularExpression(pattern: #"\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s*:?\s+#(\d+)"#, options: [.caseInsensitive])

    /// The issues a description closes ("Closes #42"), in order, once each
    static func linkedIssues(_ body: String) -> [Int] {
        var numbers: [Int] = []
        closingPattern?.enumerateMatches(in: body, range: NSRange(body.startIndex..., in: body)) { match, _, _ in
            guard let match, let range = Range(match.range(at: 1), in: body), let number = Int(body[range]), !numbers.contains(number) else { return }
            numbers.append(number)
        }
        return numbers
    }

    /// Review threads on one file
    static func threadCount(_ comments: [ReviewComment], path: String) -> Int {
        Set(comments.filter { $0.kind != .system && $0.path == path }.map { $0.threadID ?? $0.id }).count
    }

    /// "Viewed" marks belong to one head commit: a new push starts a new set
    static func viewedKey(repositoryKey: String, number: Int, headSHA: String) -> String { "\(repositoryKey)#\(number)@\(headSHA)" }
}

/// Which files of a request this device has marked as viewed. Kept locally; the server is not told.
enum PullRequestViewedStorage {
    private static let key = "pullRequestViewed.v1"

    static func load(_ id: String) -> Set<String> {
        Set((UserDefaults.standard.dictionary(forKey: key)?[id] as? [String]) ?? [])
    }

    static func save(_ id: String, _ paths: Set<String>) {
        var all = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        // one set per request: older head commits of the same request are dropped
        let prefix = id.components(separatedBy: "@").first.map { $0 + "@" } ?? id
        for other in all.keys where other.hasPrefix(prefix) { all[other] = nil }
        if !paths.isEmpty { all[id] = paths.sorted() }
        UserDefaults.standard.set(all, forKey: key)
    }
}
