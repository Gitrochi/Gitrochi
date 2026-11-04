import SwiftUI

/// The window's pages. Once the repository screen opens, this folds into the icon rail and the branch list takes its place.
struct NavigationSidebar: View {
    @Environment(RepoStore.self) private var store
    @ViewState private var hovered: WorkspaceDestination?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                NavigationBrand()
                Spacer()
                Button { store.sidebarToggleRequest += 1 } label: {
                    Image(systemName: "sidebar.left").font(.system(size: 15)).frame(width: 28, height: 24)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Collapse sidebar").accessibilityLabel("Collapse sidebar")
                .accessibilityIdentifier("navigation-sidebar-collapse")
            }
            .padding(.leading, 14).padding(.trailing, 8).frame(height: 56)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    section([.home, .repository])
                    groupTitle(String(localized: "Workspace"))
                    section([.compare, .rebase, .code])
                    groupTitle(store.target?.provider == .gitlab ? "GitLab" : "GitHub")
                    section([.pullRequests, .issues, .actions, .releases, .projects, .account])
                    groupTitle(String(localized: "Tools"))
                    section([.flows, .ledger].filter(\.isShown))
                }.padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 12)
            }
            Divider()
            SettingsLink { Label("Settings", systemImage: "gearshape").font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10).padding(.horizontal, 12) }
                .buttonStyle(.plain).padding(8).keyboardShortcut(",", modifiers: .command).accessibilityLabel("Settings")
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func groupTitle(_ text: String) -> some View {
        HStack { Text(text.uppercased()).font(.system(size: 11, weight: .medium)).tracking(0.7).lineLimit(1); Spacer() }
            .foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
    }

    private func section(_ pages: [WorkspaceDestination]) -> some View {
        VStack(spacing: 3) { rows(pages) }
            .padding(4)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.05), lineWidth: 1))
    }

    private func title(_ page: WorkspaceDestination) -> String { page.title(gitlab: store.target?.provider == .gitlab) }

    private func rows(_ pages: [WorkspaceDestination]) -> some View {
        ForEach(pages) { page in
            let active = store.destination == page
            Button { store.navigate(page) } label: {
                HStack(spacing: 10) {
                    Image(systemName: page.symbol).font(.system(size: 16, weight: active ? .semibold : .regular)).frame(width: 21, height: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title(page)).font(.system(size: 13, weight: active ? .semibold : .medium)).lineLimit(1)
                        if page == .repository {
                            Text(store.url == nil ? String(localized: "Open a repository to get started") : store.name)
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 2)
                    if page == .repository, store.status.count > 0 { badge(store.status.count) }
                    if page == .pullRequests, !store.pullRequests.isEmpty { badge(store.pullRequests.count) }
                    if page == .ledger, LedgerStore.shared.attentionTotal > 0 { badge(LedgerStore.shared.attentionTotal) }
                }.padding(.horizontal, 12).frame(minHeight: page == .repository ? 46 : 32)
                    .foregroundStyle(active ? Color.primary : Color.primary.opacity(0.8))
                    .background(active ? Color.accentColor.opacity(0.16) : hovered == page ? Color.primary.opacity(0.035) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
                .onHover { hovered = $0 ? page : nil }
                .help(title(page))
                .accessibilityLabel(title(page))
                .accessibilityValue(active ? String(localized: "Current page") : "")
        }
    }

    private func badge(_ count: Int) -> some View {
        Text(count > 999 ? "999+" : String(count)).font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 6).frame(height: 18).background(Color(nsColor: .windowBackgroundColor), in: Capsule())
    }
}
