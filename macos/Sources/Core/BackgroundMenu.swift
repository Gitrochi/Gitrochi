import Foundation

/// What the menu bar menu lists while Gitrochi keeps running: the next scheduled runs, the open repositories with their
/// terminal tabs, recent repositories to open, then the app's own commands. Pure, so it mirrors the tested Windows
/// functions. (Windows: app/lib/background-menu.ts, tested in windows/tests/background-menu.test.ts)
enum BackgroundMenu {
    /// How many scheduled runs and recent repositories the menu lists (Windows: menuRunLimit, menuRecentLimit)
    static let runLimit = 5
    static let recentLimit = 5

    struct Terminal: Equatable {
        let id: UUID
        let title: String
        /// The tab mark's word: "Running", "Waiting for input" …
        let state: String
    }

    struct Repository: Equatable {
        let path: String
        let name: String
        /// The terminals still alive, in tab order
        let terminals: [Terminal]
    }

    enum Item: Equatable {
        case header(String)
        /// A line that cannot be chosen ("No scheduled runs")
        case note(String)
        case separator
        case run(title: String, path: String)
        case repository(title: String, path: String)
        case terminal(title: String, path: String, id: UUID)
        case recent(title: String, path: String)
        case open, settings, quit
    }

    /// The runs still to start, soonest first (Windows: upcomingRuns)
    static func upcoming(_ runs: [ScheduledRun], limit: Int = runLimit) -> [ScheduledRun] {
        Array(runs.filter { $0.state == .scheduled }.sorted { $0.runAt < $1.runAt }.prefix(limit))
    }

    /// "Nov 18, 12:30 PM · demo · Deploy (main)" (Windows: runLine)
    static func runLine(_ run: ScheduledRun, time: String) -> String {
        "\(time) · \(name(of: run.repoPath)) · \(run.workflowName ?? String(localized: "Pipeline")) (\(run.ref))"
    }

    /// Recent repositories that are not open, most recent first (Windows: recentToOpen)
    static func recentToOpen(_ recents: [String], open: [String], same: (String, String) -> Bool, limit: Int = recentLimit) -> [String] {
        Array(recents.filter { recent in !open.contains { same($0, recent) } }.prefix(limit))
    }

    /// The whole menu, top to bottom (Windows: backgroundMenu)
    static func items(runs: [ScheduledRun], time: (Date) -> String, repositories: [Repository], recents: [String],
                      same: (String, String) -> Bool) -> [Item] {
        var items: [Item] = [.header(String(localized: "Scheduled runs"))]
        let next = upcoming(runs)
        if next.isEmpty {
            items.append(.note(String(localized: "No scheduled runs")))
        } else {
            items += next.map { .run(title: runLine($0, time: time($0.runAt)), path: $0.repoPath) }
        }
        if !repositories.isEmpty {
            items += [.separator, .header(String(localized: "Open repositories"))]
            for repository in repositories {
                items.append(.repository(title: repository.name, path: repository.path))
                items += repository.terminals.map { .terminal(title: "\($0.title) — \($0.state)", path: repository.path, id: $0.id) }
            }
        }
        let recent = recentToOpen(recents, open: repositories.map(\.path), same: same)
        if !recent.isEmpty {
            items += [.separator, .header(String(localized: "Recent repositories"))]
            items += recent.map { .recent(title: name(of: $0), path: $0) }
        }
        return items + [.separator, .open, .settings, .separator, .quit]
    }

    /// What quitting stops, or nil when nothing would: "2 scheduled runs won't start. 1 terminal session will end."
    /// (Windows: quitWarning)
    static func quitWarning(scheduled: Int, terminals: Int) -> String? {
        var lines: [String] = []
        if scheduled == 1 {
            lines.append(String(localized: "1 scheduled run won't start."))
        } else if scheduled > 1 {
            lines.append(String(localized: "\(scheduled) scheduled runs won't start."))
        }
        if terminals == 1 {
            lines.append(String(localized: "1 terminal session will end."))
        } else if terminals > 1 {
            lines.append(String(localized: "\(terminals) terminal sessions will end."))
        }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }

    /// Runs that would not start if the app quit now (Windows: pendingRunCount)
    static func pendingRuns(_ runs: [ScheduledRun]) -> Int {
        runs.filter { $0.state == .scheduled }.count
    }

    private static func name(of path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}
