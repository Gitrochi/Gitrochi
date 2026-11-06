import SwiftUI

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
                        if let symbol = item.symbol { SymbolIcon(symbol).font(.system(size: 11, weight: .medium)) }
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
