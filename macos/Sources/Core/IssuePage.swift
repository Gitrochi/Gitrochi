import Foundation

/// What the Issues page says about the issues assigned to you (the redesign's Issues board): which are in review, in
/// progress or not started, and the one step that comes next. Nothing here asks the server: an issue's work is what this
/// repository knows of it, its linked local branches and their requests. (Windows: entities/hosting/model/issue-page.ts)
enum IssuePage {
    enum Progress: String { case inReview, inProgress, notStarted }

    /// An assigned issue and how far its work is; `branch` is the linked local branch, if there is one
    struct Assigned: Equatable {
        let number: Int
        let progress: Progress
        var branch: String? = nil
    }

    /// In review when one of the issue's branches has an open request, in progress when it has a branch, else not started
    static func progress(branches: [String], requestBranches: Set<String>) -> Progress {
        if branches.contains(where: requestBranches.contains) { return .inReview }
        return branches.isEmpty ? .notStarted : .inProgress
    }

    struct Summary: Equatable {
        var inReview: [Int] = []
        var inProgress: [Int] = []
        var notStarted: [Int] = []

        var total: Int { inReview.count + inProgress.count + notStarted.count }

        /// The groups that have issues, the furthest along first, each in words: "#42 in review"
        var lines: [String] {
            var out: [String] = []
            if !inReview.isEmpty { out.append(String(localized: "\(IssuePage.numbers(inReview)) in review")) }
            if !inProgress.isEmpty { out.append(String(localized: "\(IssuePage.numbers(inProgress)) in progress")) }
            if !notStarted.isEmpty { out.append(String(localized: "\(IssuePage.numbers(notStarted)) not started")) }
            return out
        }

        /// What a screen reader hears for the bar: "1 in review, 2 not started"
        var counts: String {
            var out: [String] = []
            if !inReview.isEmpty { out.append(String(localized: "\(String(inReview.count)) in review")) }
            if !inProgress.isEmpty { out.append(String(localized: "\(String(inProgress.count)) in progress")) }
            if !notStarted.isEmpty { out.append(String(localized: "\(String(notStarted.count)) not started")) }
            return out.joined(separator: ", ")
        }
    }

    static func summary(_ items: [Assigned]) -> Summary {
        Summary(inReview: items.filter { $0.progress == .inReview }.map(\.number),
                inProgress: items.filter { $0.progress == .inProgress }.map(\.number),
                notStarted: items.filter { $0.progress == .notStarted }.map(\.number))
    }

    /// "#41", "#41 and #37", then a count: three numbers in a row are not read
    static func numbers(_ list: [Int]) -> String {
        switch list.count {
        case 1: return "#\(list[0])"
        case 2: return String(localized: "\("#\(list[0])") and \("#\(list[1])")")
        default: return String(localized: "\(list.count) issues")
        }
    }

    enum Next: Equatable {
        case createBranch(Int)
        case createRequest(Int, branch: String)
    }

    /// The one step the summary offers: a request for the issue this branch works on, else a branch for the first
    /// issue nobody started (the list is read oldest first)
    static func next(_ items: [Assigned], currentBranch: String?) -> Next? {
        if let currentBranch, let item = items.first(where: { $0.progress == .inProgress && $0.branch == currentBranch }) {
            return .createRequest(item.number, branch: currentBranch)
        }
        return items.first { $0.progress == .notStarted }.map { .createBranch($0.number) }
    }

    /// The count on the "Assigned to you" segment: none when nothing is assigned, "30+" when the server has more
    static func count(_ assigned: Int, more: Bool) -> String? {
        assigned == 0 ? nil : more ? "\(assigned)+" : String(assigned)
    }
}
