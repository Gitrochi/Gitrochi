import SwiftUI

/// The repository window: the page list on the left (an icon rail once a repository is open), the page on the right.
struct RepoView: View {
    @Environment(RepoStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("repositoryInspectorCollapsed") private var inspectorCollapsed = false
    @ViewState private var sidebarPresentation = SidebarPresentationState()
    @ViewState private var sidebarCollapsed = false
    @ViewState private var sidebarExpandRequest = 0
    @ViewState private var pendingCommand: WorkspaceCommand?
    @ViewState private var pageHeight: CGFloat = 800
    /// The page list is sliding in or out, when a page's flexible column is laid out once for the whole slide (PageListFold)
    @ViewState private var pageListSliding = false
    @ViewState private var slideEnd: Task<Void, Never>?

    private var showsNavigationRail: Bool { sidebarPresentation.visibility == .detailOnly || sidebarCollapsed }
    private var sidebarAnimation: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.24) }

    var body: some View {
        NavigationSplitView(columnVisibility: Binding(get: { sidebarPresentation.visibility }, set: { sidebarPresentation.setVisibility($0) })) {
            NavigationSidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
                // the toolbar's own sidebar toggle folds and expands the page list
                .toolbar(removing: .sidebarToggle)
                .background(SidebarVisibilityObserver(expandRequest: sidebarExpandRequest, animateExpansion: !reduceMotion,
                                                      expansionAllowed: sidebarPresentation.visibility != .detailOnly) {
                    sidebarCollapsed = $0
                })
                .disabled(showsNavigationRail)
                .accessibilityHidden(showsNavigationRail)
        } detail: {
            NavigationDetailColumn(sliding: pageListSliding) {
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
        // the title keeps naming the window; the toolbar shows it as the repository button instead
        .navigationTitle(store.windowTitle)
        .toolbar(removing: .title)
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
        .onGeometryChange(for: Bool.self) { $0.size.width < 1180 } action: { narrow in
            withAnimation(sidebarAnimation) { sidebarPresentation.setNarrow(narrow) }
        }
        .onChange(of: store.sidebarToggleRequest) { _, _ in
            if showsNavigationRail { expandSidebar() }
            else { slidePageList { sidebarPresentation.setVisibility(.detailOnly) } }
        }
        // opening the repository screen folds the page list into the rail, so the branch list takes its place
        .onChange(of: store.destination) { _, page in
            if page == .repository, store.url != nil {
                slidePageList { sidebarPresentation.fold() }
            }
        }
        .onAppear { if store.destination == .repository, store.url != nil { sidebarPresentation.fold() } }
        .onChange(of: AccountStore.shared.revision) { _, _ in
            Task { await store.refreshHostingAccount() }
        }
    }

    private func expandSidebar() {
        slidePageList {
            sidebarPresentation.expand()
            sidebarExpandRequest += 1
        }
    }

    /// Folds or opens the page list. A page's flexible column is laid out once for the whole slide, so the flag stays
    /// up until the slide's quarter second is safely over; the column then takes the width that shows.
    private func slidePageList(_ change: () -> Void) {
        guard let sidebarAnimation else { return change() }
        pageListSliding = true
        withAnimation(sidebarAnimation, change)
        slideEnd?.cancel()
        slideEnd = Task {
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { pageListSliding = false }
        }
    }

    /// The repository button's second line: the branch with ↑↓ beside it, or what is in progress instead of the counts
    @ViewBuilder private var branchLine: some View {
        let branch = store.headBranch ?? store.headHash.map { String(localized: "Detached HEAD · \($0.prefix(7))") } ?? ""
        HStack(spacing: 6) {
            Text(verbatim: branch).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            if store.repoState != .clean {
                Text(store.repoState.title).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            } else if store.status.upstream != nil, store.status.ahead + store.status.behind > 0 {
                HStack(spacing: 5) {
                    if store.status.ahead > 0 { Text(verbatim: "↑\(store.status.ahead)") }
                    if store.status.behind > 0 { Text(verbatim: "↓\(store.status.behind)") }
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.primary.opacity(0.8))
                .fixedSize()
            }
        }
        .font(.system(size: 11))
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
                    Button { store.operationNotice = nil } label: { DesignIconImage(icon: .close) }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss notification")
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(.bar)
            .accessibilityElement(children: .combine)
        }
    }

    private var toolbarSet: ToolbarSet { ToolbarSet(destination: store.destination, hasRepository: store.url != nil) }
    private var recommendedSync: RecommendedSync {
        RecommendedSync(ahead: store.status.ahead, behind: store.status.behind, hasUpstream: store.status.upstream != nil)
    }

    /// Repository pages get the Git actions, other pages More and the terminal, a window without a repository only the
    /// account (docs/design.md › App shell). Ahead/behind counts live on the repository button, not on the actions.
    /// Every item draws its own capsule (ToolbarCapsule), so all capsules are 36pt high and 8pt apart.
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            ToolbarCapsule {
                Button { store.sidebarToggleRequest += 1 } label: {
                    Label(sidebarToggleTitle, systemImage: "sidebar.left").labelStyle(.iconOnly).font(.system(size: 14))
                }
                .buttonStyle(ToolbarCapsuleButtonStyle())
                .help(sidebarToggleTitle + " (⌃⌘S)")
            }
        }
        .ownCapsule()
        ToolbarItem(placement: .navigation) { ToolbarCapsule { repositoryButton } }.ownCapsule()
        if store.cameFromRepository, store.destination.returnsToRepository {
            ToolbarItem(placement: .navigation) {
                ToolbarCapsule {
                    Button { store.navigate(.repository) } label: { TitledToolLabel(title: String(localized: "Repository"), icon: "chevron.left") }
                        .buttonStyle(ToolbarCapsuleButtonStyle(titled: true))
                        .keyboardShortcut("[", modifiers: .command)
                        .help("Back to the repository screen (⌘[)")
                        .accessibilityLabel("Back to the repository screen")
                }
            }
            .ownCapsule()
        }

        // flexible space: the repository button stays leading, the actions move to the trailing edge
        ToolbarItem(placement: .primaryAction) { Spacer() }

        if toolbarSet == .repository {
            ToolbarItem(placement: .primaryAction) { ToolbarCapsule { changesButton } }.ownCapsule()
            // Fetch, Pull and Push share a capsule; the recommended one moves into a filled capsule of its own
            if recommendedSync == .pull {
                ToolbarItem(placement: .primaryAction) { ToolbarCapsule { fetchButton } }.ownCapsule()
                ToolbarItem(placement: .primaryAction) { ToolbarCapsule(prominent: true) { pullButton } }.ownCapsule()
                ToolbarItem(placement: .primaryAction) { ToolbarCapsule { pushButton } }.ownCapsule()
            } else if recommendedSync == .push {
                ToolbarItem(placement: .primaryAction) {
                    ToolbarCapsule {
                        fetchButton
                        pullButton
                    }
                }
                .ownCapsule()
                ToolbarItem(placement: .primaryAction) { ToolbarCapsule(prominent: true) { pushButton } }.ownCapsule()
            } else {
                ToolbarItem(placement: .primaryAction) {
                    ToolbarCapsule {
                        fetchButton
                        pullButton
                        pushButton
                    }
                }
                .ownCapsule()
            }
            ToolbarItem(placement: .primaryAction) {
                ToolbarCapsule {
                    branchMenu
                    moreMenu
                }
            }
            .ownCapsule()
        } else if toolbarSet == .page {
            ToolbarItem(placement: .primaryAction) { ToolbarCapsule { moreMenu } }.ownCapsule()
        }

        if toolbarSet != .noRepository {
            ToolbarItem(placement: .primaryAction) {
                ToolbarCapsule {
                    terminalButton
                    if toolbarSet == .repository { rightPanelButton }
                }
            }
            .ownCapsule()
        }
        // the hosting account and Git identity stay in the toolbar's trailing corner
        ToolbarItem(placement: .primaryAction) { ToolbarCapsule { AccountQuickControls() } }.ownCapsule()
    }

    private var pushDisabled: Bool {
        store.busy != nil || store.remotes.isEmpty || store.headBranch == nil || store.headHash == nil
    }

    private var sidebarToggleTitle: String {
        showsNavigationRail ? String(localized: "Expand sidebar") : String(localized: "Collapse sidebar")
    }

    /// Repository and branch in one button that opens the repository menu (docs/design.md › App shell)
    private var repositoryButton: some View {
        ToolbarCapsuleMenu(leading: 11, trailing: 12) { repositoryMenu } label: {
            HStack(spacing: 8) {
                DesignIconImage(icon: .repository, size: 14)
                VStack(alignment: .leading, spacing: 0) {
                    Text(store.windowTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if store.url != nil { branchLine }
                }
                // the button is at most 280pt wide with its padding; longer names truncate
                .modifier(WidthLimit(limit: 208))
                DesignIconImage(icon: .chevronDown, size: 8).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
        .hoverTip(String(localized: "Repository"), String(localized: "Switch branch or repository, open or clone one, or close the tab"))
    }

    /// The repository menu (docs/design.md › App shell): switch the branch, then the repository, then close the tab.
    /// The repository-wide tools are under More.
    @ViewBuilder private var repositoryMenu: some View {
        if store.url != nil {
            Section("Branches") {
                ForEach(menuBranches) { b in
                    Toggle(b.name, isOn: Binding(get: { b.isCurrent }, set: { _ in
                        if !b.isCurrent { Task { await store.checkout(b) } }
                    }))
                }
                // a native menu has no filter field; the repository screen lists every branch
                Button("All branches…") { store.navigate(.repository) }
            }
            Button("New branch…") { store.requestNewBranch() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            if let upstream = store.status.upstream {
                Button("Compare with \(upstream)") { store.showRevisionComparison(left: upstream, right: "HEAD") }
            }
            Divider()
        }
        Section("Repositories") {
            ForEach(menuRepositories, id: \.self) { u in
                Toggle(u.lastPathComponent, isOn: Binding(get: { u == store.url }, set: { _ in
                    if u != store.url { Task { await store.openOrReport(u) } }
                }))
            }
            Button("Open repository…") { store.presentOpenPanel() }
                .keyboardShortcut("o")
            Button("Clone repository…") { store.sheet = .clone }
        }
        Divider()
        Button("Close tab") { NSApp.keyWindow?.performClose(nil) }
            .keyboardShortcut("w")
    }

    /// The current branch, then a few others, pinned ones first
    private var menuBranches: [Branch] {
        let others = store.localBranches.filter { !$0.isCurrent }.sorted { a, b in
            let ap = store.isPinned(a), bp = store.isPinned(b)
            return ap != bp ? ap : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return store.localBranches.filter(\.isCurrent) + others.prefix(4)
    }

    /// This repository, then the recent ones
    private var menuRepositories: [URL] {
        (store.url.map { [$0] } ?? []) + store.recents.filter { $0 != store.url }.prefix(5)
    }

    private var changesButton: some View {
        Button { store.showArea(store.area == .changes ? .history : .changes) } label: {
            TitledToolLabel(title: store.status.isEmpty ? String(localized: "Changes") : String(localized: "Changes \(store.status.count)"), icon: "square.and.pencil")
        }
        .buttonStyle(ToolbarCapsuleButtonStyle(on: store.area == .changes, titled: true))
        .accessibilityAddTraits(store.area == .changes ? .isSelected : [])
        .hoverTip(String(localized: "Uncommitted changes"),
                  store.status.isEmpty ? String(localized: "No modified files. When you edit files, you can stage and commit them here.")
                                       : String(localized: "\(store.status.count) modified files — stage and commit them."))
    }

    private var fetchButton: some View {
        Button { Task { await store.fetch() } } label: { TitledToolLabel(title: "Fetch", icon: "arrow.triangle.2.circlepath") }
            .buttonStyle(ToolbarCapsuleButtonStyle(titled: true))
            .disabled(store.busy != nil || store.remotes.isEmpty)
            .hoverTip("Fetch", String(localized: "Fetches new commits and branches from all remotes. Your branches aren't changed."), shortcut: "⇧⌘F")
    }

    private var pullButton: some View {
        Button { Task { await store.pull() } } label: { TitledToolLabel(title: "Pull", icon: "arrow.down") }
            .buttonStyle(ToolbarCapsuleButtonStyle(titled: true))
            .disabled(store.busy != nil || store.status.upstream == nil)
            .hoverTip("Pull",
                      store.status.upstream == nil ? String(localized: "This branch has no remote tracking branch to pull from (push it first to create one).")
                      : (store.status.behind > 0 ? String(localized: "Brings \(store.status.behind) new commits from the remote into the current branch.") : String(localized: "Syncs the current branch with the remote (no commits to pull right now).")),
                      shortcut: "⇧⌘L")
    }

    private var pushButton: some View {
        Button { Task { await store.push() } } label: { TitledToolLabel(title: "Push", icon: "arrow.up") }
            .buttonStyle(ToolbarCapsuleButtonStyle(titled: true))
            .disabled(pushDisabled)
            .hoverTip("Push",
                      store.status.upstream == nil ? String(localized: "Pushes the current branch to the remote for the first time and sets up tracking.")
                      : (store.status.ahead > 0 ? String(localized: "Pushes \(store.status.ahead) unpushed commits to the remote.") : String(localized: "Pushes the current branch to the remote (no commits to push right now).")),
                      shortcut: "⇧⌘P")
    }

    private var terminalButton: some View {
        Button { store.toggleTerminal() } label: {
            ToolLabel(title: store.showTerminal ? String(localized: "Hide terminal") : String(localized: "Terminal"), icon: "apple.terminal")
        }
        .buttonStyle(ToolbarCapsuleButtonStyle(on: store.showTerminal))
        .accessibilityAddTraits(store.showTerminal ? .isSelected : [])
        .hoverTip(String(localized: "Terminal"),
                  store.showTerminal ? String(localized: "Hides the terminal panel below. Shells keep running.")
                                     : String(localized: "Opens a terminal in this repository's folder below the graph. The graph updates as soon as you run git commands."),
                  shortcut: "⌃`")
    }

    private var rightPanelButton: some View {
        Button { inspectorCollapsed.toggle() } label: {
            ToolLabel(title: inspectorCollapsed ? String(localized: "Show right panel") : String(localized: "Hide right panel"), icon: "sidebar.right")
        }
        .buttonStyle(ToolbarCapsuleButtonStyle(on: !inspectorCollapsed))
        .accessibilityLabel(inspectorCollapsed ? String(localized: "Show right panel") : String(localized: "Hide right panel"))
        .accessibilityAddTraits(inspectorCollapsed ? [] : .isSelected)
        .help((inspectorCollapsed ? String(localized: "Show right panel") : String(localized: "Hide right panel")) + " (⌥⌘B)")
    }

    /// Branch, worktree and stash actions
    private var branchMenu: some View {
        ToolbarCapsuleMenu {
            Button("New branch…") { store.requestNewBranch() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Button("New worktree…") { store.sheet = .addWorktree(branch: nil, start: nil) }
            Button("Compare revisions…") { store.navigate(.compare) }
            Divider()
            Button("Stash changes…") { store.sheet = .stash }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(store.status.isEmpty)
            Button(store.stashes.isEmpty ? String(localized: "Pop latest stash (none saved)") : String(localized: "Pop latest stash")) {
                Task { await store.stashPop() }
            }
            .disabled(store.stashes.isEmpty)
            if let url = store.url {
                Divider()
                Button("Start \(AgentCenter.shared.defaultKind.title) here") { store.startAgent(in: url.path) }
                Button("Start agent session…") { store.sheet = .startAgent(path: url.path) }
            }
        } label: {
            HStack(spacing: 6) {
                ToolLabel(title: String(localized: "Branch"), icon: "arrow.triangle.branch")
                DesignIconImage(icon: .chevronDown, size: 8)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "Branch"))
        }
        .disabled(store.url == nil)
        .help(String(localized: "Branch"))
    }

    /// The same menu on every page (docs/design.md › App shell): Fetch, Pull and Push first so pages without those buttons
    /// still reach them, then Undo naming what it undoes, the pull and push options, and the repository-wide tools
    private var moreMenu: some View {
        ToolbarCapsuleMenu {
            Button("Fetch") { Task { await store.fetch() } }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(store.busy != nil || store.remotes.isEmpty)
            Button("Pull") { Task { await store.pull() } }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(store.busy != nil || store.status.upstream == nil)
            Button("Push") { Task { await store.push() } }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(pushDisabled)
            Divider()
            Button(store.undoStack.last.map { String(localized: "Undo: \($0.title)") } ?? String(localized: "Undo")) { store.confirmUndo() }
                .keyboardShortcut("z", modifiers: [.command, .option])
                .disabled(store.undoStack.isEmpty || store.busy != nil)
            Divider()
            if let t = store.target {
                Button(String(localized: "New \(t.provider.requestShort)…")) { store.sheet = .createPullRequest }
                    .disabled(store.headBranch == nil)
            }
            Menu("Pull options") {
                Button("Pull as configured in git") { Task { await store.pull(.standard) } }
                Button("Fast-forward only") { Task { await store.pull(.fastForward) } }
                Button("Merge") { Task { await store.pull(.merge) } }
                Button("Rebase") { Task { await store.pull(.rebase) } }
            }
            .disabled(store.busy != nil || store.status.upstream == nil)
            Button("Force push (with lease)…") { Task { await store.push(force: true) } }
                .disabled(pushDisabled)
            Divider()
            Button("Structure graph workspace") { Task { await store.openStructureGraph(.files) } }
                .disabled(store.graphJob != nil || Gitch.graphUnavailableReason != nil)
            Button("Repository tools…") { store.sheet = .localWorkflows }
            Button("Work validation…") { store.sheet = .workValidation }
            Divider()
            Button("Ask AI about changes…") { Task { await store.openChangeQuestion() } }
            Button("Repository assistant…") { Task { await store.openRepositoryAssistant() } }
            Button("Connect external AI with MCP…") { store.sheet = .mcpConnection }
        } label: {
            ToolLabel(title: String(localized: "More"), icon: "ellipsis")
        }
        .help(String(localized: "More"))
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
            TitledToolLabel(title: title, icon: icon)
        } else {
            Label(title, systemImage: icon).labelStyle(.iconOnly).font(.system(size: 14))
        }
    }
}

/// Changes, Fetch, Pull and Push always show their title (docs/design.md › App shell)
struct TitledToolLabel: View {
    let title: String
    let icon: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 14))
            Text(title).font(.system(size: 13))
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// One toolbar capsule, drawn to the design's metrics (docs/design.md › App shell): 36pt high and 8pt from the next.
/// macOS 26 groups and spaces its own capsules unevenly, so each item hides the shared background and draws this.
/// The prominent one is the recommended action's filled accent capsule.
struct ToolbarCapsule<Content: View>: View {
    var prominent = false
    @ViewBuilder let content: Content
    var body: some View {
        HStack(spacing: 0) { content }
            .frame(height: 36)
            .modifier(ToolbarCapsuleBackground(prominent: prominent))
            // 4 + 5 makes the 8pt gap: the toolbar overlaps items without a shared background by 1pt, and whole
            // points keep the ring sharp on 1x displays
            .padding(.leading, 4).padding(.trailing, 5)
    }
}

/// The design's capsule: the control background with a 1pt ring outside it and a soft shadow. A standalone
/// .glassEffect draws a greyer capsule than the toolbar's own glass, so this follows the design's values instead.
private struct ToolbarCapsuleBackground: ViewModifier {
    let prominent: Bool
    func body(content: Content) -> some View {
        if prominent {
            content
                .foregroundStyle(.white)
                .background(Capsule().fill(Color.accentColor).shadow(color: .black.opacity(0.12), radius: 1.5, y: 1))
        } else {
            content.background {
                Capsule().fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.08), radius: 3, y: 2)
                    .overlay(Capsule().stroke(Color.primary.opacity(0.07), lineWidth: 1).padding(-0.5))
            }
        }
    }
}

/// A button inside a toolbar capsule: 36pt high, at least 36pt wide; a neutral fill on hover and while it is on.
/// A toggle that is on never takes the accent (docs/design.md › App shell).
struct ToolbarCapsuleButtonStyle: ButtonStyle {
    var on = false
    var titled = false
    func makeBody(configuration: Configuration) -> some View {
        ToolbarCapsuleButton(configuration: configuration, on: on, titled: titled)
    }
}

private struct ToolbarCapsuleButton: View {
    let configuration: ButtonStyleConfiguration
    let on: Bool
    let titled: Bool
    @Environment(\.isEnabled) private var enabled
    @ViewState private var hovered = false
    var body: some View {
        configuration.label
            .padding(.leading, titled ? 10 : 9).padding(.trailing, titled ? 12 : 9)
            .frame(minWidth: 36, minHeight: 36)
            .background(Capsule().fill(Color.primary.opacity(fill)))
            .contentShape(Capsule())
            .opacity(enabled ? 1 : 0.4)
            .onHover { hovered = $0 }
    }
    private var fill: Double {
        if configuration.isPressed && enabled { return 0.12 }
        if on { return hovered && enabled ? 0.1 : 0.06 }
        return hovered && enabled ? 0.06 : 0
    }
}

/// A menu inside a toolbar capsule. The label carries the button's padding, so the whole 36pt shape opens the menu.
struct ToolbarCapsuleMenu<Items: View, MenuLabel: View>: View {
    var leading: CGFloat = 9
    var trailing: CGFloat = 9
    @ViewBuilder let items: Items
    @ViewBuilder let label: MenuLabel
    @Environment(\.isEnabled) private var enabled
    @ViewState private var hovered = false
    var body: some View {
        Menu { items } label: {
            label
                .padding(.leading, leading).padding(.trailing, trailing)
                .frame(minWidth: 36, minHeight: 36)
                .contentShape(Capsule())
        }
        // a borderless menu keeps only one icon and one text of the label; a plain button draws all of it
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .background(Capsule().fill(Color.primary.opacity(hovered && enabled ? 0.06 : 0)))
        .onHover { hovered = $0 }
    }
}

/// Offers the content at most `limit` points and keeps its own width, so a short name hugs it and a long one truncates
private struct WidthLimit: ViewModifier {
    let limit: CGFloat
    func body(content: Content) -> some View { WidthLimitLayout(limit: limit) { content } }
}

private struct WidthLimitLayout: Layout {
    let limit: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = min(proposal.width ?? .infinity, limit)
        return subviews.first?.sizeThatFits(ProposedViewSize(width: width, height: proposal.height)) ?? .zero
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

private extension ToolbarContent {
    /// The item draws its own capsule (ToolbarCapsule): macOS 26 neither adds its shared one nor merges neighbours into it
    @ToolbarContentBuilder func ownCapsule() -> some ToolbarContent {
        if #available(macOS 26.0, *) { sharedBackgroundVisibility(.hidden) } else { self }
    }
}
