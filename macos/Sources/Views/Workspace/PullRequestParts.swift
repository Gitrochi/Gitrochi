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

/// A text button: 12pt medium in the caption grey, at least 24pt tall; a destructive one is red and comes last
struct PullRequestTextButtonStyle: ButtonStyle {
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(destructive ? StudioStyle.Tone.failed.text : StudioStyle.Rail.icon)
            .frame(minHeight: 24)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

/// A 24pt icon button; `on` draws a toggle's on state as a neutral fill and a primary glyph
struct PullRequestIconButtonStyle: ButtonStyle {
    var on = false

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, on: on)
    }

    private struct Face: View {
        @Environment(\.isEnabled) private var enabled
        @ViewState private var hovered = false
        let configuration: Configuration
        let on: Bool

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(!enabled ? AnyShapeStyle(.quaternary) : on ? AnyShapeStyle(.primary) : AnyShapeStyle(StudioStyle.Tone.neutral.text))
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(on ? StudioStyle.Tone.neutral.fill : hovered && enabled ? StudioStyle.hover : Color.clear))
                .opacity(configuration.isPressed ? 0.6 : 1)
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
        }
    }
}

/// The neutral segmented control for filters and modes: a white thumb on a grey track, labels that never change weight
struct PullRequestSegmented<Value: Hashable>: View {
    struct Item {
        let value: Value
        var title: String = ""
        var symbol: String?
        var label: String?
        var disabledReason: String?
    }

    let label: LocalizedStringKey
    let items: [Item]
    let selection: Value?
    /// Segments share the width (a filter row) or hug their labels (a mode switch)
    var fill = false
    let select: (Value) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.value) { item in
                let on = item.value == selection, disabled = item.disabledReason != nil
                Button { select(item.value) } label: {
                    Group {
                        if let symbol = item.symbol { Image(systemName: symbol).font(.system(size: 11, weight: .medium)) }
                        // a label is never cut: segments grow from their own width
                        else { Text(verbatim: item.title).lineLimit(1).fixedSize() }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(disabled ? AnyShapeStyle(.tertiary) : on ? AnyShapeStyle(.primary) : AnyShapeStyle(StudioStyle.Tone.neutral.text))
                    .padding(.horizontal, 8)
                    .frame(maxWidth: fill ? .infinity : nil).frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 4).fill(on ? StudioStyle.surface : Color.clear).shadow(color: .black.opacity(on ? 0.12 : 0), radius: 1, y: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(disabled)
                // a disabled segment says why, on hover and to VoiceOver
                .help(item.disabledReason ?? item.label ?? "")
                .accessibilityLabel(item.label ?? item.title)
                .accessibilityHint(Text(verbatim: item.disabledReason ?? ""))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.Tone.neutral.fill))
        .fixedSize(horizontal: !fill, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
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
