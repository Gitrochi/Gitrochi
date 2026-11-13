import SwiftUI

/// The page list folded to icons while the repository screen is open (docs/design.md › App shell): 52pt on the
/// sidebar's grey, the pages in the sidebar's sections and Settings at the bottom. The toolbar's sidebar toggle expands
/// it, so the rail has no button of its own for that.
struct NavigationSidebarRail: View {
    @Environment(RepoStore.self) private var store
    @ViewState private var hovered: WorkspaceDestination?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 4) {
                    rows([.home])
                    separator
                    rows([.repository, .compare, .rebase, .code])
                    separator
                    rows([.pullRequests, .issues, .actions, .releases, .projects, .account])
                    separator
                    rows([.flows].filter(\.isShown))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            SettingsLink {
                DesignIconImage(icon: .settings, size: 18)
                    .frame(width: 36, height: 32)
                    .foregroundStyle(StudioStyle.Rail.settings)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .padding(.bottom, 8)
            .help(String(localized: "Settings") + " (⌘,)").accessibilityLabel("Settings")
            .keyboardShortcut(",", modifiers: .command)
        }
        .frame(width: 52)
        .background(StudioStyle.Rail.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Collapsed navigation")
        .accessibilityIdentifier("navigation-sidebar-rail")
    }

    private var separator: some View {
        Rectangle().fill(StudioStyle.Rail.separator).frame(width: 24, height: 1).padding(.vertical, 4)
    }

    private func rows(_ pages: [WorkspaceDestination]) -> some View {
        ForEach(pages) { page in
            let active = store.destination == page
            let blocked = store.url == nil && page.needsRepository
            let title = page.title(gitlab: store.target?.provider == .gitlab)
            Button { store.navigate(page) } label: {
                NavigationPageIcon(page: page, size: 18)
                    .frame(width: 36, height: 32)
                    .foregroundStyle(blocked ? StudioStyle.Rail.blocked : StudioStyle.Rail.icon)
                    .background(active ? StudioStyle.Rail.selected : hovered == page ? StudioStyle.Rail.hover : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 ? page : (hovered == page ? nil : hovered) }
            .help(blocked ? String(localized: "Open a repository to use this page.") : title)
            .accessibilityLabel(title)
            .accessibilityValue(active ? String(localized: "Current page") : "")
            .accessibilityIdentifier("navigation-rail-" + page.rawValue)
        }
    }
}
