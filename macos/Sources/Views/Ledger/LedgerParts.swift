import SwiftUI

// Small pieces the Ledger views share. They only combine existing styles and system colours: the verdict chip is the
// tinted capsule of GitchResultPill, lane colours come from the commit graph's Palette.

extension LedgerVerdict {
    /// The contract's colours: orange, the accent (outlined for To confirm), green, red, and the secondary and
    /// tertiary text colours for what needs nobody
    var color: Color {
        switch self {
        case .needsHuman: return Color(nsColor: .systemOrange)
        case .pendingMerge, .confirm: return .accentColor
        case .expirable: return Color(nsColor: .systemGreen)
        case .stale: return Color(nsColor: .systemRed)
        case .active: return Color(nsColor: .secondaryLabelColor)
        case .shelved, .archived: return Color(nsColor: .tertiaryLabelColor)
        }
    }

    var outlined: Bool { self == .confirm }
}

enum LedgerTime {
    static func date(_ ms: LedgerMs) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }
    static func short(_ ms: LedgerMs) -> String { Fmt.short(date(ms)) }
    static func long(_ ms: LedgerMs) -> String { Fmt.long(date(ms)) }
}

/// The verdict as a chip: symbol, label and colour together, so colour is never the only sign
struct LedgerVerdictBadge: View {
    let verdict: LedgerVerdict
    var count: Int?

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: verdict.symbol)
            Text(verdict.title).lineLimit(1)
            if let count { Text("\(count)").monospacedDigit() }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(verdict.color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(verdict.outlined ? Color.clear : verdict.color.opacity(0.15)))
        .overlay(Capsule().strokeBorder(verdict.outlined ? verdict.color : Color.clear, lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(verdict.title + (count.map { ", \($0)" } ?? ""))
    }
}

/// A session's ID next to its lane colour, as the graph draws it
struct LedgerSessionLabel: View {
    let id: String
    let color: Int

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Palette.lane(color)).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(id).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
        }
        .fixedSize()
    }
}

/// A group title in the Inbox and the inspector: small capitals, count on the right
/// How long auto-continue waits for a person: the core keeps waits between 10 s and 5 minutes
struct LedgerWaitPicker: View {
    let seconds: Int
    let choose: (Int) -> Void

    var body: some View {
        Picker("Wait", selection: Binding(get: { LedgerWait.clamped(seconds) }, set: choose)) {
            ForEach(LedgerWait.choices(including: seconds), id: \.self) { Text("\($0) s").tag($0) }
        }
        .fixedSize()
    }
}

struct LedgerSectionHeader: View {
    let title: String
    var count: Int?

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.8).lineLimit(1)
            Rectangle().frame(height: 1).opacity(0.25)
            if let count { Text("\(count)").font(.system(size: 10, weight: .semibold, design: .monospaced)) }
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The note after an operation; Undo (⌘Z) while it can be undone
struct LedgerToastView: View {
    let toast: LedgerToast
    let undo: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(nsColor: .systemGreen)).accessibilityHidden(true)
            Text(toast.message).font(.callout).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if toast.canUndo {
                Button("Undo", action: undo)
                    .keyboardShortcut("z", modifiers: .command)
                    .help("Undo (⌘Z)")
            }
            Button(action: close) { Image(systemName: "xmark") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .help("Close").accessibilityLabel("Close")
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)).shadow(color: .black.opacity(0.18), radius: 8, y: 2))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
        .frame(maxWidth: 520)
        .accessibilityElement(children: .contain)
    }
}

/// A link chip in the inspector header: branch, worktree, pull request, agent, chat
struct LedgerLinkChip: View {
    let symbol: String
    let text: String
    var url: URL?

    var body: some View {
        let chip = HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            Text(text).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.1)))
        if let url {
            Link(destination: url) { chip }.buttonStyle(.plain).foregroundStyle(Color.accentColor).help(url.absoluteString)
        } else {
            chip.foregroundStyle(.secondary).help(text)
        }
    }
}
