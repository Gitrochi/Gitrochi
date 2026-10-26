import SwiftUI

/// 저장소 작업을 한곳에 모으고 자주 쓰는 작업만 바로가기로 고정한다.
struct NavigationSidebar: View {
    @Environment(RepoStore.self) private var store
    var focusSearchOnAppear = false
    @ViewState private var query = ""
    @FocusState private var searchFocused: Bool
    @AppStorage("navigationToolsExpanded") private var toolsExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Button { store.showCommandPalette = true } label: { Image(systemName: "magnifyingglass").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("Quick navigation (⌘K)").accessibilityLabel("Quick navigation")
                TextField("Go to a page…", text: $query).textFieldStyle(.plain).font(.system(size: 12))
                    .accessibilityLabel("Find a workspace page").focused($searchFocused)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Clear search").accessibilityLabel("Clear search")
                } else {
                    Text("⌘ K").font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize()
                }
            }.padding(.horizontal, 10).padding(.vertical, 9)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor).opacity(0.4)))
                .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    rows([.home, .repositories])
                    HStack(spacing: 9) {
                        Text("Workspace").font(.system(size: 10, weight: .semibold)).tracking(0.8)
                        Rectangle().frame(height: 1).opacity(0.3)
                        Menu {
                            Text("Keep your favorite tools in the sidebar. All tools stay available in Repository.")
                            ForEach(RepositorySection.allCases) { section in
                                Button { store.toggleRepositoryPagePin(section) } label: {
                                    Label(section.title, systemImage: store.isRepositoryPagePinned(section) ? "checkmark.square.fill" : "square")
                                }
                            }
                        } label: { Image(systemName: "slider.horizontal.3").font(.system(size: 11)).frame(width: 22, height: 22) }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            .help("Choose repository shortcuts").accessibilityLabel("Choose repository shortcuts")
                    }.foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 15).padding(.bottom, 3)
                    rows([.repository])
                    rows(query.isEmpty ? store.pinnedRepositoryPages.map(\.destination) : RepositorySection.allCases.map(\.destination), shortcut: true)
                    groupTitle(store.target?.provider == .gitlab ? "GitLab" : "GitHub")
                    rows([.inbox, .myWork, .pullRequests, .issues, .actions, .releases, .projects, .organizations, .gists])
                    Button { toolsExpanded.toggle() } label: {
                        HStack { Text("Workspace tools").font(.system(size: 10, weight: .semibold)); Spacer(); Image(systemName: toolsExpanded ? "chevron.down" : "chevron.right").font(.caption2) }
                            .foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 18).padding(.bottom, 5)
                    }.buttonStyle(.plain).accessibilityLabel("Workspace tools")
                    if toolsExpanded || !query.isEmpty { rows([.assistant, .agents, .flows, .worktrees, .operations]) }
                }.padding(.horizontal, 8).padding(.bottom, 12)
            }
            Divider()
            SettingsLink { Label("Settings", systemImage: "gearshape").font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10).padding(.horizontal, 12) }
                .buttonStyle(.plain).padding(8).keyboardShortcut(",", modifiers: .command).accessibilityLabel("Settings")
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { if focusSearchOnAppear { searchFocused = true } }
    }

    private func groupTitle(_ text: String) -> some View {
        HStack { Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.8).lineLimit(1); Rectangle().frame(height: 1).opacity(0.3) }
            .foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 18).padding(.bottom, 6)
    }

    private func title(_ page: WorkspaceDestination) -> String { page.title(gitlab: store.target?.provider == .gitlab) }

    private func selected(_ page: WorkspaceDestination) -> Bool {
        if let section = page.repositorySection { return store.destination == .repository && store.repositorySection == section }
        return store.destination == page && (page != .repository || !store.isRepositoryPagePinned(store.repositorySection))
    }

    private func rows(_ pages: [WorkspaceDestination], shortcut: Bool = false) -> some View {
        ForEach(pages.filter { query.isEmpty || title($0).localizedCaseInsensitiveContains(query) || $0.rawValue.localizedCaseInsensitiveContains(query) }) { page in
            let active = selected(page)
            let disabled = page.needsRepository && store.url == nil
            Button { store.navigate(page) } label: {
                HStack(spacing: 10) {
                    navigationIcon(page).font(.system(size: shortcut ? 15 : 16, weight: active ? .semibold : .regular)).frame(width: 21, height: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title(page)).font(.system(size: shortcut ? 12 : 13, weight: active ? .semibold : .medium)).lineLimit(1)
                        if page == .repository {
                            Text(store.url == nil ? String(localized: "Open a repository to get started") : "\(store.name) · \(store.repositorySection.title)")
                                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 2)
                    if (page == .changes || page == .repository), store.status.count > 0 { badge(store.status.count) }
                    if page == .pullRequests, !store.pullRequests.isEmpty { badge(store.pullRequests.count) }
                    if shortcut { Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.tertiary) }
                }.padding(.horizontal, shortcut ? 16 : 12).frame(minHeight: page == .repository ? 54 : 38)
                    .foregroundStyle(active ? Color.accentColor : disabled ? Color.secondary.opacity(0.5) : Color.primary.opacity(0.8))
                    .background(active ? Color.accentColor.opacity(0.11) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .leading) { if active { Capsule().fill(Color.accentColor).frame(width: 3, height: 16) } }
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(disabled)
                .help(disabled ? String(localized: "Open a repository to use this page.") : title(page))
                .accessibilityLabel(title(page))
                .accessibilityValue(active ? String(localized: "Current page") : "")
                .contextMenu {
                    if let section = page.repositorySection {
                        Button(store.isRepositoryPagePinned(section) ? String(localized: "Remove shortcut") : String(localized: "Pin to sidebar")) { store.toggleRepositoryPagePin(section) }
                    }
                }
        }
    }

    @ViewBuilder private func navigationIcon(_ page: WorkspaceDestination) -> some View {
        if let section = page.repositorySection, section == .branches || section == .commits {
            RepositoryNavigationIcon(section: section).frame(width: 19, height: 19)
        } else {
            Image(systemName: page.symbol)
        }
    }

    private func badge(_ count: Int) -> some View {
        Text(count > 999 ? "999+" : String(count)).font(.system(size: 10, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 5).padding(.vertical, 2).background(.quaternary.opacity(0.7), in: Capsule())
    }
}

/// Git의 선과 노드를 직접 그려 브랜치와 커밋을 분명하게 구별한다.
struct RepositoryNavigationIcon: View {
    let section: RepositorySection
    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width, geometry.size.height) / 24
            Path { path in
                if section == .branches {
                    path.move(to: CGPoint(x: 6, y: 7)); path.addLine(to: CGPoint(x: 6, y: 17))
                    path.move(to: CGPoint(x: 6, y: 15)); path.addCurve(to: CGPoint(x: 18, y: 7), control1: CGPoint(x: 6, y: 9), control2: CGPoint(x: 18, y: 15))
                    for center in [CGPoint(x: 6, y: 4), CGPoint(x: 6, y: 20), CGPoint(x: 18, y: 4)] { path.addEllipse(in: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)) }
                } else {
                    path.move(to: CGPoint(x: 2, y: 12)); path.addLine(to: CGPoint(x: 8, y: 12))
                    path.move(to: CGPoint(x: 16, y: 12)); path.addLine(to: CGPoint(x: 22, y: 12))
                    path.addEllipse(in: CGRect(x: 8, y: 8, width: 8, height: 8))
                }
            }.applying(CGAffineTransform(scaleX: scale, y: scale)).stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }.accessibilityHidden(true)
    }
}
