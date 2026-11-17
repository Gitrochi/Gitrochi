import SwiftUI

/// Where the open file sits among a list of files, and the step to the one before or after it (the diff header's
/// "2 / 6" with its previous and next buttons)
struct CodeFilePosition {
    let index: Int
    let count: Int
    let step: (Int) -> Void
}

/// The one diff header (docs/design.md, Shared components): a 44 pt row with the way back where the screen has one,
/// the status badge, the file name and its folder on the left; the file's position with previous and next, Unified |
/// Split, Hide whitespace, Ask AI… and More on the right. When the row is narrow the folder goes first, then the
/// position, then Ask AI… and Hide whitespace move into More, and only then is the name cut.
/// (Windows: shared/ui/DiffHeader.tsx)
struct DiffHeader<Accessory: View, More: View>: View {
    struct Back {
        let title: LocalizedStringKey
        let help: LocalizedStringKey
        let action: () -> Void
    }

    struct Ask {
        var disabled = false
        let action: () -> Void
    }

    @Environment(RepoStore.self) private var store
    var back: Back?
    var kind: ChangeKind?
    let path: String
    /// What the name says on hover instead of the whole path
    var help: String?
    var position: CodeFilePosition?
    /// false where the content has one layout only (blame)
    var layout = true
    /// Why Split cannot be chosen here; the stored preference stays
    var splitDisabledReason: String?
    var whitespace = true
    var ask: Ask?
    /// The screen's own controls, before the layout (History | Blame)
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var more: () -> More

    /// What is still in the row at one width
    private struct Fold: Hashable {
        var folder = ""
        var position = true
        var ask = true
        var whitespace = true
        var cut = false
    }

    private var folds: [Fold] {
        var result = Self.folders(path).map { Fold(folder: $0) }
        var fold = Fold()
        result.append(fold)
        if position != nil { fold.position = false; result.append(fold) }
        if ask != nil { fold.ask = false; result.append(fold) }
        if whitespace { fold.whitespace = false; result.append(fold) }
        fold.cut = true
        result.append(fold)
        return result
    }

    var body: some View {
        let _ = store.diffSettingsVersion
        HStack(spacing: 8) {
            // outside the candidates: Esc belongs to one button
            if let back { GraphBackButton(title: back.title, help: back.help, action: back.action) }
            ViewThatFits(in: .horizontal) {
                ForEach(folds, id: \.self) { row($0) }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    private func row(_ fold: Fold) -> some View {
        HStack(spacing: 8) {
            if let kind { StatusBadge(kind: kind) }
            if fold.cut {
                Text(verbatim: (path as NSString).lastPathComponent).font(.system(size: 13, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle).help(help ?? path)
            } else {
                Text(verbatim: (path as NSString).lastPathComponent).font(.system(size: 13, weight: .semibold))
                    .lineLimit(1).fixedSize().help(help ?? path)
            }
            if !fold.folder.isEmpty {
                Text(verbatim: fold.folder).font(.system(size: 11)).foregroundStyle(StudioStyle.Rail.icon).lineLimit(1).fixedSize()
                    .help((path as NSString).deletingLastPathComponent)
            }
            Spacer(minLength: 0)
            if let position, fold.position {
                HStack(spacing: 4) {
                    Text(verbatim: "\(position.index + 1) / \(position.count)").font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(StudioStyle.Rail.icon).padding(.trailing, 4).fixedSize()
                    Button { position.step(-1) } label: { DesignIconImage(icon: .chevronUp, size: 13) }
                        .buttonStyle(PullRequestIconButtonStyle()).disabled(position.index == 0)
                        .help("Previous file (K)").accessibilityLabel("Previous file (K)")
                    Button { position.step(1) } label: { DesignIconImage(icon: .chevronDown, size: 13) }
                        .buttonStyle(PullRequestIconButtonStyle()).disabled(position.index + 1 >= position.count)
                        .help("Next file (J)").accessibilityLabel("Next file (J)")
                }
            }
            accessory()
            if layout {
                Segmented(label: "Diff layout", items: [
                    .init(value: false, title: String(localized: "Unified")),
                    .init(value: true, title: String(localized: "Split"), disabledReason: splitDisabledReason),
                ], selection: store.diffSplit && splitDisabledReason == nil) { store.diffSplit = $0 }
            }
            if whitespace, fold.whitespace {
                let hidden = store.diffIgnoreWhitespace
                Button { store.diffIgnoreWhitespace.toggle() } label: { DesignIconImage(icon: .whitespace, size: 13) }
                    .buttonStyle(PullRequestIconButtonStyle(on: hidden))
                    .help("Hide whitespace").accessibilityLabel("Hide whitespace")
                    .accessibilityValue(hidden ? String(localized: "On") : String(localized: "Off"))
                    .accessibilityAddTraits(hidden ? .isSelected : [])
            }
            if let ask, fold.ask {
                Button("Ask AI…", action: ask.action)
                    .buttonStyle(PullRequestTextButtonStyle())
                    .disabled(ask.disabled)
                    .help("Ask questions about the selected changes")
                    .fixedSize()
            }
            Menu {
                // what the row had no room for comes first, in the row's order
                if let position, !fold.position {
                    Button("Previous file (K)") { position.step(-1) }.disabled(position.index == 0)
                    Button("Next file (J)") { position.step(1) }.disabled(position.index + 1 >= position.count)
                    Divider()
                }
                if whitespace, !fold.whitespace {
                    Toggle("Hide whitespace", isOn: Binding(get: { store.diffIgnoreWhitespace }, set: { store.diffIgnoreWhitespace = $0 }))
                }
                if let ask, !fold.ask {
                    Button("Ask AI…", action: ask.action).disabled(ask.disabled)
                    Divider()
                }
                more()
            } label: {
                DesignIconImage(icon: .more, size: 13).foregroundStyle(StudioStyle.Rail.icon)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("More file actions").accessibilityLabel("More file actions")
        }
    }

    /// The folder as the row shows it, widest first: the last two segments behind "…/", then the last one
    /// ("macos/Sources/Views/Search" is "…/Views/Search", then "…/Search")
    static func folders(_ path: String) -> [String] {
        let parts = path.split(separator: "/").dropLast()
        guard let last = parts.last else { return [] }
        let two = parts.count > 2 ? "…/" + parts.suffix(2).joined(separator: "/") : parts.joined(separator: "/")
        let one = (parts.count > 1 ? "…/" : "") + last
        return two == one ? [two] : [two, one]
    }
}

extension DiffHeader where Accessory == EmptyView {
    init(back: Back? = nil, kind: ChangeKind? = nil, path: String, help: String? = nil, position: CodeFilePosition? = nil, layout: Bool = true,
         splitDisabledReason: String? = nil, whitespace: Bool = true, ask: Ask? = nil, @ViewBuilder more: @escaping () -> More) {
        self.init(back: back, kind: kind, path: path, help: help, position: position, layout: layout, splitDisabledReason: splitDisabledReason,
                  whitespace: whitespace, ask: ask, accessory: { EmptyView() }, more: more)
    }
}

/// "‹ Graph" in a diff or file history header: a text button, then a hairline before the file (the Changes board's
/// diff header). Esc presses it.
struct GraphBackButton: View {
    let title: LocalizedStringKey
    let help: LocalizedStringKey
    let action: () -> Void
    @ViewState private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: action) {
                HStack(spacing: 4) {
                    DesignIconImage(icon: .chevronLeft, size: 12)
                    Text(title).lineLimit(1).fixedSize()
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(StudioStyle.Tone.neutral.text)
                .padding(.leading, 4).padding(.trailing, 8)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? StudioStyle.hover : Color.clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .keyboardShortcut(.escape, modifiers: [])
            .help(help)
            .padding(.leading, -4)
            Rectangle().fill(StudioStyle.border).frame(width: 1, height: 16).accessibilityHidden(true)
        }
    }
}
