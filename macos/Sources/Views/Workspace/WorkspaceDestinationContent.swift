import SwiftUI

struct WorkspaceDestinationContent: View {
    @Environment(RepoStore.self) private var store
    var body: some View {
        Group {
            switch store.destination {
            case .home: WelcomeView()
            case .repository: RepositoryScreen()
            case .compare: RevisionComparisonPanel()
            case .rebase: RebaseWorkbenchPanel()
            case .code: RepositoryCodePanel()
            case .pullRequests: PullRequestsWorkspace()
            case .issues: IssuesWorkspacePanel()
            case .actions: ActionsWorkspacePanel()
            case .account: AccountWorkspacePanel()
            case .flows: FlowPanel()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
