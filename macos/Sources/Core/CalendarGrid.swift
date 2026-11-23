import Foundation

/// The arithmetic behind the date and time field: a month's grid of days, the times of day to pick from, and a few
/// ready-made moments. Local time throughout. (Windows: shared/lib/calendar.ts)
enum CalendarGrid {
    struct Day: Hashable { let date: Date; let day: Int; let inMonth: Bool }

    /// Six weeks of days covering the month of `month`, starting on the calendar's first weekday, so the grid keeps its
    /// height from month to month
    static func month(_ month: Date, calendar: Calendar = .current) -> [Day] {
        let first = calendar.date(from: calendar.dateComponents([.year, .month], from: month)) ?? month
        let lead = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        let shown = calendar.component(.month, from: first)
        return (0..<42).compactMap { i in
            guard let date = calendar.date(byAdding: .day, value: i - lead, to: first) else { return nil }
            return Day(date: date, day: calendar.component(.day, from: date), inMonth: calendar.component(.month, from: date) == shown)
        }
    }

    /// Minutes after midnight, every `step` minutes
    static func slots(step: Int = 15) -> [Int] { Array(stride(from: 0, to: 1440, by: step)) }

    /// `date` moved to another day, keeping its time of day
    static func with(day: Date, from date: Date, calendar: Calendar = .current) -> Date {
        let time = calendar.dateComponents([.hour, .minute], from: date)
        return calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: day) ?? day
    }

    /// `date` at another time of the same day
    static func with(minutes: Int, from date: Date, calendar: Calendar = .current) -> Date {
        calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: date) ?? date
    }

    static func minutes(of date: Date, calendar: Calendar = .current) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    enum Preset: String { case hour, tonight, tomorrow }

    /// In an hour (rounded up to five minutes), tonight at 21:00 while that is ahead, tomorrow at 9:00
    static func presets(now: Date, calendar: Calendar = .current) -> [(Preset, Date)] {
        let five: TimeInterval = 300
        let hour = Date(timeIntervalSince1970: ((now.timeIntervalSince1970 + 3600) / five).rounded(.up) * five)
        let tonight = with(minutes: 21 * 60, from: now, calendar: calendar)
        let tomorrowDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let tomorrow = with(minutes: 9 * 60, from: tomorrowDay, calendar: calendar)
        return [(.hour, hour)] + (tonight > now ? [(.tonight, tonight)] : []) + [(.tomorrow, tomorrow)]
    }
}
