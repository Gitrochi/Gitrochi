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
            Image(systemName: symbol)
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

/// The tab stays keyboard accessible while its close action remains a separate button.
struct TerminalSessionTab: View {
    let title: String
    let directory: String
    let number: Int?
    let running: Bool
    let unseenOutput: Bool
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: select) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(!running ? Color.secondary : unseenOutput ? Color(nsColor: .systemBlue) : Color(nsColor: .systemGreen))
                        .frame(width: 5, height: 5).accessibilityHidden(true)
                    if let number {
                        Text("\(number)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                    Text(verbatim: title)
                        .font(.system(size: 11, weight: selected ? .semibold : .regular, design: .monospaced))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 150, alignment: .leading)
                }
                .padding(.leading, 9).padding(.trailing, 5)
                .frame(height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: title))
            .accessibilityValue(accessibleStatus)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            Button(action: close) {
                DesignIconImage(icon: .close)
                    .font(.system(size: 8, weight: .semibold))
                    .frame(width: 20, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .opacity(hovering || selected ? 1 : 0)
            .help("Close terminal").accessibilityLabel("Close terminal")
        }
        .background(Color.primary.opacity(selected ? 0.07 : hovering ? 0.035 : 0),
                    in: RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(selected ? Color.primary.opacity(0.12) : .clear)
                .allowsHitTesting(false)
        }
        .onHover { hovering = $0 }.help(directory)
    }

    private var accessibleStatus: Text {
        let state = running ? String(localized: "Running") : String(localized: "Exited")
        return Text(verbatim: unseenOutput ? state + ", " + String(localized: "New output") : state)
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

/// A small workflow rail folds into one menu before it can crowd a split terminal.
struct TerminalQuickActions: View {
    var enabled = true
    let select: (TerminalQuickCommand) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    ForEach(TerminalQuickCommand.allCases) { command in
                        Button { select(command) } label: {
                            HStack(spacing: 4) {
                                Text(verbatim: "❯").foregroundStyle(.tertiary)
                                Text(command.title)
                            }
                            .padding(.horizontal, 7).frame(height: 23)
                            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 4))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).help(command.command)
                    }
                }
                Spacer(minLength: 0)
                insertionHint
            }
            HStack(spacing: 8) {
                commandMenu
                Spacer(minLength: 0)
                insertionHint
            }
            HStack(spacing: 0) {
                commandMenu
                Spacer(minLength: 0)
            }
        }
        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
        .disabled(!enabled).padding(.horizontal, 10).frame(height: 32)
        .background(Color.primary.opacity(0.015))
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }

    private var commandMenu: some View {
        Menu {
            ForEach(TerminalQuickCommand.allCases) { command in
                Button { select(command) } label: { Text(command.title) }
            }
        } label: {
            Text(verbatim: "❯ " + String(localized: "Commands"))
        }
        .menuStyle(.borderlessButton).fixedSize().frame(minWidth: 84, alignment: .leading)
        .help(String(localized: "Insert command") + " · " + String(localized: "Insert, then Return"))
    }

    private var insertionHint: some View {
        Text("Insert, then Return")
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.tertiary).fixedSize()
    }
}

/// Current location and output activity stay readable without competing with the terminal content.
struct TerminalStatusBar: View {
    @ViewState private var copyFeedbackToken: UUID?
    let directory: String
    let running: Bool
    let program: String
    var branch: String?
    var unseenCount = 0
    var copyDirectory: (() -> Void)?
    var nextUnseen: (() -> Void)?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(showBranch: true, showProgram: true)
            row(showBranch: false, showProgram: true)
            row(showBranch: false, showProgram: false)
        }
        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
        .padding(.horizontal, 10).frame(height: 28)
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
        HStack(spacing: 9) {
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
                        Circle().fill(Color(nsColor: .systemBlue)).frame(width: 4, height: 4).accessibilityHidden(true)
                        Text("\(unseenCount) new")
                    }
                }
                .buttonStyle(.plain).disabled(nextUnseen == nil).fixedSize()
                .help(String(localized: "Next terminal with new output") + "\n" + String(localized: "\(unseenCount) tabs with new output"))
                .accessibilityLabel("Next terminal with new output")
                .accessibilityValue(Text("\(unseenCount) tabs with new output"))
            }
            HStack(spacing: 6) {
                if showProgram {
                    Text(verbatim: program).lineLimit(1).truncationMode(.middle).frame(maxWidth: 80)
                }
                Circle().fill(running ? Color(nsColor: .systemGreen) : Color.secondary)
                    .frame(width: 5, height: 5).accessibilityHidden(true)
                Text(running ? LocalizedStringKey("Running") : LocalizedStringKey("Exited")).fixedSize()
            }
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityElement(children: .combine)
        }
    }

    private var folder: some View {
        HStack(spacing: 5) {
            DesignIconImage(icon: .repository).accessibilityHidden(true)
            Text(verbatim: abbreviatedDirectory).lineLimit(1).truncationMode(.head)
            if copyDirectory != nil {
                Image(systemName: copyFeedbackToken != nil ? "checkmark" : "doc.on.doc")
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
