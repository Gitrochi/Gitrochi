import SwiftUI

struct WorkspaceDestinationContent: View {
    @Environment(RepoStore.self) private var store
    var body: some View {
        Group {
            switch store.destination {
            case .home: WorkspaceHomePanel()
            case .repositories: RepositoryLibraryPanel()
            case .repository: RepositoryWorkspace()
            case .changes, .commits: ContentColumn()
            case .branches: LocalBranchesPanel()
            case .compare: RevisionComparisonPanel()
            case .rebase: RebaseWorkbenchPanel()
            case .code: RepositoryCodePanel()
            case .inbox: WorkInboxPanel()
            case .myWork: MyWorkPanel()
            case .pullRequests: PullRequestsWorkspace()
            case .issues: IssuesWorkspacePanel()
            case .actions: ActionsWorkspacePanel()
            case .releases: HostingHubPanel(store: store, section: .releases, onClone: clone)
            case .projects: HostingHubPanel(store: store, section: .projects, onClone: clone)
            case .organizations: HostingHubPanel(store: store, section: .organizations, onClone: clone)
            case .gists: HostingHubPanel(store: store, section: .gists, onClone: clone)
            case .assistant: RepositoryAssistantSheet(embedded: true)
            case .agents: AgentsPanel()
            case .flows: FlowPanel()
            case .worktrees: WorktreesWorkspace()
            case .operations: OperationsWorkspacePanel()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: store.destination) {
            if store.destination == .assistant { await store.openRepositoryAssistant(present: false) }
        }
    }
    private func clone(_ url: String) { store.sheet = .cloneURL(url) }
}

/// 저장소의 여섯 작업은 같은 문맥을 유지하며 전환하고, 바로가기는 사용자가 고른다.
private struct RepositoryWorkspace: View {
    @Environment(RepoStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(RepositorySection.allCases) { section in
                            Button { store.selectRepositorySection(section) } label: {
                                HStack(spacing: 6) {
                                    if section == .branches || section == .commits {
                                        RepositoryNavigationIcon(section: section).frame(width: 15, height: 15)
                                    } else {
                                        Image(systemName: section.symbol).frame(width: 15)
                                    }
                                    Text(section.title)
                                    if section == .changes, store.status.count > 0 {
                                        Text("\(store.status.count)").font(.system(size: 10, weight: .semibold, design: .monospaced))
                                            .padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: Capsule())
                                    }
                                }
                                .font(.system(size: 12, weight: store.repositorySection == section ? .semibold : .medium))
                                .padding(.horizontal, 12).frame(height: 34)
                                .foregroundStyle(store.repositorySection == section ? Color.accentColor : Color.secondary)
                                .background(store.repositorySection == section ? Color.accentColor.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 7))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).accessibilityLabel(section.title)
                            .accessibilityAddTraits(store.repositorySection == section ? .isSelected : [])
                            .contextMenu {
                                Button(store.isRepositoryPagePinned(section) ? String(localized: "Remove shortcut") : String(localized: "Pin to sidebar")) { store.toggleRepositoryPagePin(section) }
                            }
                        }
                    }
                }
                Menu {
                    Text("Keep your favorite tools in the sidebar. All tools stay available in Repository.")
                    ForEach(RepositorySection.allCases) { section in
                        Button { store.toggleRepositoryPagePin(section) } label: {
                            Label(section.title, systemImage: store.isRepositoryPagePinned(section) ? "checkmark.square.fill" : "square")
                        }
                    }
                } label: { Image(systemName: "pin").frame(width: 30, height: 30) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Choose repository shortcuts").accessibilityLabel("Choose repository shortcuts")
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            Group {
                switch store.repositorySection {
                case .changes, .commits: ContentColumn()
                case .branches: LocalBranchesPanel()
                case .compare: RevisionComparisonPanel()
                case .rebase: RebaseWorkbenchPanel()
                case .code: RepositoryCodePanel()
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct PullRequestsWorkspace: View {
    @Environment(RepoStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        if let target = store.target {
            AdaptiveWorkbenchSplit(listWidth: 320) {
                PullRequestBrowser(target: target)
            } detail: {
                Group {
                    if case .pullRequest(let number)? = store.selection {
                        let showingDiff = reviewDiff(number: number) != nil
                        ZStack {
                            // 파일을 확인하는 동안에도 작성 중인 대화와 스크롤 위치를 보존한다.
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
                        VStack(spacing: 18) {
                            Image(systemName: "arrow.triangle.pull").font(.system(size: 32, weight: .light))
                                .foregroundStyle(Color.accentColor).frame(width: 76, height: 76)
                                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 22))
                            Text("Select a pull request").font(.title2.weight(.semibold))
                            Text("Search the list, then review the conversation, files and merge checks here.")
                                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 390)
                            WorkbenchFlow(spacing: 16) {
                                Label("Conversation", systemImage: "bubble.left.and.bubble.right")
                                Label("Changed files", systemImage: "doc.on.doc")
                                Label("Checks", systemImage: "checkmark.circle")
                            }.font(.caption).foregroundStyle(.secondary)
                        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
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

private struct WorktreesWorkspace: View {
    @Environment(RepoStore.self) private var store
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Worktrees").font(.title2.bold()); Spacer(); Button("New worktree…") { store.sheet = .addWorktree(branch: nil, start: nil) } }.padding(22)
            Divider()
            List { WorktreeSection() }.listStyle(.inset)
        }
    }
}
