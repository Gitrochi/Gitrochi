import SwiftUI

/// 탐색은 사이드바에, 현재 작업의 목적과 원격 상태는 작업 영역 머리에 둔다.
struct RepoView: View {
    @Environment(RepoStore.self) private var store
    @ViewState private var sidebarPresentation = SidebarPresentationState()
    @ViewState private var sidebarCollapsed = false
    @ViewState private var sidebarExpandRequest = 0
    @ViewState private var pendingCommand: WorkspaceCommand?

    private var showsNavigationRail: Bool { sidebarPresentation.visibility == .detailOnly || sidebarCollapsed }

    var body: some View {
        NavigationSplitView(columnVisibility: Binding(get: { sidebarPresentation.visibility }, set: { sidebarPresentation.setVisibility($0) })) {
            NavigationSidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
                .background(SidebarVisibilityObserver(expandRequest: sidebarExpandRequest) { sidebarCollapsed = $0 })
                .disabled(showsNavigationRail)
                .accessibilityHidden(showsNavigationRail)
        } detail: {
            HStack(spacing: 0) {
                if showsNavigationRail {
                    NavigationSidebarRail {
                        sidebarPresentation.expand()
                        sidebarExpandRequest += 1
                    }
                    Divider()
                }
                VStack(spacing: 0) {
                    workspaceHeader
                    Divider()
                    if ToolStore.shared.path(.git) == nil {
                        HStack {
                            Text("Install Git or locate the existing executable to work with local repositories.").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            SettingsLink { Text("Locate Git…") }
                        }.padding(12)
                        Divider()
                    }
                    WorkspaceDestinationContent()
                    if store.showTerminal, !(store.destination == .repository && [.changes, .commits].contains(store.repositorySection)) {
                        Divider(); TerminalPanel().frame(height: 240)
                    }
                    feedback
                }
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(store.name)
        .tint(Color(red: 0.43, green: 0.33, blue: 0.89))
        .accentColor(Color(red: 0.43, green: 0.33, blue: 0.89))
        .toolbar { toolbar }
        .sheet(isPresented: Binding(get: { store.showCommandPalette }, set: { store.showCommandPalette = $0 }), onDismiss: {
            let command = pendingCommand
            pendingCommand = nil
            command?.action()
        }) {
            WorkspaceCommandPalette { command in
                pendingCommand = command
                store.showCommandPalette = false
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width < 1180 } action: { sidebarPresentation.setNarrow($0) }
        .onChange(of: store.sidebarToggleRequest) { _, _ in
            if showsNavigationRail { sidebarPresentation.expand(); sidebarExpandRequest += 1 }
            else { sidebarPresentation.setVisibility(.detailOnly) }
        }
        .onChange(of: AccountStore.shared.revision) { _, _ in
            Task { await store.refreshHostingAccount() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in store.navigationPreferencesVersion += 1 }
    }

    private var workspaceHeader: some View {
        HStack(spacing: 16) {
            HStack(spacing: 5) {
                Button { store.moveWorkspaceHistory(-1) } label: { Image(systemName: "chevron.left") }.disabled(store.navigationPosition == 0).help("Previous page")
                Button { store.moveWorkspaceHistory(1) } label: { Image(systemName: "chevron.right") }.disabled(store.navigationPosition + 1 >= store.navigationTrail.count).help("Next page")
            }.buttonStyle(.borderless)
            Label(store.destination.title(gitlab: store.target?.provider == .gitlab), systemImage: store.destination.symbol)
                .font(.callout.weight(.semibold)).lineLimit(1).fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 3) {
                Label(store.url == nil ? "Gitrochi" : (store.headBranch ?? String(localized: "Detached HEAD")), systemImage: "arrow.triangle.branch")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                    .help(store.headBranch ?? store.headHash ?? "")
                Text(remoteStatus)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(remoteStatus)
            }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            if store.destination == .repository && store.repositorySection == .commits {
                Button { store.showHistoryInspector.toggle() } label: {
                    Image(systemName: "sidebar.right").foregroundStyle(store.showHistoryInspector ? Color.accentColor : .secondary)
                }
                .buttonStyle(.borderless).help("Show or hide commit details (⌥⌘I)")
                .accessibilityLabel("Toggle commit details")
                .accessibilityValue(store.showHistoryInspector ? String(localized: "Shown") : String(localized: "Hidden"))
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 62)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var remoteStatus: String {
        guard let upstream = store.status.upstream else {
            return store.remotes.isEmpty ? String(localized: "No remote configured") : String(localized: "Push to publish this branch")
        }
        if store.status.ahead == 0 && store.status.behind == 0 {
            return upstream + " · " + String(localized: "Up to date")
        }
        return upstream + " · " + String(localized: "↑\(store.status.ahead) to push · ↓\(store.status.behind) to pull")
    }

    @ViewBuilder private var feedback: some View {
        if let text = store.busy ?? store.graphProgress ?? store.operationNotice {
            Divider()
            HStack(spacing: 8) {
                if store.busy != nil || store.graphProgress != nil { ProgressView().controlSize(.mini) }
                else { Image(systemName: "checkmark.circle").foregroundStyle(.green) }
                Text(text).font(.caption).lineLimit(2)
                Spacer()
                if store.busy == nil, store.graphProgress == nil {
                    Button { store.operationNotice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss notification")
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(.bar)
            .accessibilityElement(children: .combine)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Menu {
                ForEach(store.recents.filter { $0 != store.url }, id: \.self) { u in
                    Button(u.lastPathComponent) { Task { await store.openOrReport(u) } }
                }
                Divider()
                Button("Open repository…") { store.presentOpenPanel() }
                Button("Clone repository…") { store.sheet = .clone }
                Divider()
                StructureGraphMenu(store: store)
                Button("Workspace overview…") { store.navigate(.home) }
                Button("Issues and mentions…") { store.navigate(.inbox) }.disabled(store.target == nil)
                Button("Repository tools…") { store.navigate(.operations) }
                Button("Connect external AI with MCP…") { store.sheet = .mcpConnection }
                Divider()
                Button("Close tab") { NSApp.keyWindow?.performClose(nil) }
            } label: { ToolLabel(title: String(localized: "Repository"), icon: "folder") }
            .help("Open or clone another repository, recent repositories, structure graph, close tabs")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { Task { await store.fetch() } } label: {
                ToolLabel(title: "Fetch", icon: "arrow.triangle.2.circlepath")
            }
            .disabled(store.busy != nil || store.remotes.isEmpty)
            .help(store.remotes.isEmpty ? String(localized: "No remote configured") : String(localized: "Fetches new commits and branches from all remotes. Your branches aren't changed. (⇧⌘F)"))
            Menu {
                Button("Pull (as configured in git)") { Task { await store.pull(.standard) } }
                Button("Pull — fast-forward only") { Task { await store.pull(.fastForward) } }
                Button("Pull — merge") { Task { await store.pull(.merge) } }
                Button("Pull — rebase") { Task { await store.pull(.rebase) } }
            } label: {
                ToolLabel(title: store.status.behind > 0 ? "Pull ↓\(store.status.behind)" : "Pull", icon: "arrow.down")
            } primaryAction: { Task { await store.pull() } }
            .disabled(store.busy != nil || store.status.upstream == nil)
            .help(store.status.upstream == nil ? String(localized: "Push this branch first to set up remote tracking.") : String(localized: "Bring remote commits into this branch. Choose a pull strategy from the menu. (⇧⌘L)"))
            Menu {
                Button("Push") { Task { await store.push() } }
                Button("Force push (with lease)…") {
                    Task { await store.push(force: true) }
                }
            } label: {
                ToolLabel(title: store.status.ahead > 0 ? "Push ↑\(store.status.ahead)" : "Push", icon: "arrow.up")
            } primaryAction: { Task { await store.push() } }
            .disabled(store.busy != nil || store.remotes.isEmpty || store.headBranch == nil || store.headHash == nil)
            .help(store.remotes.isEmpty ? String(localized: "No remote configured") : store.headBranch == nil || store.headHash == nil ? String(localized: "Create a branch with a commit before pushing.") : String(localized: "Pushes this branch to the remote; sets up tracking on the first push. (⇧⌘P)"))
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button(store.undoStack.last.map { String(localized: "Undo: \($0.title)") } ?? String(localized: "Undo")) { store.confirmUndo() }
                    .disabled(store.undoStack.isEmpty)
                Button("Refresh") { Task { await store.reload() } }
                Button("Ask AI about changes…") { Task { await store.openChangeQuestion() } }
                Button("Repository assistant…") { store.navigate(.assistant) }
                Button("Compare revisions…") { store.navigate(.compare) }
                Divider()
                Button("New branch…") { store.requestNewBranch() }
                Button("New worktree…") { store.sheet = .addWorktree(branch: nil, start: nil) }
                if let target = store.target {
                    Button("New \(target.provider.requestShort)…") { store.sheet = .createPullRequest }
                        .disabled(store.headBranch == nil)
                }
                Divider()
                Button("Stash… (save changes for later)") { store.sheet = .stash }.disabled(store.status.isEmpty)
                Button("Pop (apply the latest stash)") { Task { await store.stashPop() } }.disabled(store.stashes.isEmpty)
                Divider()
                Button("Start agent session…") { store.sheet = .startAgent(path: store.url?.path) }
                if let url = store.url {
                    Button("Run \(AgentCenter.shared.defaultKind.title) here") { store.startAgent(in: url.path) }
                }
            } label: { ToolLabel(title: String(localized: "Actions"), icon: "ellipsis.circle") }
            .disabled(store.busy != nil || store.url == nil)
            .help("Branches, worktrees, pull requests, stash and undo")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { store.toggleTerminal() } label: {
                ToolLabel(title: String(localized: "Terminal"), icon: store.showTerminal ? "apple.terminal.fill" : "apple.terminal")
            }
            .help("Show or hide the terminal. Shells keep running when hidden. (⌃`)")
            .disabled(store.url == nil)
        }
        ToolbarItem(placement: .primaryAction) {
            AccountQuickControls()
        }
    }
}

struct InspectorView: View {
    @Environment(RepoStore.self) private var store
    var body: some View {
        switch store.selection {
        case .wip?: WorkingChangesView()
        case .commit(let sha)?: CommitDetailView(sha: sha)
        case .worktree(let path)?: WorktreeChangesView(path: path)
        case .pullRequest(let n)?: PullRequestDetailView(number: n)
        case nil:
            ContentUnavailableView("No commit selected", systemImage: "point.3.connected.trianglepath.dotted",
                                   description: Text("Select a commit in the graph."))
        }
    }
}

/// 주요 작업은 창 너비와 상관없이 이름을 함께 표시한다.
struct ToolLabel: View {
    let title: String
    let icon: String
    var body: some View {
        Label(title, systemImage: icon).labelStyle(.titleAndIcon).fixedSize()
    }
}
