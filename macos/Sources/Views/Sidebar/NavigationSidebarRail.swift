import SwiftUI

/// 사이드바를 숨겨도 현재 위치와 주요 메뉴를 항상 왼쪽에 남긴다.
struct NavigationSidebarRail: View {
    @Environment(RepoStore.self) private var store
    let onExpand: () -> Void
    @ViewState private var preview: WorkspaceDestination?
    @ViewState private var overPreview = false

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onExpand) {
                Image(systemName: "sidebar.left").font(.system(size: 17)).frame(width: 40, height: 36)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help("Expand sidebar").accessibilityLabel("Expand sidebar")
            .accessibilityIdentifier("navigation-rail-expand")
            .padding(.top, 6)
            Button { store.showCommandPalette = true } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 17)).frame(width: 40, height: 36)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help("Quick navigation (⌘K)").accessibilityLabel("Quick navigation")
            Divider().padding(.horizontal, 10).padding(.vertical, 6)
            ScrollView(showsIndicators: false) {
                VStack(spacing: 4) {
                    rows([.home, .repositories])
                    separator
                    rows([.repository])
                    rows(store.pinnedRepositoryPages.map(\.destination))
                    separator
                    rows([.inbox, .myWork, .pullRequests, .issues, .actions, .releases, .projects, .organizations, .gists])
                    separator
                    rows([.assistant, .agents, .flows, .worktrees, .operations])
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
        .onChange(of: WorkspaceLocation(store.destination, section: store.repositorySection)) { _, _ in preview = nil }
        .onChange(of: preview) { _, _ in overPreview = false }
    }

    private var separator: some View { Divider().padding(.horizontal, 4).padding(.vertical, 5) }

    private func rows(_ pages: [WorkspaceDestination]) -> some View {
        ForEach(pages) { page in
            let active = selected(page)
            let disabled = page.needsRepository && store.url == nil
            let count = (page == .repository || page == .changes) ? store.status.count : page == .pullRequests ? store.pullRequests.count : 0
            let title = page.title(gitlab: store.target?.provider == .gitlab)
            Button { store.navigate(page) } label: {
                Group {
                    if let section = page.repositorySection, section == .branches || section == .commits {
                        RepositoryNavigationIcon(section: section).frame(width: 20, height: 20)
                    } else {
                        Image(systemName: page.symbol).font(.system(size: 18, weight: active ? .semibold : .regular))
                    }
                }
                .frame(width: 40, height: 36)
                .foregroundStyle(active ? Color.accentColor : disabled ? Color.secondary.opacity(0.45) : Color.primary.opacity(0.72))
                .background(active ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .leading) { if active { Capsule().fill(Color.accentColor).frame(width: 3, height: 16) } }
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
            .onHover { inside in
                if inside, hasPreview(page), !disabled { preview = page }
                else if !inside { closePreviewSoon(page) }
            }
            .onKeyPress(.rightArrow) {
                guard hasPreview(page), !disabled else { return .ignored }
                preview = page; return .handled
            }
            .accessibilityAction(named: Text("Show preview")) { if hasPreview(page) { preview = page } }
            .popover(isPresented: Binding(get: { preview == page }, set: { if !$0 { preview = nil } }), arrowEdge: .trailing) {
                NavigationRailPreview(page: page, close: { preview = nil })
                    .onHover { inside in overPreview = inside; if !inside { closePreviewSoon(page) } }
            }
            .contextMenu {
                if hasPreview(page) { Button("Show preview") { preview = page } }
                if let section = page.repositorySection {
                    Button(store.isRepositoryPagePinned(section) ? String(localized: "Remove shortcut") : String(localized: "Pin to sidebar")) { store.toggleRepositoryPagePin(section) }
                }
            }
        }
    }

    private func hasPreview(_ page: WorkspaceDestination) -> Bool {
        [.repository, .changes, .commits, .branches, .pullRequests, .agents, .worktrees].contains(page)
    }

    private func closePreviewSoon(_ page: WorkspaceDestination) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            if preview == page, !overPreview { preview = nil }
        }
    }

    private func selected(_ page: WorkspaceDestination) -> Bool {
        if let section = page.repositorySection { return store.destination == .repository && store.repositorySection == section }
        return store.destination == page && (page != .repository || !store.isRepositoryPagePinned(store.repositorySection))
    }
}
