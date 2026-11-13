import AppKit
import SwiftUI

/// The terminal carries the same eye artwork as the application, with a compact form for split panes.
struct TerminalBrand: View {
    var compact = false
    var image: NSImage?
    private static let appIcon: NSImage = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage

    var body: some View {
        HStack(spacing: 7) {
            Image(nsImage: image ?? Self.appIcon)
                .resizable().interpolation(.high)
                .frame(width: 26, height: 26)
            if !compact {
                Text(verbatim: "gitrochi")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .tracking(-0.2).foregroundStyle(.primary)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Gitrochi")
    }
}

/// Compact terminal controls share a quiet selected treatment and a consistent hit area.
struct TerminalToolbarButton: View {
    let symbol: String
    let label: LocalizedStringKey
    var selected = false
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            SymbolIcon(symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(selected ? 0.09 : hovering ? 0.055 : 0),
                            in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(Text(label))
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// One tab of a terminal pane, as the tab bar draws it
struct TerminalTabItem: Identifiable, Equatable {
    let id: UUID
    let title: String
    let directory: String
    /// Its number across the panel; nil with a single terminal
    let number: Int?
    let mark: TerminalTabMark
    /// The mark in words, for tooltips, the » menu and VoiceOver
    let state: String
}

/// The 12pt slot every tab reserves, so titles never shift when a mark appears. Status is told by shape:
/// a ring while a command runs, a dot for unseen output or a waiting session, a hollow circle when exited.
struct TerminalTabMarkView: View {
    let mark: TerminalTabMark

    var body: some View {
        ZStack {
            switch mark {
            case .ring:
                Circle().trim(from: 0, to: 0.75)
                    .stroke(Color(nsColor: .systemOrange), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .frame(width: 7.5, height: 7.5)
            case .dot:
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
            case .hollow:
                Circle().strokeBorder(Color.secondary, lineWidth: 1.5).frame(width: 7, height: 7)
            case .none:
                EmptyView()
            }
        }
        .frame(width: 12, height: 12)
        .accessibilityHidden(true)
    }
}

/// A pane's tab bar: tabs with their status marks, » for the tabs that do not fit, then the pane's buttons. No logo.
/// What fits is decided from the pane's width (TerminalPanelLayout). (Windows: TerminalTabBar.tsx)
struct TerminalTabBar<Actions: View>: View {
    let tabs: [TerminalTabItem]
    let selected: UUID?
    /// The pane has the keyboard: its selected tab gets the accent underline
    var focused = true
    let width: CGFloat
    /// The top-right pane carries Hide
    var corner = true
    var voiceOn = false
    var voiceEnabled = true
    let select: (UUID) -> Void
    let close: (UUID) -> Void
    let newTerminal: () -> Void
    let voice: () -> Void
    let hide: () -> Void
    /// The actions menu's own items; the bar adds the buttons it folds away
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        let compact = TerminalPanelLayout.compactBar(width: width)
        let fit = TerminalPanelLayout.tabOverflow(count: tabs.count, selected: tabs.firstIndex { $0.id == selected },
                                                  width: TerminalPanelLayout.tabStripWidth(bar: width, controls: compact ? 1 : corner ? 4 : 3))
        HStack(spacing: 2) {
            HStack(spacing: 0) {
                ForEach(fit.visible.map { tabs[$0] }) { tab in
                    TerminalSessionTab(tab: tab, selected: tab.id == selected, focused: focused,
                                       select: { select(tab.id) }, close: { close(tab.id) })
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Terminals")
            .accessibilityIdentifier("terminal-tabs")
            if !fit.hidden.isEmpty {
                Menu {
                    ForEach(fit.hidden.map { tabs[$0] }) { tab in
                        Button { select(tab.id) } label: {
                            Text(verbatim: (tab.number.map { "\($0)  " } ?? "") + tab.title)
                            Text(verbatim: tab.state)
                        }
                    }
                } label: {
                    Text(verbatim: "» \(fit.hidden.count)")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        .frame(minWidth: 26, minHeight: 26)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(Text("\(fit.hidden.count) more terminals"))
                .accessibilityLabel(Text("\(fit.hidden.count) more terminals"))
                .accessibilityIdentifier("terminal-overflow")
            }
            if !compact {
                TerminalToolbarButton(symbol: "plus", label: "New terminal", action: newTerminal)
                    .accessibilityIdentifier("terminal-new")
            }
            Spacer(minLength: 0)
            if !compact {
                TerminalToolbarButton(symbol: "mic", label: "Voice input", selected: voiceOn, action: voice)
                    .disabled(!voiceEnabled)
                    .accessibilityIdentifier("terminal-voice")
            }
            Menu {
                if compact {
                    Button("New terminal", symbol: "plus", action: newTerminal)
                    Button("Voice input", symbol: "mic", action: voice).disabled(!voiceEnabled)
                }
                actions()
                if compact && corner {
                    Button("Hide terminal", symbol: "chevron.down", action: hide)
                }
            } label: {
                DesignIconImage(icon: .more)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(minWidth: 26, minHeight: 26)
            .help("Terminal actions")
            .accessibilityLabel("Terminal actions")
            .accessibilityIdentifier("terminal-actions")
            if !compact && corner {
                TerminalToolbarButton(symbol: "chevron.down", label: "Hide terminal", action: hide)
                    .accessibilityIdentifier("terminal-hide")
            }
        }
        .padding(.leading, 10).padding(.trailing, 6)
        .frame(height: 36)
    }
}

/// The tab stays keyboard accessible while its close action remains a separate button.
struct TerminalSessionTab: View {
    let tab: TerminalTabItem
    let selected: Bool
    /// The pane has the keyboard; a pane without it keeps a neutral underline
    var focused = true
    let select: () -> Void
    let close: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: select) {
                HStack(spacing: 6) {
                    TerminalTabMarkView(mark: tab.mark)
                    if let number = tab.number {
                        Text(verbatim: "\(number)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Text(verbatim: tab.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.75))
                        .lineLimit(1).truncationMode(.tail)
                }
                .padding(.leading, 8).padding(.trailing, 2)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: tab.title))
            .accessibilityValue(Text(verbatim: tab.state))
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            Button(action: close) {
                DesignIconImage(icon: .close)
                    .font(.system(size: 8, weight: .semibold))
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .opacity(hovering || selected ? 1 : 0)
            .help("Close terminal").accessibilityLabel("Close terminal")
        }
        .background(Color.primary.opacity(hovering ? 0.035 : 0), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 2)
        .frame(maxWidth: TerminalPanelLayout.tabMaxWidth, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if selected {
                Capsule().fill(focused ? Color.accentColor : Color(nsColor: .tertiaryLabelColor))
                    .frame(height: 2).padding(.horizontal, 8).allowsHitTesting(false)
            }
        }
        .onHover { hovering = $0 }
        .help(Text(verbatim: tab.directory + " · " + tab.state))
    }
}

/// These actions prepare text for review; the terminal runs it only on Return.
enum TerminalQuickCommand: String, CaseIterable, Identifiable {
    case status, preflight, pullRequest, ci
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .status: return "Status"
        case .preflight: return "Preflight"
        case .pullRequest: return "Pull request"
        case .ci: return "CI"
        }
    }
    var command: String {
        switch self {
        case .status: return "gitch ck"
        case .preflight: return "gitch preflight"
        case .pullRequest: return "gitch pr status"
        case .ci: return "gitch ci"
        }
    }
}

/// A small workflow rail folds into one "Commands" menu before it can crowd a narrow pane. (Windows: TerminalQuickActions)
struct TerminalQuickActions: View {
    var enabled = true
    /// The pane's width, which decides whether the commands fold (TerminalPanelLayout)
    var width: CGFloat = .infinity
    let select: (TerminalQuickCommand) -> Void

    var body: some View {
        HStack(spacing: 6) {
            if TerminalPanelLayout.commandsFolded(width: width) {
                commandMenu
            } else {
                ForEach(TerminalQuickCommand.allCases) { command in
                    Button { select(command) } label: {
                        HStack(spacing: 6) {
                            prompt
                            Text(command.title)
                        }
                        .modifier(TerminalCommandChip())
                    }
                    .buttonStyle(.plain).help(command.command)
                }
            }
            Spacer(minLength: 0)
            if TerminalPanelLayout.commandHintShown(width: width) { insertionHint }
        }
        .font(.system(size: 12, weight: .medium))
        .disabled(!enabled).padding(.horizontal, 12).frame(height: 36)
        .background(Color.primary.opacity(0.02))
        .overlay(alignment: .top) { Divider().opacity(0.5) }
    }

    private var prompt: some View {
        Text(verbatim: "❯").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
    }

    private var commandMenu: some View {
        Menu {
            ForEach(TerminalQuickCommand.allCases) { command in
                Button { select(command) } label: {
                    Text(command.title)
                    Text(verbatim: command.command)
                }
            }
        } label: {
            HStack(spacing: 6) {
                prompt
                Text("Commands")
                DesignIconImage(icon: .chevronDown, size: 8).foregroundStyle(.secondary)
            }
            .modifier(TerminalCommandChip())
        }
        // a plain button menu keeps the label neutral; the borderless style would tint it with the accent
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help(String(localized: "Insert command") + " · " + String(localized: "Insert, then Return"))
        .accessibilityIdentifier("terminal-commands")
    }

    private var insertionHint: some View {
        Text("Insert, then Return")
            .font(.system(size: 11))
            .foregroundStyle(.secondary).lineLimit(1).fixedSize()
    }
}

/// A command in the rail: a neutral bordered chip, 24pt high
private struct TerminalCommandChip: ViewModifier {
    @Environment(\.isEnabled) private var enabled

    func body(content: Content) -> some View {
        content
            .foregroundStyle(enabled ? Color.primary : Color(nsColor: .tertiaryLabelColor))
            .padding(.horizontal, 9).frame(height: 24)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)) }
            .contentShape(Rectangle())
    }
}

/// Current location and output activity stay readable without competing with the terminal content.
struct TerminalStatusBar: View {
    @ViewState private var copyFeedbackToken: UUID?
    let directory: String
    let activity: TerminalActivity
    let program: String
    var branch: String?
    var unseenCount = 0
    /// The pane's width: a narrow line drops the branch first, then the shell (TerminalPanelLayout)
    var width: CGFloat = .infinity
    var copyDirectory: (() -> Void)?
    var nextUnseen: (() -> Void)?

    var body: some View {
        let parts = TerminalPanelLayout.statusLine(width: width)
        row(showBranch: parts.branch, showProgram: parts.shell)
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .padding(.leading, 12).padding(.trailing, 8).frame(height: 28)
        .background(Color.primary.opacity(0.02))
        .overlay(alignment: .top) { Divider().opacity(0.5) }
        .task(id: copyFeedbackToken) {
            guard let token = copyFeedbackToken else { return }
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled, copyFeedbackToken == token else { return }
            copyFeedbackToken = nil
        }
        .onChange(of: directory) { _, _ in copyFeedbackToken = nil }
    }

    private func row(showBranch: Bool, showProgram: Bool) -> some View {
        HStack(spacing: 12) {
            Group {
                if let copyDirectory {
                    Button {
                        copyDirectory()
                        copyFeedbackToken = UUID()
                    } label: { folder }
                        .buttonStyle(.plain)
                        .help(copyFeedbackToken != nil ? String(localized: "Folder path copied") : String(localized: "Copy current folder"))
                        .accessibilityLabel(copyFeedbackToken != nil ? Text("Folder path copied") : Text("Copy current folder"))
                        .accessibilityValue(Text(verbatim: directory))
                } else {
                    folder.help(directory)
                }
            }
            .frame(minWidth: 48, maxWidth: .infinity, alignment: .leading)
            if showBranch, let branch, !branch.isEmpty {
                Label { Text(verbatim: branch).lineLimit(1).truncationMode(.middle) } icon: {
                    DesignIconImage(icon: .branch)
                }
                .frame(maxWidth: 140).help(branch)
                .accessibilityLabel("Repository branch")
                .accessibilityValue(Text(verbatim: branch))
            }
            if unseenCount > 0 {
                Button { nextUnseen?() } label: {
                    HStack(spacing: 4) {
                        Circle().fill(Color.accentColor).frame(width: 6, height: 6).accessibilityHidden(true)
                        Text("\(unseenCount) new")
                    }
                }
                .buttonStyle(.plain).disabled(nextUnseen == nil).fixedSize()
                .help(String(localized: "Next terminal with new output") + "\n" + String(localized: "\(unseenCount) tabs with new output"))
                .accessibilityLabel("Next terminal with new output")
                .accessibilityValue(Text("\(unseenCount) tabs with new output"))
            }
            HStack(spacing: 12) {
                if showProgram {
                    Text(verbatim: program).lineLimit(1).truncationMode(.middle).frame(maxWidth: 120)
                }
                // the state is words here; its shape is the tab's mark
                Text(activity == .running ? LocalizedStringKey("Running") : activity == .idle ? LocalizedStringKey("Idle") : LocalizedStringKey("Exited")).fixedSize()
            }
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityElement(children: .combine)
        }
    }

    private var folder: some View {
        HStack(spacing: 5) {
            DesignIconImage(icon: .repository).accessibilityHidden(true)
            Text(verbatim: abbreviatedDirectory).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.head)
            if copyDirectory != nil {
                SymbolIcon(copyFeedbackToken != nil ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9))
                    .foregroundStyle(copyFeedbackToken != nil ? Color(nsColor: .systemGreen) : Color(nsColor: .tertiaryLabelColor))
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }

    private var abbreviatedDirectory: String {
        let home = NSHomeDirectory()
        return directory == home || directory.hasPrefix(home + "/") ? "~" + directory.dropFirst(home.count) : directory
    }
}
