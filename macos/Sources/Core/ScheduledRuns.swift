import Foundation

/// A workflow (GitHub) or pipeline (GitLab) run the app starts once, later. It keeps enough to find the saved account
/// again and never a token: the token is read when the run starts. (Windows: entities/ci/model/scheduled-runs.ts)
struct ScheduledRun: Codable, Identifiable, Hashable {
    enum State: String, Codable { case scheduled, missed, failed }

    struct Variable: Codable, Hashable {
        let key: String
        let value: String
    }

    var id = UUID().uuidString
    /// The repository folder it was scheduled from; that repository's Actions page lists it
    let repoPath: String
    let provider: Provider
    let host: String
    let remote: String
    /// owner/repo, group/sub/repo
    let path: String
    /// The saved account whose token starts the run
    let accountID: String
    /// GitHub: the workflow_dispatch workflow
    var workflowID: Int?
    var workflowName: String?
    let ref: String
    var inputs: [String: String] = [:]
    /// GitLab: the pipeline variables, in the order given
    var variables: [Variable] = []
    let runAt: Date
    var createdAt = Date()
    var state = State.scheduled
    /// Why the start failed
    var message: String?

    var target: RepoTarget { RepoTarget(provider: provider, remote: remote, host: host, path: path) }
}

/// When a scheduled run starts and how its time reads. Pure, so it mirrors the tested Windows functions.
/// (Windows: entities/ci/model/scheduled-runs.ts)
enum ScheduledRuns {
    /// How late a check may find a run and still start it; any later and it waits for a click (Windows: scheduleGrace)
    static let grace: TimeInterval = 120
    /// How often the app looks for runs that are due (Windows: scheduleInterval)
    static let interval: TimeInterval = 30

    enum Action: Equatable { case wait, start, miss }

    /// The sheet's first time: the next full hour (Windows: nextFullHour)
    static func nextFullHour(after now: Date, calendar: Calendar = .current) -> Date {
        let hour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        return calendar.date(byAdding: .hour, value: 1, to: hour) ?? hour.addingTimeInterval(3600)
    }

    /// Only a time still ahead can be scheduled (Windows: canSchedule)
    static func canSchedule(_ at: Date, now: Date) -> Bool { at > now }

    /// What a check does with a run. One found more than `grace` late (the app was closed or the computer slept) is
    /// missed and never starts on its own. (Windows: scheduledRunAction)
    static func action(_ run: ScheduledRun, now: Date) -> Action {
        guard run.state == .scheduled, now >= run.runAt else { return .wait }
        return now.timeIntervalSince(run.runAt) <= grace ? .start : .miss
    }

    /// "in 5m", "in 2h", "in 3d"; a time gone by reads like a list date, "12m ago" (Windows: scheduledRunRelative)
    static func relative(_ at: Date, now: Date, locale: Locale = .current) -> String {
        let left = at.timeIntervalSince(now)
        if left <= 0 { return ListDate.when(at, now: now, locale: locale) }
        let minutes = Int((left / 60).rounded(.up))
        if minutes < 60 { return String(localized: "in \(minutes)m") }
        if minutes < 1440 { return String(localized: "in \(minutes / 60)h") }
        return String(localized: "in \(minutes / 1440)d")
    }

    /// "Nov 12, 2:00 PM", with the year only for another year (Windows: scheduledRunTime)
    static func time(_ at: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let sameYear = calendar.component(.year, from: at) == calendar.component(.year, from: now)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMdjmm" : "yMMMdjmm")
        return formatter.string(from: at)
    }
}
