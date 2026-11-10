import Foundation

/// What the Account page says about a notification or a piece of open work (the redesign's Account board): why it is
/// in the inbox, when it changed, and which rows the search, the unread filter and the sort order leave.
/// (Windows: features/account-work/lib/account-inbox.ts)
enum AccountInbox {
    /// Why an item is in the inbox. The servers name more reasons than these; the rest are plain updates.
    enum Reason: Equatable { case review, mention, assigned, ciFailed, ci, update }

    static func reason(_ item: AccountWorkItem) -> Reason {
        switch item.reason {
        case "review_requested", "approval_requested", "approval_required": return .review
        case "mention", "team_mention", "mentioned", "directly_addressed": return .mention
        case "assign", "assigned": return .assigned
        case "build_failed": return .ciFailed
        // GitHub says only that a run finished; the title says how it ended
        case "ci_activity": return item.title.range(of: "fail", options: .caseInsensitive) != nil ? .ciFailed : .ci
        default: return .update
        }
    }

    /// "Mentioned by Sam" when the server names who did it, "Mentioned" otherwise
    static func label(_ reason: Reason, actor: String = "") -> String {
        switch reason {
        case .review: return String(localized: "Review requested")
        case .mention: return actor.isEmpty ? String(localized: "Mentioned") : String(localized: "Mentioned by \(actor)")
        case .assigned: return String(localized: "Assigned")
        case .ciFailed: return String(localized: "CI failed")
        case .ci: return String(localized: "CI run")
        case .update: return String(localized: "Updated")
        }
    }

    /// "#57", or nothing for what has no number (a release, a run)
    static func reference(_ item: AccountWorkItem) -> String { item.number > 0 ? "#\(item.number)" : "" }

    /// "desktop" of "sample-studio/desktop": a row has room for the name; the detail shows the whole path
    static func repositoryName(_ path: String) -> String { path.split(separator: "/").last.map(String.init) ?? path }

    /// docs/design.md, Dates: "12m ago" and "2h ago" within 24 hours, then "Yesterday", then the day, with the year only
    /// for another year
    static func when(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return String(localized: "Just now") }
        if minutes < 60 { return String(localized: "\(minutes)m ago") }
        if minutes < 24 * 60 { return String(localized: "\(minutes / 60)h ago") }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days == 1 { return String(localized: "Yesterday") }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMd" : "yMMMd")
        return formatter.string(from: date)
    }

    /// The search covers the title, the repository, the number and, in the inbox, the reason
    static func matches(_ item: AccountWorkItem, search: String) -> Bool {
        let words = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return true }
        let why = item.reason.isEmpty ? "" : label(reason(item), actor: item.actor)
        return [item.title, item.repository, reference(item), why].contains { $0.range(of: words, options: .caseInsensitive) != nil }
    }

    /// The rows the list shows: the search and the unread filter applied, then newest or oldest first. Rows that
    /// changed at the same time, or carry no time, keep the order the server gave them.
    static func visible(_ items: [AccountWorkItem], search: String, unreadOnly: Bool, oldestFirst: Bool) -> [AccountWorkItem] {
        let rows = items.filter { (!unreadOnly || $0.unread) && matches($0, search: search) }
        return rows.enumerated().sorted { a, b in
            let left = a.element.updated ?? .distantPast, right = b.element.updated ?? .distantPast
            if left == right { return a.offset < b.offset }
            return oldestFirst ? left < right : left > right
        }.map(\.element)
    }

    /// The rows that changed today and the earlier ones, each in the order given
    static func groups(_ items: [AccountWorkItem], now: Date = Date(), calendar: Calendar = .current) -> (today: [AccountWorkItem], earlier: [AccountWorkItem]) {
        let today = items.filter { item in item.updated.map { calendar.isDate($0, inSameDayAs: now) } == true }
        let ids = Set(today.map(\.id))
        return (today, items.filter { !ids.contains($0.id) })
    }

    /// Whether the item is a request or an issue of the open repository, which a page of the app can show
    static func isLocal(_ item: AccountWorkItem, host: String?, path: String?) -> Bool {
        guard let host, let path, item.number > 0, item.kind != .other else { return false }
        return item.host.caseInsensitiveCompare(host) == .orderedSame && item.repository.caseInsensitiveCompare(path) == .orderedSame
    }
}
