import SwiftUI

/// The window's pages. Once the repository screen opens, this folds into the icon rail and the branch list takes its place.
struct NavigationSidebar: View {
    @Environment(RepoStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Workspace").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).tracking(0.6)
                Spacer()
                Button { store.sidebarToggleRequest += 1 } label: {
                    Image(systemName: "sidebar.left").font(.system(size: 15)).frame(width: 28, height: 24)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Collapse sidebar").accessibilityLabel("Collapse sidebar")
                .accessibilityIdentifier("navigation-sidebar-collapse")
            }
            .padding(.leading, 16).padding(.trailing, 8).padding(.top, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    rows([.home, .repository])
                    groupTitle(String(localized: "Workspace"))
                    rows([.compare, .rebase, .code])
                    groupTitle(store.target?.provider == .gitlab ? "GitLab" : "GitHub")
                    rows([.pullRequests, .issues, .actions, .releases, .projects, .account])
                    groupTitle(String(localized: "Tools"))
                    rows([.flows])
                }.padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 12)
            }
            Divider()
            SettingsLink { Label("Settings", systemImage: "gearshape").font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10).padding(.horizontal, 12) }
                .buttonStyle(.plain).padding(8).keyboardShortcut(",", modifiers: .command).accessibilityLabel("Settings")
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func groupTitle(_ text: String) -> some View {
        HStack { Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.8).lineLimit(1); Rectangle().frame(height: 1).opacity(0.3) }
            .foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 18).padding(.bottom, 6)
    }

    private func title(_ page: WorkspaceDestination) -> String { page.title(gitlab: store.target?.provider == .gitlab) }

    private func rows(_ pages: [WorkspaceDestination]) -> some View {
        ForEach(pages) { page in
            let active = store.destination == page
            let disabled = page.needsRepository && store.url == nil
            Button { store.navigate(page) } label: {
                HStack(spacing: 10) {
                    Image(systemName: page.symbol).font(.system(size: 16, weight: active ? .semibold : .regular)).frame(width: 21, height: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title(page)).font(.system(size: 13, weight: active ? .semibold : .medium)).lineLimit(1)
                        if page == .repository {
                            Text(store.url == nil ? String(localized: "Open a repository to get started") : store.name)
                                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 2)
                    if page == .repository, store.status.count > 0 { badge(store.status.count) }
                    if page == .pullRequests, !store.pullRequests.isEmpty { badge(store.pullRequests.count) }
                }.padding(.horizontal, 12).frame(minHeight: page == .repository ? 54 : 38)
                    .foregroundStyle(active ? Color.accentColor : disabled ? Color.secondary.opacity(0.5) : Color.primary.opacity(0.8))
                    .background(active ? Color.accentColor.opacity(0.11) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(disabled)
                .help(disabled ? String(localized: "Open a repository to use this page.") : title(page))
                .accessibilityLabel(title(page))
                .accessibilityValue(active ? String(localized: "Current page") : "")
        }
    }

    private func badge(_ count: Int) -> some View {
        Text(count > 999 ? "999+" : String(count)).font(.system(size: 10, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 5).padding(.vertical, 2).background(.quaternary.opacity(0.7), in: Capsule())
    }
}
