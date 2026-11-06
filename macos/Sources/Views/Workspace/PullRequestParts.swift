import SwiftUI

/// The controls the Pull requests page draws as its boards do (docs/design.md › Controls): 28pt buttons, 12pt text
/// buttons, 24pt icon buttons, the neutral segmented control and underline tabs.
/// (Windows: Button, Segmented and the classes of widgets/inspector/ui/pull-request.css)

/// A 28pt button: plain in a hairline frame, or the region's one filled button. Disabled is neutral, never faded.
struct PullRequestButtonStyle: ButtonStyle {
    var filled = false
    /// An icon alone in a 28pt square
    var iconOnly = false

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, filled: filled, iconOnly: iconOnly)
    }

    private struct Face: View {
        @Environment(\.isEnabled) private var enabled
        let configuration: Configuration
        let filled: Bool
        let iconOnly: Bool

        var body: some View {
            configuration.label
                .labelStyle(PullRequestButtonLabel(enabled: enabled, filled: filled))
                .font(.system(size: 13))
                .lineLimit(1)
                .foregroundStyle(!enabled ? AnyShapeStyle(.tertiary) : filled ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
                .padding(.horizontal, iconOnly ? 0 : 12)
                .frame(width: iconOnly ? 28 : nil, height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(!enabled ? AnyShapeStyle(StudioStyle.Tone.neutral.fill.opacity(0.6)) : filled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(StudioStyle.surface)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(filled && enabled ? Color.clear : Color.primary.opacity(enabled ? 0.16 : 0.09)))
                .opacity(configuration.isPressed ? 0.7 : 1)
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .fixedSize()
        }
    }
}

private struct PullRequestButtonLabel: LabelStyle {
    let enabled: Bool
    let filled: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 12))
                .foregroundStyle(!enabled ? AnyShapeStyle(.quaternary) : filled ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
            configuration.title
        }
    }
}

/// A pill whose fill the row decides: on the selected (tinted) row pills turn to the surface colour so they stay visible
struct PullRequestRowPill: View {
    let title: String
    var symbol: String?
    /// A marker (This branch) carries a 6pt accent dot instead of an icon
    var marker = false
    let tone: StudioStyle.Tone
    var onSelection = false

    var body: some View {
        HStack(spacing: marker ? 5 : 4) {
            if marker { Circle().fill(Color.accentColor).frame(width: 6, height: 6) }
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
            Text(verbatim: title).lineLimit(1)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(tone.text)
        .padding(.horizontal, 8)
        .frame(height: 18)
        .background(Capsule().fill(onSelection ? StudioStyle.surface : tone.fill))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

/// A side card of the conversation: a hairline frame, a grey 12pt title, rows 8pt apart
struct PullRequestCard<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(StudioStyle.Rail.icon)
            content
        }
        .font(.system(size: 13))
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(StudioStyle.border))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// Dates as docs/design.md writes them: relative within a day, then "Yesterday", then "Oct 28"
enum PullRequestDate {
    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = AppLanguage.locale
        formatter.unitsStyle = .short
        return formatter
    }()

    static func short(_ date: Date, now: Date = Date()) -> String {
        switch PullRequestPage.dateStyle(age: now.timeIntervalSince(date)) {
        case .relative: return relative.localizedString(for: date, relativeTo: now)
        case .yesterday: return String(localized: "Yesterday")
        case .day: return date.formatted(.dateTime.month(.abbreviated).day().locale(AppLanguage.locale))
        }
    }
}

/// A file's folder beside its name: shortened from the start by whole segments, hidden when not even the last one fits
struct PullRequestFolderLabel: View {
    let path: String
    var color = StudioStyle.Rail.icon

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(PullRequestPage.folderLabels(path), id: \.self) { Text(verbatim: $0).lineLimit(1).fixedSize() }
            Color.clear.frame(width: 0, height: 0)
        }
        .font(.system(size: 11)).foregroundStyle(color)
        .help((path as NSString).deletingLastPathComponent)
    }
}

/// The page's secondary text: 12pt in the caption grey
struct PullRequestCaption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(verbatim: text).font(.system(size: 12)).foregroundStyle(StudioStyle.Rail.icon).fixedSize(horizontal: false, vertical: true)
    }
}
