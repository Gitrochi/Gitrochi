import SwiftUI

struct WorkspaceDestinationContent: View {
    @Environment(RepoStore.self) private var store

    /// No title row: the selected sidebar item names the page and the toolbar is the only title (docs/design.md › App shell).
    /// VoiceOver still hears the page name.
    var body: some View {
        page
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(store.destination.title(gitlab: store.target?.provider == .gitlab)))
    }

    @ViewBuilder private var page: some View {
        Group {
            if store.url == nil && (store.destination.needsRepository || [.issues, .releases].contains(store.destination)) {
                WorkspaceHomePanel(repositoryOnly: true)
            } else {
            switch store.destination {
            case .home: WorkspaceHomePanel()
            case .repository: RepositoryScreen()
            case .compare: RevisionComparisonPanel()
            case .rebase: RebaseWorkbenchPanel()
            case .code: RepositoryCodePanel()
            case .pullRequests: PullRequestsWorkspace()
            case .issues: IssuesWorkspacePanel()
            case .actions: ActionsWorkspacePanel()
            // Releases and Projects keep pages of their own, apart from the account's lists
            case .releases: HostingHubPanel(store: store, section: .releases, onClone: { store.sheet = .cloneURL($0) })
            case .projects: HostingHubPanel(store: store, section: .projects, onClone: { store.sheet = .cloneURL($0) })
            case .account: AccountWorkspacePanel()
            case .flows: FlowPanel()
            case .ledger: LedgerWorkspaceView(repositoryPath: store.url?.path)
            }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The repository screen: branches and refs | graph or diff with the terminal below | uncommitted changes or details
struct RepositoryScreen: View {
    @AppStorage("repositorySidebarWidth") private var sidebarWidth = 250.0
    @AppStorage("repositoryInspectorWidth") private var inspectorWidth = 380.0
    @AppStorage("repositoryInspectorCollapsed") private var inspectorCollapsed = false
    /// While the page list slides, the side columns keep their widths and the centre one is cut off (PageListFold)
    @Environment(\.pageListOverhang) private var overhang

    var body: some View {
        WorkspaceColumns(width: $sidebarWidth, fixedTrailing: false, minimumFlexible: 560, overhang: overhang) {
            SidebarView()
        } trailing: {
            WorkspaceColumns(width: $inspectorWidth, fixedTrailing: true, minimumFlexible: 480, trailingCollapsed: inspectorCollapsed,
                             overhang: overhang) {
                ContentColumn()
            } trailing: {
                InspectorView()
            }
        }
    }
}

private struct PullRequestsWorkspace: View {
    @Environment(RepoStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        if let target = store.target {
            AdaptiveWorkbenchSplit(listWidth: 290) {
                ScrollView { PullRequestSection(target: target, onPage: true).padding(.vertical, 6) }
                    .environment(\.sidebarFlyout, true)
                    .background(Color(nsColor: .windowBackgroundColor))
            } detail: {
                Group {
                    if case .pullRequest(let number)? = store.selection {
                        let showingDiff = reviewDiff(number: number) != nil
                        ZStack {
                            // the conversation keeps its draft and scroll position while a file is open
                            PullRequestDetailView(number: number)
                                .opacity(showingDiff ? 0 : 1)
                                .disabled(showingDiff)
                                .allowsHitTesting(!showingDiff).accessibilityHidden(showingDiff)
                            if let source = reviewDiff(number: number) {
                                VStack(spacing: 0) {
                                    HStack { Button("Back to conversation") { store.closeDiff() }; Spacer(); Text("\(target.provider.requestShort) #\(number)").font(.caption) }.padding(10)
                                    Divider(); DiffView(source: source)
                                }.background(Color(nsColor: .windowBackgroundColor))
                            }
                        }
                    } else {
                        ContentUnavailableView("Select a pull request", systemImage: "arrow.triangle.pull", description: Text("Search the list, then review the conversation, files and merge checks here."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }.task { await store.loadPullRequests() }
        } else {
            VStack(spacing: 14) {
                ContentUnavailableView("No hosting remote", systemImage: "arrow.triangle.pull", description: Text("Open a repository with a GitHub or GitLab remote to use this workspace."))
                Button("Open repository…") { store.presentOpenPanel() }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private func reviewDiff(number: Int) -> DiffSource? {
        guard let source = store.diffSource, case .review(let n, _, _) = source, n == number else { return nil }
        return source
    }
}
