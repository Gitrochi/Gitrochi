import SwiftUI

/// The window's pages as the native source list (docs/design.md › App shell, Sidebar). The OS lays out the rows, the
/// sections and Ledger's count; the app draws the current page's fill, so it stays neutral with or without keyboard
/// focus, as in the rail. While no repository is open, a page that needs one is disabled and its section says why.
/// Once the repository screen opens, this folds into the icon rail.
struct NavigationSidebar: View {
    @Environment(RepoStore.self) private var store
    @ViewState private var hovered: WorkspaceDestination?
    /// Holding ⌘ shows every row's shortcut; otherwise a row shows its own on hover
    @ViewState private var commandHeld = false

    private var gitlab: Bool { store.target?.provider == .gitlab }

    var body: some View {
        // No selection binding: the OS would fill the current page with the accent while the list has focus, next to
        // the page's own filled button.
        List {
            row(.home)
            section(String(localized: "Repository"), [.repository, .compare, .rebase, .code])
            section(gitlab ? "GitLab" : "GitHub", [.pullRequests, .issues, .actions, .releases, .projects, .account])
            section(String(localized: "Tools"), [.flows, .ledger].filter(\.isShown))
        }
        .listStyle(.sidebar)
        .onModifierKeysChanged(mask: .command) { _, keys in commandHeld = keys.contains(.command) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                SettingsLink {
                    HStack(spacing: 8) {
                        Label { Text("Settings") } icon: { DesignIconImage(icon: .settings, size: 16).foregroundStyle(.secondary) }
                        Spacer(minLength: 8)
                        if commandHeld || hovered == nil && settingsHovered { Text(verbatim: "⌘,").foregroundStyle(.primary.opacity(0.6)) }
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 10).frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .onHover { settingsHovered = $0 }
                .keyboardShortcut(",", modifiers: .command)
                .accessibilityLabel("Settings")
            }
        }
    }

    @ViewState private var settingsHovered = false

    private func section(_ title: String, _ pages: [WorkspaceDestination]) -> some View {
        Section {
            ForEach(pages) { row($0) }
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11, weight: .semibold))
                // the reason sits under the section, not in a tip: macOS shows no tip on a disabled row
                if store.url == nil, pages.contains(where: \.needsRepository) {
                    Text("Open a repository to use these").font(.system(size: 12, weight: .regular))
                }
            }
            // the OS draws sidebar section titles at about 2.2:1 on the sidebar grey; the design's grey reaches 4.8:1
            .foregroundStyle(StudioStyle.Rail.icon)
        }
    }

    private func row(_ page: WorkspaceDestination) -> some View {
        let title = page.title(gitlab: gitlab)
        // only Ledger counts something
        let count = page == .ledger ? LedgerStore.shared.attentionTotal : 0
        let blocked = store.url == nil && page.needsRepository
        let active = store.destination == page
        return Button { store.navigate(page) } label: {
            HStack(spacing: 8) {
                // a sidebar list does not dim a disabled row by itself, so a blocked one draws its own dimmed colours
                Label {
                    Text(title).foregroundStyle(blocked ? .tertiary : .primary)
                } icon: {
                    NavigationPageIcon(page: page, size: 16).foregroundStyle(blocked ? .quaternary : .secondary)
                }
                Spacer(minLength: 8)
                if let shortcut = page.shortcutLabel, commandHeld || hovered == page {
                    // 60% of the label colour reads at about 5:1 on the sidebar and on the current page's fill
                    Text(verbatim: shortcut).font(.system(size: 12)).foregroundStyle(.primary.opacity(0.6))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .badge(count)
        .disabled(blocked)
        // the rail's fill for the current page: neutral, never the accent
        .listRowBackground(
            RoundedRectangle(cornerRadius: 6).fill(active ? StudioStyle.Rail.selected : Color.clear).padding(.horizontal, 10)
        )
        .onHover { hovered = $0 ? page : (hovered == page ? nil : hovered) }
        .accessibilityLabel(title)
        .accessibilityValue(active ? String(localized: "Current page") : "")
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

extension WorkspaceDestination {
    var designIcon: DesignIcon {
        switch self {
        case .account: return .account
        case .home: return .home
        case .repository: return .repository
        case .compare: return .compare
        case .rebase: return .rebase
        case .code: return .code
        case .pullRequests: return .pullRequests
        case .issues: return .issues
        case .actions: return .actions
        case .releases: return .releases
        case .projects: return .projects
        case .flows: return .flows
        case .ledger: return .ledger
        }
    }
}

/// A page's icon in the rail and the sidebar
struct NavigationPageIcon: View {
    let page: WorkspaceDestination
    var size: CGFloat = 16

    var body: some View {
        DesignIconImage(icon: page.designIcon, size: size)
    }
}
