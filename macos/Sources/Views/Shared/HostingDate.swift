import SwiftUI

/// A readable timestamp keeps its complete date available on hover.
struct HostingDate: View {
    let value: String?
    var published = false
    var label: String? = nil
    @Environment(\.locale) private var locale
    private var date: Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withFullDate]
        return formatter.date(from: value)
    }
    var body: some View {
        if let date {
            let formatter = RelativeDateTimeFormatter()
            let _ = formatter.locale = locale
            let short = abs(date.timeIntervalSinceNow) < 7 * 86_400 ? formatter.localizedString(for: date, relativeTo: Date()) : date.formatted(.dateTime.year().month(.abbreviated).day().locale(locale))
            let full = date.formatted(.dateTime.year().month(.wide).day().hour().minute().locale(locale))
            let template = published ? "Published {0}" : label
            Label(template.map { String(localized: String.LocalizationValue($0)).replacingOccurrences(of: "{0}", with: short) } ?? short, systemImage: "calendar")
                .font(.caption).foregroundStyle(.secondary).help(full).accessibilityLabel(full)
        } else { Text("Date unavailable").font(.caption).foregroundStyle(.secondary) }
    }
}
