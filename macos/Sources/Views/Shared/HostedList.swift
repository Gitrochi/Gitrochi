import AppKit
import SwiftUI

// The parts the Issues and Actions pages share, as their boards draw them: the row above the page (where it is and its
// actions), the summary card, the 312 pt list column with its search, segments and two-line rows, and the page states
// of docs/design.md (empty, blocked, could not load). (Windows: shared/ui/HostedList.tsx)

enum HostedList {
    /// The list column's width (docs/design.md, Frames); it stays as drawn while the detail grows with the window
    static let column: CGFloat = 312
    /// Under this width the page shows the list or the detail, not both, and the summary becomes a strip
    static let compact: CGFloat = 680
    static let edge = Color.primary.opacity(0.16)
    static let caption = StudioStyle.Rail.icon

    /// Secondary text; a little darker on the selection tint, where the usual grey is too faint
    static func secondary(selected: Bool) -> Color { selected ? onSelection : caption }

    private static let onSelection = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.76, green: 0.76, blue: 0.78, alpha: 1) : NSColor(srgbRed: 0.353, green: 0.353, blue: 0.373, alpha: 1)
    })
}

/// The board's 28 pt button: a label, with an icon before it when it has one, in a hairline frame, and square for an
/// icon alone. A region's one filled button is the system's prominent style, which picks a label colour for any accent.
struct HostedListButtonStyle: ButtonStyle {
    var iconOnly = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(HostedListButtonLabel(iconOnly: iconOnly))
            .font(.system(size: 13))
            .lineLimit(1)
            // a disabled button is neutral, never faded (docs/design.md, Controls)
            .foregroundStyle(enabled ? Color.primary : StudioStyle.Rail.blocked)
            .padding(.horizontal, iconOnly ? 0 : 12)
            .frame(width: iconOnly ? 28 : nil, height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(enabled ? StudioStyle.surface : StudioStyle.canvas))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(HostedList.edge))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct HostedListButtonLabel: LabelStyle {
    let iconOnly: Bool
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 12))
            if !iconOnly { configuration.title }
        }
    }
}

extension View {
    /// A region's one filled button: the system's prominent style, as tall and as square-cornered as the buttons beside it
    func hostedListFilledButton() -> some View {
        buttonStyle(.borderedProminent).controlSize(.large).buttonBorderShape(.roundedRectangle(radius: 6))
    }
}

/// A 12 pt grey text button, at least 24 pt tall; a destructive one is red and comes last (docs/design.md, Controls)
struct HostedListTextButtonStyle: ButtonStyle {
    var destructive = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(!enabled ? StudioStyle.Rail.blocked : destructive ? StudioStyle.Tone.failed.text : HostedList.caption)
            .frame(minHeight: 24)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

/// The row above the page: which repository on which server, and the page's actions on the right
struct HostedListHeader<Actions: View>: View {
    let target: RepoTarget
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: "\(target.host) / \(target.path)").font(.system(size: 13)).foregroundStyle(HostedList.caption)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 10)
            actions
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }
}

/// The summary card every hosted page starts with: what it is about on the left, its picture in the middle and the one
/// next step on the right. In a narrow window it is a 44 pt strip with the same words on one line.
struct HostedListSummary<Lead: View, Middle: View, Trail: View, Strip: View>: View {
    let compact: Bool
    @ViewBuilder let lead: Lead
    @ViewBuilder let middle: Middle
    @ViewBuilder let trail: Trail
    @ViewBuilder let strip: Strip

    var body: some View {
        Group {
            if compact {
                HStack(spacing: 10) { strip }
                    .padding(.leading, 16).padding(.trailing, 10)
                    .frame(height: 44)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(StudioStyle.border))
                    .padding(.horizontal, 12).padding(.bottom, 10)
            } else {
                HStack(spacing: 32) {
                    VStack(alignment: .leading, spacing: 2) { lead }.frame(width: 220, alignment: .leading)
                    middle.frame(maxWidth: .infinity)
                    VStack(alignment: .trailing, spacing: 6) { trail }.frame(width: 200, alignment: .trailing)
                }
                .padding(.horizontal, 20)
                .frame(height: 112)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(StudioStyle.border))
                .padding(.horizontal, 20).padding(.bottom, 16)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// The summary's small grey line above its headline
struct HostedListSummaryCaption: View {
    let text: String
    var body: some View {
        Text(verbatim: text).font(.system(size: 12)).foregroundStyle(HostedList.caption).lineLimit(1)
    }
}

/// The list column's first row: the search field and, beside it, the sort (and filter) menu
struct HostedListSearch<Items: View>: View {
    let prompt: String
    @Binding var text: String
    /// What the menu button says on hover and to VoiceOver, with the choices that are on
    let menuTitle: String
    /// Enter searches; clearing searches again. A list that filters as you type passes nothing.
    var onSearch: (() -> Void)? = nil
    @ViewBuilder let menu: Items
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                DesignIconImage(icon: .search, size: 12).foregroundStyle(HostedList.caption)
                TextField(prompt, text: $text)
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .focused($focused)
                    .onSubmit { onSearch?() }
                    .onKeyPress(.escape) {
                        guard !text.isEmpty else { return .ignored }
                        text = ""; onSearch?()
                        return .handled
                    }
                if !text.isEmpty {
                    Button { text = ""; onSearch?() } label: { SymbolIcon("xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(HostedList.caption)
                        .help("Clear search").accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.surface))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? Color.accentColor.opacity(0.7) : HostedList.edge))
            Menu { menu } label: { DesignIconImage(icon: .sort, size: 12) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.surface))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(HostedList.edge))
                .help(menuTitle).accessibilityLabel(menuTitle)
        }
    }
}

/// The list's filter. A segment carries a count only when it needs attention or is live; a count appears once per screen.
struct HostedListSegments<Value: Hashable>: View {
    let options: [(value: Value, title: String, count: String?)]
    let selection: Value
    let onSelect: (Value) -> Void

    var body: some View {
        // drawn here, not a system picker: a segmented picker keeps its natural width and the filter fills its column
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let on = option.value == selection
                Button { if !on { onSelect(option.value) } } label: {
                    Text(verbatim: option.count.map { "\(option.title) \($0)" } ?? option.title)
                        .font(.system(size: 12, weight: .medium)).lineLimit(1).fixedSize()
                        .foregroundStyle(on ? Color.primary : StudioStyle.Tone.neutral.text)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity).frame(height: 24)
                        // the selected segment is a white thumb; the labels keep their weight so they never shift
                        .background(RoundedRectangle(cornerRadius: 4).fill(on ? StudioStyle.surface : Color.clear)
                            .shadow(color: .black.opacity(on ? 0.12 : 0), radius: 1, y: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.Tone.neutral.fill))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filter")
    }
}

/// A two-line list row: the selected one gets the tint and nothing else (no bar, no outline), any other the hover grey
struct HostedListRow<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let content: Content
    @ViewState private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) { content }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(selected ? StudioStyle.selection : hovered ? StudioStyle.hover : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A row's first line: the title in up to two lines and, opposite it, when the item last changed
struct HostedListRowTitle: View {
    let title: String
    let when: String?
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(verbatim: title).font(.system(size: 13, weight: selected ? .semibold : .medium)).lineLimit(2)
                .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            if let when {
                Text(verbatim: when).font(.system(size: 12)).foregroundStyle(HostedList.secondary(selected: selected)).fixedSize()
            }
        }
    }
}

/// A marker in a row or a meta line (a linked request, a branch, a run that waits); it turns white on the selection tint
struct HostedListChip: View {
    let title: String
    var symbol: String? = nil
    var selected = false
    /// Chips in a meta line are squarer than the pills of a row
    var square = false
    var tone = StudioStyle.Tone.neutral

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { SymbolIcon(symbol).font(.system(size: 10, weight: .semibold)).accessibilityHidden(true) }
            Text(verbatim: title).lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(tone.text)
        .padding(.horizontal, 8)
        .frame(height: 18)
        .background(RoundedRectangle(cornerRadius: square ? 6 : 9).fill(selected ? StudioStyle.surface : tone.fill))
    }
}

/// An empty or blocked page or column: a 24 pt grey icon, one 15 pt line, one caption and one action, which is filled
/// only when the state blocks the user (docs/design.md, Controls)
struct HostedListEmpty: View {
    let symbol: String
    let title: String
    var caption: String? = nil
    var actionTitle: String? = nil
    var filled = false
    /// A failed load shows the failed icon in its tone; the words say it too
    var failed = false
    var action: () -> Void = {}

    var body: some View {
        VStack(spacing: 8) {
            SymbolIcon(symbol).font(.system(size: 24)).foregroundStyle(failed ? StudioStyle.Tone.failed.text : HostedList.caption)
                .accessibilityHidden(true)
            Text(verbatim: title).font(.system(size: 15, weight: .semibold)).multilineTextAlignment(.center)
            if let caption {
                Text(verbatim: caption).font(.system(size: 12)).foregroundStyle(HostedList.caption).multilineTextAlignment(.center)
                    .frame(maxWidth: 380).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if let actionTitle {
                if filled {
                    Button(actionTitle, action: action).hostedListFilledButton().padding(.top, 4)
                } else {
                    Button(actionTitle, action: action).buttonStyle(HostedListButtonStyle()).padding(.top, 4)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A list could not be refreshed and its last items stay: white with a hairline, the failed icon, what happened in
/// the failed tone, how old the data is, and Retry
struct HostedListNotice: View {
    let title: String
    var caption: String? = nil
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SymbolIcon("xmark.circle.fill").font(.system(size: 14)).foregroundStyle(StudioStyle.Tone.failed.text).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(.system(size: 13, weight: .semibold)).foregroundStyle(StudioStyle.Tone.failed.text)
                if let caption { Text(verbatim: caption).font(.system(size: 12)).foregroundStyle(HostedList.caption) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Retry", action: retry).buttonStyle(HostedListButtonStyle())
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.surface))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(StudioStyle.border))
    }
}

/// A list on its way: the words first, then three grey rows where the items will be
struct HostedListLoading: View {
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(verbatim: caption).font(.system(size: 12)).foregroundStyle(HostedList.caption)
            }
            ForEach([0.78, 0.64, 0.82], id: \.self) { share in
                VStack(alignment: .leading, spacing: 4) {
                    bar(height: 12, share: share)
                    bar(height: 10, share: share * 0.55)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bar(height: CGFloat, share: Double) -> some View {
        GeometryReader { geometry in
            RoundedRectangle(cornerRadius: 4).fill(StudioStyle.Tone.neutral.fill).frame(width: geometry.size.width * share)
        }
        .frame(height: height)
    }
}

/// "Showing data from 12m ago", for a list that could not be refreshed
func hostedListAge(_ date: Date?, locale: Locale) -> String? {
    date.map { String(localized: "Showing data from \(ListDate.when($0, locale: locale))") }
}
