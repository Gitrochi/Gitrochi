import Foundation

/// What the Actions page shows of the runs it already has (the redesign's Actions board): the segments and their
/// counts, the list's search and order, this branch's recent runs, a run's jobs by result and the part of a log to
/// open on. Nothing here asks the server. (Windows: entities/ci/model/actions-page.ts)
enum ActionsPage {
    /// The list's filter; all but `all` are states that need attention or are live, so only they carry a count
    enum Segment: String, CaseIterable { case all, failed, running, waiting }

    static func segment(_ status: CIStatus) -> Segment? {
        switch status {
        case .failed: return .failed
        case .running, .pending, .created: return .running
        case .waiting, .manual, .scheduled: return .waiting
        default: return nil
        }
    }

    static func count(_ runs: [CIPipeline], _ segment: Segment) -> Int {
        segment == .all ? runs.count : runs.filter { self.segment($0.status) == segment }.count
    }

    /// The rows to show: the segment's runs that match the search (title, number, branch or workflow), in the chosen order
    static func visible(_ runs: [CIPipeline], segment: Segment, search: String, oldestFirst: Bool,
                        title: (CIPipeline) -> String) -> [CIPipeline] {
        let words = search.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = runs.filter { run in
            guard segment == .all || self.segment(run.status) == segment else { return false }
            guard !words.isEmpty else { return true }
            return [title(run), "#\(run.number)", run.ref, run.name].contains { $0.lowercased().contains(words) }
        }
        return oldestFirst ? shown.reversed() : shown
    }

    /// The workflow most runs belong to; rows name only the other ones
    static func commonWorkflow(_ runs: [CIPipeline]) -> String? {
        var counts: [String: Int] = [:], order: [String] = []
        for run in runs where !run.name.isEmpty {
            if counts[run.name] == nil { order.append(run.name) }
            counts[run.name, default: 0] += 1
        }
        return order.max { counts[$0]! < counts[$1]! }
    }

    /// The latest runs of this branch's newest workflow, oldest first, as the summary draws them: runs of different
    /// workflows side by side say nothing about each other
    static func history(_ runs: [CIPipeline], ref: String?, limit: Int = 3) -> [CIPipeline] {
        guard let ref else { return [] }
        let branch = runs.filter { $0.ref == ref }
        guard let workflow = branch.first?.name else { return [] }
        return Array(branch.filter { $0.name == workflow }.prefix(limit).reversed())
    }

    enum Streak: Equatable {
        case none
        /// The latest runs all passed
        case passing(Int)
        case failed(CIPipeline)
        case running(CIPipeline)
        case waiting(CIPipeline)
    }

    /// What the newest run of a history says: still going, waiting for someone, failed, or how many passed in a row
    static func streak(_ history: [CIPipeline]) -> Streak {
        guard let latest = history.last else { return .none }
        switch segment(latest.status) {
        case .running?: return .running(latest)
        case .waiting?: return .waiting(latest)
        case .failed?: return .failed(latest)
        default:
            let passed = history.reversed().prefix { $0.status == .success }.count
            return passed > 0 ? .passing(passed) : .none
        }
    }

    /// How long a finished run took, when the server said when it started and ended
    static func took(_ run: CIPipeline) -> TimeInterval? {
        guard run.status.isFinished, let start = run.started ?? run.created, let end = run.updated, end > start else { return nil }
        return end.timeIntervalSince(start)
    }

    /// The branch runs are compared with: main, or master where there is no main
    static func baseRef(_ branches: [String]) -> String? {
        ["main", "master"].first(where: branches.contains)
    }

    enum JobGroup: String, CaseIterable { case failed, running, waiting, passed, other }

    static func group(_ status: CIStatus) -> JobGroup {
        switch segment(status) {
        case .failed?: return .failed
        case .running?: return .running
        case .waiting?: return .waiting
        default: return status == .success ? .passed : .other
        }
    }

    /// A run's jobs by result, what failed first; groups without jobs are left out
    static func groups(_ jobs: [CIJob]) -> [(group: JobGroup, jobs: [CIJob])] {
        JobGroup.allCases.compactMap { group in
            let list = jobs.filter { self.group($0.status) == group }
            return list.isEmpty ? nil : (group, list)
        }
    }

    // MARK: Log

    /// The first line a log opens on: a few lines before its first error, or its last two hundred lines
    static func firstShown(_ lines: [String]) -> Int {
        if let error = lines.firstIndex(where: JobLog.isError) { return max(0, error - 3) }
        return max(0, lines.count - 200)
    }
}
