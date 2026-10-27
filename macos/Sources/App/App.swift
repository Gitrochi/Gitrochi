import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { urls.forEach { Workspace.shared.receive($0) } }
    }
    /// 마지막 창을 닫으면 종료. 단, 실행 중(스플래시)에는 여분의 빈 창을 닫는 순간 작업 창이 아직 투명하게
    /// 준비 중이라 '마지막 창'으로 잘못 판단될 수 있어 종료하지 않는다.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated { !RestoreState.shared.active }
    }

    /// 첫 창이 그려지기 전에 테마를 정해 둔다(잠깐 다른 테마로 번쩍이지 않게)
    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppTheme.apply() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 설치 디스크(dmg) 안의 앱을 바로 열었으면 응용 프로그램 폴더로 옮길지 묻고, 설치한 앱을 열었으면 그 설치 디스크를 꺼낸다
        MainActor.assumeIsolated { InstallerDisk.check() }
        // 보통은 첫 창이 붙을 때 그 자리에 뜬다. 혹시 늦으면 화면 가운데에라도 띄운다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated { if !Workspace.shared.launchedByEvent { Splash.shared.show() } }
        }
        MainActor.assumeIsolated { UpdateCenter.shared.start() }
        // 시스템이 첫 창을 만들지 않고 넘어가는 때가 있다(백그라운드 실행 등) — 그러면 직접 하나 연다
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            MainActor.assumeIsolated { Workspace.shared.ensureWindow() }
        }
    }
}

@main
struct GitrochiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        LegacyData.migrate()
        // 화면 언어(기본 영어): 번역 묶음을 고르기 전에 정해 둔다
        AppLanguage.applyChoice()
        // 커밋 메시지를 stdin 으로 넘기는 중 git 이 먼저 끝나도 SIGPIPE 로 앱이 죽지 않게
        signal(SIGPIPE, SIG_IGN)
        // 창 복원은 직접 한다(Workspace) — 시스템 복원과 겹쳐 같은 저장소가 두 번 열리지 않게
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        NSWindow.allowsAutomaticWindowTabbing = true
        // 버튼 설명 툴팁이 기본(1초 넘게)보다 빨리 뜨게 — 사용자가 따로 정했으면 그 값을 따른다
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 350])
    }

    var body: some Scene {
        WindowGroup("Gitrochi", id: "repo", for: String.self) { $path in
            RepoWindow(path: $path)
                .frame(minWidth: 1080, minHeight: 640)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1440, height: 900)   // 툴바 버튼이 이름까지 다 보이는 폭
        .restorationBehavior(.disabled)   // 탭 복원은 Workspace 가 한다(시스템 복원과 겹치면 빈 창·중복 창이 생김)
        // Opened folders and gitrochi:// links go to AppDelegate → Workspace.receive; letting the window group take them
        // as well makes SwiftUI replace the launch window, which then never starts and stays invisible
        .handlesExternalEvents(matching: [])
        .commands { AppCommands() }

        Settings {
            SettingsView()
        }

        Window("Get started with Git accounts", id: "git-setup") {
            GitchGuideSheet(repo: nil)
        }
        .windowResizability(.contentSize)
        // opened only from its menu item: not for opened folders or links, and not reopened at the next launch
        .handlesExternalEvents(matching: [])
        .restorationBehavior(.disabled)
    }
}

/// 창(탭) 하나 = 저장소 하나
struct RepoWindow: View {
    @Binding var path: String?
    @ViewState private var store = RepoStore()
    @ViewState private var started = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        RepoContainer()
            .environment(store)
            .background(WindowTabbing(onAttach: { store.window = $0 }, onClose: {
                Workspace.shared.unregister(store)
                store.close()
            }))
            .focusedSceneValue(\.repoStore, store)
            .navigationTitle(store.url == nil ? "Gitrochi" : store.name)
            .task {
                // 탭을 오가며 화면이 다시 나타나도 한 번만 연다
                guard !started else { return }
                started = true
                await setUp()
            }
            .onChange(of: store.url) { _, u in
                path = u?.path
                Workspace.shared.persist()
            }
            .onChange(of: path) { _, p in
                // 복원 탭인데 경로가 조금 늦게 들어온 경우: 그때 연다
                if store.url == nil, let p, started, Workspace.shared.awaitingWindows > 0 {
                    Workspace.shared.windowArrived()
                    Task {
                        await store.openInPlace(URL(fileURLWithPath: p, isDirectory: true))
                        store.booted = true
                        RestoreState.shared.finished(store.name)
                        await Workspace.shared.applyPendingRoutes(to: store)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await store.reload(quiet: true) }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
                if let w = note.object as? NSWindow, w === store.window { Workspace.shared.rememberSelected(store) }
            }
    }

    private func setUp() async {
        store.isActive = true
        // 다른 저장소·워크트리를 열면 새 탭으로(이미 열려 있으면 그 탭이 앞으로 온다)
        store.openRepo = { url in openWindow(id: "repo", value: url.path) }
        Workspace.shared.register(store)

        if let path {
            Workspace.shared.windowArrived()
            await store.openInPlace(URL(fileURLWithPath: path, isDirectory: true))
            store.booted = true
            RestoreState.shared.finished(store.name)
            await Workspace.shared.applyPendingRoutes(to: store)
            return
        }
        // 복원 탭인데 경로가 늦게 오는 경우(onChange 에서 연다) / 실행 직후 닫히는 여분 창
        if Workspace.shared.awaitingWindows > 0 || Workspace.shared.isDuplicate(store.window) { return }

        let initialRoute = Workspace.shared.takeInitialRoute()
        let saved = Workspace.shared.takeRestoreList()
        let restore = initialRoute.map { route in [route.repo] + saved.filter { $0.resolvingSymlinksInPath() != route.repo } } ?? saved
        RestoreState.shared.begin(total: restore.count)
        if let first = restore.first {
            // 나머지 탭은 이 창이 로딩 화면을 보여 주는 동안 뒤에서 하나씩 붙인다(보이는 탭은 바뀌지 않음)
            let rest = Array(restore.dropFirst())
            let open = openWindow
            Task { @MainActor in
                for u in rest {
                    Workspace.shared.expectWindow()
                    open(id: "repo", value: u.path)
                    try? await Task.sleep(for: .milliseconds(120))
                }
            }
            await store.openInPlace(first)
            RestoreState.shared.finished(store.name)
        }
        store.booted = true
        await Workspace.shared.applyPendingRoutes(to: store)
    }
}

struct AppCommands: Commands {
    @FocusedValue(\.repoStore) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // 창이 하나도 없을 때도 새 창을 열 수 있게 메뉴의 openWindow 를 받아 둔다
        let _ = Workspace.shared.setWindowOpener { [openWindow] in openWindow(id: "repo") }
        let _ = Workspace.shared.setRouteOpener { [openWindow] path in openWindow(id: "repo", value: path) }
        CommandGroup(after: .appInfo) {
            Button("Check for updates…") { Task { await UpdateCenter.shared.check(manual: true) } }
        }
        CommandGroup(replacing: .help) {
            Button("Get started with Git accounts…") { openWindow(id: "git-setup") }
        }
        CommandGroup(replacing: .newItem) {
            Button("New tab") { openWindow(id: "repo") }
                .keyboardShortcut("t")
            Button("Open repository…") {
                if let store { store.presentOpenPanel() } else { openWindow(id: "repo") }
            }
            .keyboardShortcut("o")
            Button("Clone repository…") { store?.sheet = .clone }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Create new repository…") { store?.presentInitPanel() }
        }
        CommandMenu("Repository") {
            Button(store?.undoStack.last.map { "Undo: \($0.title)" } ?? "Undo") { store?.confirmUndo() }
                .keyboardShortcut("z", modifiers: [.command, .option])
                .disabled(store?.undoStack.isEmpty ?? true)
            Divider()
            Button("Refresh") { Task { await store?.reload() } }
                .keyboardShortcut("r")
            Button("Search commits") { store?.requestSearchFocus() }
                .keyboardShortcut("f")
            Button("Next search result") { store?.nextMatch() }
                .keyboardShortcut("g")
            Button("Previous search result") { store?.previousMatch() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Button("Toggle sidebar") { store?.sidebarToggleRequest += 1 }
                .keyboardShortcut("s", modifiers: [.command, .control])
            Button("Quick navigation…") { store?.showCommandPalette = true }
                .keyboardShortcut("k")
            Button("Show home") { store?.navigate(.home) }.keyboardShortcut("0")
            Button("Show uncommitted changes") { store?.navigate(.repository); store?.showArea(.changes) }
                .keyboardShortcut("1")
            Button("Show history") { store?.navigate(.repository); store?.showArea(.history) }
                .keyboardShortcut("2")
            Button("Show compare") { store?.navigate(.compare) }.keyboardShortcut("3")
            Button("Show pull requests") { store?.navigate(.pullRequests) }.keyboardShortcut("4")
            Button("Show CI/CD") { store?.navigate(.actions) }.keyboardShortcut("5")
            Button("Show flows") { store?.navigate(.flows) }.keyboardShortcut("6")
            Divider()
            Button("Fetch") { Task { await store?.fetch() } }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Pull") { Task { await store?.pull() } }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Push") { Task { await store?.push() } }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Divider()
            Button("New branch…") { store?.requestNewBranch() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Button("New worktree…") { store?.sheet = .addWorktree(branch: nil, start: nil) }
                .keyboardShortcut("w", modifiers: [.command, .option])
            Button("New pull/merge request…") { store?.sheet = .createPullRequest }
                .disabled(store?.target == nil || store?.headBranch == nil)
            Divider()
            Button("Write commit message with AI") { Task { await store?.generateCommitMessage() } }
                .keyboardShortcut("m", modifiers: [.command, .option])
                .disabled(store?.status.staged.isEmpty ?? true)
            Button("Start agent session…") { store?.sheet = .startAgent(path: store?.url?.path) }
                .keyboardShortcut("k", modifiers: [.command, .option])
                .disabled(store?.url == nil)
            Divider()
            StructureGraphMenu(store: store)
            Divider()
            Button(store?.showTerminal == true ? "Hide terminal" : "Show terminal") { store?.toggleTerminal() }
                .keyboardShortcut("`", modifiers: .control)
                .disabled(store?.url == nil)
            Button("New terminal") { store?.newTerminal() }
                .keyboardShortcut("`", modifiers: [.control, .shift])
                .disabled(store?.url == nil)
            Divider()
            Button("Stash…") { store?.sheet = .stash }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Stash Pop") { Task { await store?.stashPop() } }
        }
    }
}

struct RepoContainer: View {
    @Environment(RepoStore.self) private var store

    var body: some View {
        @Bindable var store = store
        let showLoading = !store.booted || store.loading != nil
        ZStack {
            if store.url != nil || store.booted {
                RepoView()
            }
            if showLoading {
                LoadingView(title: store.loading?.title ?? "Gitrochi",
                            step: store.loading?.step ?? String(localized: "Preparing…"))
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: showLoading)
        .sheet(item: $store.sheet) { kind in
            switch kind {
            case .clone: CloneSheet()
            case .cloneURL(let url): CloneSheet(initialURL: url)
            case .stash: StashSheet()
            case .newBranch(let start, let label, let name, let task): NewBranchSheet(start: start, label: label, suggestedName: name, projectTask: task)
            case .tag(let sha): TagSheet(sha: sha)
            case .createPullRequest: CreatePullRequestSheet()
            case .pushReview(let branch, let force, let remote): PushReviewSheet(branch: branch, force: force, remoteOverride: remote)
            case .changeQuestion: ChangeQuestionSheet()
            case .compareRevisions: CompareRevisionsSheet(store: store)
            case .batchCommits: BatchCommitsSheet(store: store)
            case .lineHistory: LineHistorySheet(store: store)
            case .localWorkflows: LocalWorkflowsSheet()
            case .repositoryAssistant: RepositoryAssistantSheet()
            case .mcpConnection: MCPConnectionSheet()
            case .startAgent(let path): StartAgentSheet(presetPath: path)
            case .addWorktree(let branch, let start): AddWorktreeSheet(presetBranch: branch, start: start)
            case .splitCommits: SplitCommitsSheet()
            case .runPipeline: RunPipelineSheet()
            case .interactiveRebase: InteractiveRebaseSheet()
            case .graphDiff: GraphDiffSheet()
            case .graphCheck: GraphCheckSheet()
            case .issueEditor(let number, let title, let body): IssueEditorSheet(number: number, title: title, body: body)
            }
        }
        .alert("Couldn't complete the operation",
               isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
        .alert("Not a Git repository",
               isPresented: Binding(get: { store.notRepoPrompt != nil }, set: { if !$0 { store.notRepoPrompt = nil } }),
               presenting: store.notRepoPrompt) { folder in
            Button("Create repository here") { Task { await store.initRepository(at: folder) } }
            Button("Cancel", role: .cancel) {}
        } message: { folder in
            Text("Create a new Git repository in \(folder.path)?")
        }
        .confirmationDialog(store.confirm?.title ?? "",
                            isPresented: Binding(get: { store.confirm != nil }, set: { if !$0 { store.confirm = nil } }),
                            titleVisibility: .visible,
                            presenting: store.confirm) { req in
            Button(req.actionTitle, role: req.destructive ? .destructive : nil) {
                Task { await req.action() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { req in
            Text(req.message)
        }
    }
}
