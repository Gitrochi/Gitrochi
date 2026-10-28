import SwiftUI

struct WorkspaceDestinationContent: View {
    @Environment(RepoStore.self) private var store
    /// Pages with the shared title row; Home has its own welcome and Repository is the work screen
    private static let titled: Set<WorkspaceDestination> = [.compare, .rebase, .code, .pullRequests, .issues, .actions, .releases, .projects, .account, .flows]

    var body: some View {
        VStack(spacing: 0) {
            if Self.titled.contains(store.destination) {
                PageHeader(page: store.destination)
                Divider()
            }
            page
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var page: some View {
        Group {
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
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The title row every workspace page shares (Windows: pages/repo/ui/PageHeader.tsx). A page reached from the repository
/// screen also offers the way back.
struct PageHeader: View {
    @Environment(RepoStore.self) private var store
    let page: WorkspaceDestination

    var body: some View {
        HStack(spacing: 10) {
            if store.cameFromRepository, page.returnsToRepository {
                Button { store.navigate(.repository) } label: { Label("Repository", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("[", modifiers: .command)
                    .help("Back to the repository screen (⌘[)")
                    .accessibilityLabel("Back to the repository screen")
                Divider().frame(height: 20)
            }
            Image(systemName: page.symbol).font(.system(size: 18)).foregroundStyle(.secondary)
            Text(page.title(gitlab: store.target?.provider == .gitlab))
                .font(.title2.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .frame(height: 50)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The repository screen: branches and refs | graph or diff with the terminal below | uncommitted changes or details
struct RepositoryScreen: View {
    @AppStorage("repositorySidebarWidth") private var sidebarWidth = 250.0
    @AppStorage("repositoryInspectorWidth") private var inspectorWidth = 380.0

    var body: some View {
        WorkspaceColumns(width: $sidebarWidth, fixedTrailing: false, minimumFlexible: 560) {
            SidebarView()
        } trailing: {
            WorkspaceColumns(width: $inspectorWidth, fixedTrailing: true, minimumFlexible: 480) {
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
                Button("Connect account…") { openSettings() }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private func reviewDiff(number: Int) -> DiffSource? {
        guard let source = store.diffSource, case .review(let n, _, _) = source, n == number else { return nil }
        return source
    }
}
