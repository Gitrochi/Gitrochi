import Foundation

/// How a list row dates its item (docs/design.md, Dates): within 24 hours "12m ago" or "2h ago", then "Yesterday",
/// then the day, with the year only for another year. (Windows: shared/lib/list-date.ts)
enum ListDate {
    static func when(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 60 { return String(localized: "Just now") }
        if elapsed < 3600 { return String(localized: "\(Int(elapsed / 60))m ago") }
        if elapsed < 86_400 { return String(localized: "\(Int(elapsed / 3600))h ago") }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        return days <= 1 ? String(localized: "Yesterday") : day(date, now: now, calendar: calendar, locale: locale)
    }

    /// "Oct 28", or "Dec 30, 2025" for another year
    static func day(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMd" : "yMMMd")
        return formatter.string(from: date)
    }

    /// The hosting servers' ISO 8601 dates, with or without fractions of a second
    static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}
