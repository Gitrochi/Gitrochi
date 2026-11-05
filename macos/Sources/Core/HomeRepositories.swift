import Foundation

/// What Home says about the recent repositories and today's tasks (the redesign's Home board).
/// (Windows: entities/repo/model/home-repositories.ts)
enum HomeRepositories {
    /// "2 not pushed · 3 to pull", or "Up to date"
    static func sync(ahead: Int, behind: Int) -> String {
        var words: [String] = []
        if ahead > 0 { words.append(String(localized: "\(ahead) not pushed")) }
        if behind > 0 { words.append(String(localized: "\(behind) to pull")) }
        return words.isEmpty ? String(localized: "Up to date") : words.joined(separator: " · ")
    }

    /// When a repository was opened: Today, Yesterday, then the day, with the year only for another year
    static func opened(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days == 0 { return String(localized: "Today") }
        if days == 1 { return String(localized: "Yesterday") }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMd" : "yMMMd")
        return formatter.string(from: date)
    }

    /// The filter field matches the repository's name or any part of its path
    static func matches(_ url: URL, filter: String) -> Bool {
        let words = filter.trimmingCharacters(in: .whitespaces)
        return words.isEmpty || url.path.localizedCaseInsensitiveContains(words)
    }

    /// Today's tasks: what is overdue first, oldest first, then what is due today; at most five. Status and people
    /// stay on the Projects page.
    static func today(_ tasks: [ProjectPortfolioTask], today: String) -> [ProjectPortfolioTask] {
        let open = tasks.filter { !$0.entry.completed && !$0.entry.invalidRange && !$0.entry.invalidDate }
        let overdue = open.filter { $0.entry.due.map { $0 < today } == true }
            .sorted { ($0.entry.due ?? "", $0.entry.row.title) < ($1.entry.due ?? "", $1.entry.row.title) }
        let ids = Set(overdue.map(\.id))
        let due = open.filter { !ids.contains($0.id) && $0.entry.date == today }
            .sorted { $0.entry.row.title < $1.entry.row.title }
        return Array((overdue + due).prefix(5))
    }
}
