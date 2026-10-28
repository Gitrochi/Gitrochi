import SwiftUI

/// The repository window: the page list on the left (an icon rail once a repository is open), the page on the right.
struct RepoView: View {
    @Environment(RepoStore.self) private var store
    @ViewState private var sidebarPresentation = SidebarPresentationState()
    @ViewState private var sidebarCollapsed = false
    @ViewState private var sidebarExpandRequest = 0
    @ViewState private var pendingCommand: WorkspaceCommand?
    @ViewState private var pageHeight: CGFloat = 800

    private var showsNavigationRail: Bool { sidebarPresentation.visibility == .detailOnly || sidebarCollapsed }

    var body: some View {
        NavigationSplitView(columnVisibility: Binding(get: { sidebarPresentation.visibility }, set: { sidebarPresentation.setVisibility($0) })) {
            NavigationSidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
                // the page list and the rail carry their own collapse and expand buttons
                .toolbar(removing: .sidebarToggle)
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
                    if ToolStore.shared.path(.git) == nil {
                        HStack {
                            Text("Install Git or locate the existing executable to work with local repositories.").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            SettingsLink { Text("Locate Git…") }
                        }.padding(12)
                        Divider()
                    }
                    WorkspaceDestinationContent()
                    // the repository screen has its own terminal under the graph; the other pages get one below
                    if store.showTerminal, store.destination != .repository {
                        TerminalPanel(columnHeight: pageHeight)
                    }
                    feedback
                }
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pageHeight = $0 }
            }
            // Split details must shrink with the viewport instead of centering a page's larger minimum height.
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationTitle(store.windowTitle)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .background(ToolbarTitles.Observer())
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
        // opening the repository screen folds the page list into the rail, so the branch list takes its place
        .onChange(of: store.destination) { _, page in
            if page == .repository { sidebarPresentation.setVisibility(.detailOnly) }
        }
        .onAppear { if store.destination == .repository { sidebarPresentation.setVisibility(.detailOnly) } }
        .onChange(of: AccountStore.shared.revision) { _, _ in
            Task { await store.refreshHostingAccount() }
        }
    }

    private var subtitle: String {
        guard store.url != nil else { return "" }
        guard let branch = store.headBranch else {
            return store.headHash.map { String(localized: "Detached HEAD · \($0.prefix(7))") } ?? ""
        }
        var s = branch
        if let up = store.status.upstream {
            s += "  →  \(up)"
            if store.status.ahead > 0 { s += "  ↑\(store.status.ahead)" }
            if store.status.behind > 0 { s += "  ↓\(store.status.behind)" }
        }
        if store.repoState != .clean { s += "  ·  \(store.repoState.title)" }
        return s
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
                if store.recents.count > 1 { Divider() }
                Button("Open repository…") { store.presentOpenPanel() }
                Button("Clone repository…") { store.sheet = .clone }
                Divider()
                StructureGraphMenu(store: store)
                Button("Repository tools…") { store.sheet = .localWorkflows }.disabled(store.url == nil)
                Divider()
                Button("Ask AI about changes…") { Task { await store.openChangeQuestion() } }.disabled(store.url == nil)
                Button("Repository assistant…") { Task { await store.openRepositoryAssistant() } }.disabled(store.url == nil)
                Button("Connect external AI with MCP…") { store.sheet = .mcpConnection }.disabled(store.url == nil)
                Divider()
                Button("Close tab") { NSApp.keyWindow?.performClose(nil) }
            } label: {
                ToolLabel(title: String(localized: "Repository"), icon: "folder")
            }
            .hoverTip(String(localized: "Repository"), String(localized: "Open or clone another repository, recent repositories, structure graph, close tabs"))
        }

        // flexible space: the title and repository menu stay leading, the actions move to the trailing edge
        ToolbarItem(placement: .primaryAction) { Spacer() }

        ToolbarItemGroup(placement: .primaryAction) {
            Button { store.confirmUndo() } label: {
                ToolLabel(title: String(localized: "Undo"), icon: "arrow.uturn.backward")
            }
            .disabled(store.undoStack.isEmpty || store.busy != nil)
            .hoverTip(String(localized: "Undo"),
                      store.undoStack.last.map { String(localized: "Undoes the last operation, “\($0.title)”. Undoing a commit keeps its changes.") }
                        ?? String(localized: "Nothing to undo. Operations like commit, merge, rebase, checkout and branch deletion can be undone here."),
                      shortcut: "⌥⌘Z")

            Button { store.navigate(.repository); store.showArea(.changes) } label: {
                ToolLabel(title: store.status.isEmpty ? String(localized: "Changes") : String(localized: "Changes \(store.status.count)"), icon: "square.and.pencil")
            }
            .disabled(store.url == nil)
            .hoverTip(String(localized: "Uncommitted changes"),
                      store.status.isEmpty ? String(localized: "No modified files. When you edit files, you can stage and commit them here.")
                                           : String(localized: "\(store.status.count) modified files — stage and commit them."),
                      shortcut: "⌘1")

            Button { Task { await store.fetch() } } label: {
                ToolLabel(title: "Fetch", icon: "arrow.triangle.2.circlepath")
            }
            .disabled(store.busy != nil || store.remotes.isEmpty)
            .hoverTip("Fetch", String(localized: "Fetches new commits and branches from all remotes. Your branches aren't changed."), shortcut: "⇧⌘F")

            Menu {
                Button("Pull (as configured in git)") { Task { await store.pull(.standard) } }
                Button("Pull — fast-forward only") { Task { await store.pull(.fastForward) } }
                Button("Pull — merge") { Task { await store.pull(.merge) } }
                Button("Pull — rebase") { Task { await store.pull(.rebase) } }
            } label: {
                ToolLabel(title: store.status.behind > 0 ? "Pull ↓\(store.status.behind)" : "Pull", icon: "arrow.down")
            } primaryAction: {
                Task { await store.pull() }
            }
            .disabled(store.busy != nil || store.status.upstream == nil)
            .hoverTip("Pull",
                      store.status.upstream == nil ? String(localized: "This branch has no remote tracking branch to pull from (push it first to create one).")
                      : (store.status.behind > 0 ? String(localized: "Brings \(store.status.behind) new commits from the remote into the current branch.") : String(localized: "Syncs the current branch with the remote (no commits to pull right now)."))
                        + String(localized: " Choose merge or rebase from ▾."),
                      shortcut: "⇧⌘L")

            Menu {
                Button("Push") { Task { await store.push() } }
                Button("Force push (with lease)…") { Task { await store.push(force: true) } }
            } label: {
                ToolLabel(title: store.status.ahead > 0 ? "Push ↑\(store.status.ahead)" : "Push", icon: "arrow.up")
            } primaryAction: {
                Task { await store.push() }
            }
            .disabled(store.busy != nil || store.remotes.isEmpty || store.headBranch == nil || store.headHash == nil)
            .hoverTip("Push",
                      (store.status.upstream == nil ? String(localized: "Pushes the current branch to the remote for the first time and sets up tracking.")
                       : (store.status.ahead > 0 ? String(localized: "Pushes \(store.status.ahead) unpushed commits to the remote.") : String(localized: "Pushes the current branch to the remote (no commits to push right now).")))
                        + String(localized: " Force push from ▾."),
                      shortcut: "⇧⌘P")

            Menu {
                Button("New branch…") { store.requestNewBranch() }
                Button("New worktree…") { store.sheet = .addWorktree(branch: nil, start: nil) }
                Button("Compare revisions…") { store.navigate(.compare) }
                if let url = store.url {
                    Divider()
                    Button("Run \(AgentCenter.shared.defaultKind.title) here") { store.startAgent(in: url.path) }
                    Button("Start agent session…") { store.sheet = .startAgent(path: url.path) }
                }
            } label: {
                ToolLabel(title: String(localized: "Branch"), icon: "arrow.triangle.branch")
            } primaryAction: {
                store.requestNewBranch()
            }
            .disabled(store.url == nil)
            .hoverTip(String(localized: "Branch"), String(localized: "Creates a new branch at the current position. From ▾: new worktree, run an agent (Claude Code, Codex, Gemini)."), shortcut: "⇧⌘B")

            if let t = store.target {
                Button { store.sheet = .createPullRequest } label: {
                    ToolLabel(title: String(localized: "New \(t.provider.requestShort)"), icon: "arrow.triangle.pull")
                }
                .disabled(store.headBranch == nil)
                .hoverTip(String(localized: "New \(t.provider.requestShort)"), String(localized: "Creates a \(t.provider.requestName) from the current branch (\(store.headBranch ?? "-")). Pushes first if needed."))
            }

            Menu {
                Button("Stash… (save changes for later)") { store.sheet = .stash }
                    .disabled(store.status.isEmpty)
                Button("Pop (apply the latest stash)") { Task { await store.stashPop() } }
                    .disabled(store.stashes.isEmpty)
            } label: {
                ToolLabel(title: store.stashes.isEmpty ? "Stash" : "Stashes \(store.stashes.count)", icon: "tray.and.arrow.down")
            } primaryAction: {
                if !store.status.isEmpty { store.sheet = .stash } else { Task { await store.stashPop() } }
            }
            .disabled(store.status.isEmpty && store.stashes.isEmpty)
            .hoverTip("Stash",
                      (store.status.isEmpty ? String(localized: "Applies the most recently stashed changes (Pop).") : String(localized: "Saves uncommitted changes for later."))
                        + (store.stashes.isEmpty ? "" : String(localized: " \(store.stashes.count) stashes saved.")) + String(localized: " Choose Stash or Pop from ▾."),
                      shortcut: "⇧⌘S")

            Button { store.toggleTerminal() } label: {
                ToolLabel(title: String(localized: "Terminal"), icon: store.showTerminal ? "apple.terminal.fill" : "apple.terminal")
            }
            .disabled(store.url == nil)
            .hoverTip(String(localized: "Terminal"),
                      store.showTerminal ? String(localized: "Hides the terminal panel below. Shells keep running.")
                                         : String(localized: "Opens a terminal in this repository's folder below the graph. The graph updates as soon as you run git commands."),
                      shortcut: "⌃`")
        }
        // the hosting account and Git identity stay in the toolbar's trailing corner, in a capsule of their own:
        // without the gap macOS draws the terminal button and the account in one shared capsule
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        if #available(macOS 26.0, *) {
            // Keep the account control separate from the terminal's shared glass background.
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        ToolbarItem(placement: .primaryAction) {
            AccountQuickControls()
        }
    }
}

/// The right column of the repository screen: uncommitted changes, or the details of what is selected in the graph
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

/// Toolbar buttons show their icon, and their title beside it when the toolbar is set to show text; what they do is in the hover tip
struct ToolLabel: View {
    let title: String
    let icon: String
    @AppStorage(ToolbarTitles.key) private var showsTitles = false
    var body: some View {
        if showsTitles {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(title).font(.system(size: 12))
            }
            .fixedSize()
            .accessibilityElement(children: .combine)
        } else {
            Label(title, systemImage: icon).labelStyle(.iconOnly)
        }
    }
}
