import SwiftUI

/// The window's pages as the native source list (docs/design.md › App shell, Sidebar). The OS draws the rows, their
/// selection, the section headers and Ledger's count. While no repository is open, a page that needs one is disabled
/// and its section says why. Once the repository screen opens, this folds into the icon rail.
struct NavigationSidebar: View {
    @Environment(RepoStore.self) private var store
    @ViewState private var hovered: WorkspaceDestination?
    /// Holding ⌘ shows every row's shortcut; otherwise a row shows its own on hover
    @ViewState private var commandHeld = false

    private var gitlab: Bool { store.target?.provider == .gitlab }

    var body: some View {
        List(selection: Binding(get: { store.destination }, set: { page in
            if let page, page != store.destination { store.navigate(page) }
        })) {
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
                        Label { Text("Settings") } icon: { Image(systemName: "gearshape").foregroundStyle(.secondary) }
                        Spacer(minLength: 8)
                        if commandHeld || hovered == nil && settingsHovered { Text(verbatim: "⌘,").foregroundStyle(.secondary) }
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
                Text(title)
                // the reason sits under the section, not in a tip: macOS shows no tip on a disabled row
                if store.url == nil, pages.contains(where: \.needsRepository) {
                    Text("Open a repository to use these").font(.system(size: 12, weight: .regular)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func row(_ page: WorkspaceDestination) -> some View {
        let title = page.title(gitlab: gitlab)
        // only Ledger counts something
        let count = page == .ledger ? LedgerStore.shared.attentionTotal : 0
        let blocked = store.url == nil && page.needsRepository
        return HStack(spacing: 8) {
            // secondary icons keep the accent for the selection (docs/design.md › App shell, Sidebar); a sidebar list
            // does not dim a disabled row by itself, so a blocked one draws its own dimmed colours
            Label {
                Text(title).foregroundStyle(blocked ? .tertiary : .primary)
            } icon: {
                Image(systemName: page.symbol).foregroundStyle(blocked ? .quaternary : .secondary)
            }
            Spacer(minLength: 8)
            if let shortcut = page.shortcutLabel, commandHeld || hovered == page {
                Text(verbatim: shortcut).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .badge(count)
        .tag(page)
        .disabled(blocked)
        .selectionDisabled(blocked)
        .onHover { hovered = $0 ? page : (hovered == page ? nil : hovered) }
    }
}
