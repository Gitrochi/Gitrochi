import SwiftUI

/// 저장소를 연 뒤의 메인 화면: 사이드바(참조) | 그래프 또는 diff (+ 터미널) | 상세
struct RepoView: View {
    @Environment(RepoStore.self) private var store

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } content: {
            ContentColumn()
                .navigationSplitViewColumnWidth(min: 520, ideal: 780)
        } detail: {
            InspectorView()
                .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 560)
        }
        .navigationTitle(store.name)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .onChange(of: AccountStore.shared.revision) { _, _ in
            Task { await store.loadPullRequests() }
        }
    }

    private var subtitle: String {
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

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
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
                Divider()
                Button("Close tab") { NSApp.keyWindow?.performClose(nil) }
            } label: {
                ToolLabel(title: String(localized: "Repository"), icon: "folder")
            }
            .hoverTip(String(localized: "Repository"), String(localized: "Open or clone another repository, recent repositories, structure graph, close tabs"))
        }

        // 작업 중 표시는 버튼 묶음과 떼어 자기 칸에 둔다(같은 묶음이면 글자가 테두리에 붙음).
        // 구조 그래프는 다른 작업을 막지 않아 busy 와 따로 두고, 둘 다면 busy 를 보인다.
        if let busy = store.busy ?? store.graphProgress {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.callout).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .fixedSize()
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {

            Button { store.confirmUndo() } label: {
                ToolLabel(title: String(localized: "Undo"), icon: "arrow.uturn.backward")
            }
            .disabled(store.undoStack.isEmpty || store.busy != nil)
            .hoverTip(String(localized: "Undo"),
                      store.undoStack.last.map { String(localized: "Undoes the last operation, “\($0.title)”. Undoing a commit keeps its changes.") }
                        ?? String(localized: "Nothing to undo. Operations like commit, merge, rebase, checkout and branch deletion can be undone here."),
                      shortcut: "⌥⌘Z")

            Button { store.select(.wip) } label: {
                ToolLabel(title: store.status.isEmpty ? String(localized: "Changes") : String(localized: "Changes \(store.status.count)"), icon: "square.and.pencil")
            }
            .hoverTip(String(localized: "Uncommitted changes"),
                      store.status.isEmpty ? String(localized: "No modified files. When you edit files, you can stage and commit them here.")
                                           : String(localized: "\(store.status.count) modified files — stage and commit them."),
                      shortcut: "⌘1")

            Button { Task { await store.fetch() } } label: {
                ToolLabel(title: "Fetch", icon: "arrow.triangle.2.circlepath")
            }
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
            .disabled(store.status.upstream == nil)
            .hoverTip("Pull",
                      store.status.upstream == nil ? String(localized: "This branch has no remote tracking branch to pull from (push it first to create one).")
                      : (store.status.behind > 0 ? String(localized: "Brings \(store.status.behind) new commits from the remote into the current branch.") : String(localized: "Syncs the current branch with the remote (no commits to pull right now)."))
                        + String(localized: " Choose merge or rebase from ▾."),
                      shortcut: "⇧⌘L")

            Menu {
                Button("Push") { Task { await store.push() } }
                Button("Force push (with lease)…") {
                    store.confirm = ConfirmRequest(title: String(localized: "Force push?"),
                                                   message: String(localized: "Overwrites the remote branch only if it's still as you last saw it (--force-with-lease)."),
                                                   actionTitle: "Force push") { await store.push(force: true) }
                }
            } label: {
                ToolLabel(title: store.status.ahead > 0 ? "Push ↑\(store.status.ahead)" : "Push", icon: "arrow.up")
            } primaryAction: {
                Task { await store.push() }
            }
            .hoverTip("Push",
                      (store.status.upstream == nil ? String(localized: "Pushes the current branch to the remote for the first time and sets up tracking.")
                       : (store.status.ahead > 0 ? String(localized: "Pushes \(store.status.ahead) unpushed commits to the remote.") : String(localized: "Pushes the current branch to the remote (no commits to push right now).")))
                        + String(localized: " Force push from ▾."),
                      shortcut: "⇧⌘P")

            Menu {
                Button("New branch…") { store.requestNewBranch() }
                Button("New worktree…") { store.sheet = .addWorktree(branch: nil, start: nil) }
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
                ToolLabel(title: store.stashes.isEmpty ? "Stash" : "Stash \(store.stashes.count)", icon: "tray.and.arrow.down")
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
            .hoverTip(String(localized: "Terminal"),
                      store.showTerminal ? String(localized: "Hides the terminal panel below. Shells keep running.")
                                         : String(localized: "Opens a terminal in this repository's folder below the graph. The graph updates as soon as you run git commands."),
                      shortcut: "⌃`")
        }
    }
}

/// 오른쪽 열: 작업 영역 또는 커밋 상세
struct InspectorView: View {
    @Environment(RepoStore.self) private var store

    var body: some View {
        switch store.selection {
        case .wip?:
            WorkingChangesView()
        case .commit(let sha)?:
            CommitDetailView(sha: sha)
        case .worktree(let path)?:
            WorktreeChangesView(path: path)
        case .pullRequest(let n)?:
            PullRequestDetailView(number: n)
        case nil:
            ContentUnavailableView("No commit selected", systemImage: "point.3.connected.trianglepath.dotted",
                                   description: Text("Select a commit in the graph."))
        }
    }
}

/// 툴바 버튼 모양: 아이콘만. 무슨 버튼인지는 마우스를 올리면 설명 풍선(hoverTip)으로 보여 준다.
struct ToolLabel: View {
    let title: String
    let icon: String

    var body: some View {
        Label(title, systemImage: icon)
            .labelStyle(.iconOnly)
    }
}
