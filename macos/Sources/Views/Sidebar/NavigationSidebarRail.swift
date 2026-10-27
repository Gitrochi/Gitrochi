import SwiftUI

/// The page list folded to icons: always at the left edge while the repository screen is open
struct NavigationSidebarRail: View {
    @Environment(RepoStore.self) private var store
    let onExpand: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onExpand) {
                Image(systemName: "sidebar.left").font(.system(size: 17)).frame(width: 40, height: 36)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help("Expand sidebar").accessibilityLabel("Expand sidebar")
            .accessibilityIdentifier("navigation-rail-expand")
            .padding(.top, 6)
            Divider().padding(.horizontal, 10).padding(.vertical, 6)
            ScrollView(showsIndicators: false) {
                VStack(spacing: 4) {
                    rows([.home, .repository])
                    separator
                    rows([.compare, .rebase, .code])
                    separator
                    rows([.pullRequests, .issues, .actions, .releases, .projects, .account])
                    separator
                    rows([.flows])
                }.padding(.horizontal, 8).padding(.bottom, 8)
            }
            Divider()
            SettingsLink {
                Image(systemName: "gearshape").font(.system(size: 18)).frame(width: 40, height: 40)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).padding(.vertical, 5)
            .help("Settings").accessibilityLabel("Settings").keyboardShortcut(",", modifiers: .command)
        }
        .frame(width: 56)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Collapsed navigation")
        .accessibilityIdentifier("navigation-sidebar-rail")
    }

    private var separator: some View { Divider().padding(.horizontal, 4).padding(.vertical, 5) }

    private func rows(_ pages: [WorkspaceDestination]) -> some View {
        ForEach(pages) { page in
            let active = store.destination == page
            let disabled = page.needsRepository && store.url == nil
            let count = page == .repository ? store.status.count : page == .pullRequests ? store.pullRequests.count : 0
            let title = page.title(gitlab: store.target?.provider == .gitlab)
            Button { store.navigate(page) } label: {
                Image(systemName: page.symbol).font(.system(size: 18, weight: active ? .semibold : .regular))
                    .frame(width: 40, height: 36)
                    .foregroundStyle(active ? Color.accentColor : disabled ? Color.secondary.opacity(0.45) : Color.primary.opacity(0.72))
                    .background(active ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .topTrailing) {
                        if count > 0 {
                            Text(count > 99 ? "99+" : String(count)).font(.system(size: 8, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 3).padding(.vertical, 1)
                                .background(Color(nsColor: .windowBackgroundColor), in: Capsule()).offset(x: 2, y: -1)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(disabled)
            .help(disabled ? String(localized: "Open a repository to use this page.") : title + (count > 0 ? " (\(count))" : ""))
            .accessibilityLabel(title).accessibilityValue(active ? String(localized: "Current page") : "")
            .accessibilityIdentifier("navigation-rail-" + page.rawValue)
        }
    }
}
