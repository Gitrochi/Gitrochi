import SwiftUI
import AppKit
import Observation

/// 열린 저장소 하나의 상태와 모든 git 작업. 화면은 이 객체만 바라본다.
@MainActor @Observable
final class RepoStore: Identifiable {
    let id = UUID()
    /// 지금 보이는 탭인지 — 뒤에 있는 탭은 파일이 바뀌어도 바로 다시 읽지 않고 돌아왔을 때 읽는다
    var isActive = false
    private var pendingReload = false

    // MARK: 저장소
    private(set) var url: URL?
    private(set) var gitDir: URL?
    var name: String { url?.lastPathComponent ?? "Gitrochi" }

    // MARK: 데이터
    private(set) var entries: [GraphEntry] = []
    private(set) var maxLanes = 1
    private(set) var commitIndex: [String: Int] = [:]
    private(set) var refsByCommit: [String: [RefLabel]] = [:]
    private(set) var localBranches: [Branch] = []
    private(set) var remoteBranches: [Branch] = []
    private(set) var remotes: [String] = []
    private(set) var tags: [Tag] = []
    private(set) var stashes: [Stash] = []
    private(set) var status = WorkingStatus()
    private(set) var headHash: String? {
        didSet { if headHash != oldValue { queueCommitImpactValidation() } }
    }
    private(set) var headBranch: String?
    private(set) var repoState: RepoState = .clean
    private(set) var hasMore = false
    var limit = 2000
    var emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    // MARK: 선택·상세
    enum Area { case changes, history }
    var area: Area = .changes
    var destination: WorkspaceDestination = .home
    var workspaceNavigationPreparing = false
    var historySelection: Selection?
    var pullRequestSelection: Int?
    var pullRequestDiff: DiffSource?
    var pullRequestInspect: FileInspect?
    var worktreeDiffs: [String: DiffSource] = [:]
    var worktreeInspects: [String: FileInspect] = [:]
    var sidebarToggleRequest = 0
    var showCommandPalette = false
    var selectedBranchID: String?
    var selectedBranchContext: Branch? {
        guard case .commit(let sha)? = selection else { return nil }
        let matches = localBranches.filter { $0.target == sha } + remoteBranches.filter { $0.target == sha }
        return matches.first { $0.id == selectedBranchID } ?? matches.first(where: \.isCurrent) ?? matches.first
    }
    var changesDiff: DiffSource?
    var historyDiff: DiffSource?
    var changesInspect: FileInspect?
    var historyInspect: FileInspect?
    var selection: Selection?
    var detail: CommitDetail?
    var detailFiles: [FileChange] = []
    var diffSource: DiffSource?
    var diff: DiffDocument?
    var diffLoading = false
    var scrollTarget: String?

    // MARK: 커밋 입력
    var summary = ""
    var message = ""
    var amend = false
    var mergeMessageFilled = false

    // MARK: UI
    var busy: String?
    var operationNotice: String?
    var errorMessage: String?
    var sheet: SheetKind?
    var pushReview: PushReviewPlan?
    var pushReviewLoading = false
    var pushReviewGeneration = 0
    var pushReviewError: String?
    var pushReviewCompletion: ((Bool) -> Void)?
    var changeQuestionSession: ChangeQuestionSession?
    var historyTools = HistoryToolsState()
    var collaboration = CollaborationState()
    /// The repository's issues, shared by the sidebar section and the Issues page
    let issueList = WorkspaceIssueModel()
    var localWorkflows = LocalWorkflowState()
    var repositoryAssistant = RepositoryAssistantState()
    var hostingHub = HostingHubState()
    var newPullRequestDraft: NewPullRequestDraft?
    var pullRequestWorkflowID: UUID?
    private let confirmationGuard = RepositoryConfirmationGuard()
    private var pendingConfirmation: ConfirmRequest?
    var confirm: ConfirmRequest? {
        get { pendingConfirmation }
        set {
            guard let request = newValue else { pendingConfirmation = nil; return }
            let action = confirmationGuard.wrap(path: url?.path, currentPath: { [weak self] in self?.url?.path }, action: request.action)
            pendingConfirmation = ConfirmRequest(title: request.title, message: request.message, actionTitle: request.actionTitle, destructive: request.destructive, action: action)
        }
    }
    var notRepoPrompt: URL?
    private(set) var recents: [URL] = Recents.load()

    // MARK: 그래프 끌어다 놓기
    var dropRequest: DropRequest?

    // MARK: 터미널 패널
    var terminals: [TerminalSession] = []
    var activeTerminalID: UUID?
    /// How the terminal panel is split into panes of tabs
    var terminalLayout: TerminalNode?
    var showTerminal = false

    // MARK: 로딩 화면
    weak var window: NSWindow?
    var loading: LoadingInfo?
    /// 창이 처음 무엇을 보여 줄지 정했는지(그 전에는 로딩 화면)
    var booted = false

    // MARK: 줄 수·나
    var detailStats: [String: LineStat] = [:]
    var stagedStats: [String: LineStat] = [:]
    var unstagedStats: [String: LineStat] = [:]
    var me: Identity?

    // MARK: gitch(설정 > CLI 에서 설치) — 이 저장소의 계정과 커밋·push 전 점검. gitch 계정이 없으면 nil
    var gitchStatus: Gitch.Status?
    var gitchPreflight: Gitch.Preflight?
    /// 커밋 칸에서 고를 수 있는 gitch 계정
    var gitchAccounts: [Gitch.Account] = []
    /// gitch 가 직접 push 를 막는 브랜치(gitch protect)
    var gitchProtected: Set<String> = []
    var gitchChecking = false
    /// 브랜치·참조가 바뀔 때만 다시 점검하려고(파일 저장마다 돌지 않게)
    var gitchKey = ""
    /// gitch graph 로 만들고 있는 페이지(구조 그래프 · 바뀐 의존 · 규칙 위반). 읽기만 하므로 busy 와 달리 다른 작업을 막지 않는다
    var graphJob: GraphJob?
    /// 의존 규칙 검사 창에 보일 결과(gitch graph check)
    var graphCheck: GraphCheckState?

    // MARK: 커밋에 들어갈 스테이지 영향 분석 — 요청할 때만 분석하고 감시 중에는 식별값만 확인한다
    var commitImpactState: CommitImpactState = .idle
    var commitImpactValidationError: String?
    var commitImpactGeneration = 0
    var commitImpactRevision = 0
    var commitImpactValidationTask: Task<Void, Never>?

    // MARK: 검색
    var searchText = ""
    var searchScope: SearchScope = .commits
    var searchMatches: [String] = []
    var searchMatchSet: Set<String> = []
    var searchUnloaded = 0
    var searching = false
    var searchFocusRequest = 0
    var searchTask: Task<Void, Never>?

    // MARK: 워크트리·호스팅·Claude
    var worktrees: [Worktree] = []
    var worktreeStats: [String: WorktreeStats] = [:]
    /// Other worktrees' status (they aren't watched, so it is polled while this tab is in front)
    var worktreeStatus: [String: WorkingStatus] = [:]
    @ObservationIgnored private var worktreePoll: Task<Void, Never>?
    private(set) var remoteURLs: [String: String] = [:]
    var target: RepoTarget?
    var pullRequests: [PullRequest] = []
    var prState: LoadState = .idle
    var aiWorking: String?
    var aiNotice: String?
    var explanations: [String: String] = [:]
    var explaining: Set<String> = []
    var splitPlan: [SplitGroup]?
    /// 되돌릴 수 있는 작업(마지막이 맨 뒤)
    var undoStack: [UndoPoint] = []
    /// 그래프에서 숨긴 브랜치(refs/heads/x · refs/remotes/o/x), 사이드바 맨 위에 고정한 로컬 브랜치, 현재 브랜치만 보기
    var hiddenRefs: Set<String> = []
    var pinnedBranches: Set<String> = []
    var graphCurrentOnly = false
    /// 충돌 해결 중인 파일과 블록마다 고른 것
    var conflictDoc: ConflictDocument?
    var conflictChoices: [Int: ConflictDocument.Choice] = [:]
    var conflictPath: String?
    /// 커밋 정리(인터랙티브 리베이스) 창에 넘길 계획
    var rebasePlan: RebasePlan?
    /// 고른 PR·MR 의 대화·바뀐 파일·승인
    var review: PullRequestReview?
    var reviewLoading = false
    var reviewError: String?
    var reviewBusy = false
    var reviewDrafts: [ReviewDraftComment] = ReviewDraftStorage.load()
    var reviewLoadID = UUID()
    var reviewActionID: UUID?
    /// 가운데에 띄운 파일 히스토리·blame
    var fileInspect: FileInspect?
    var fileInspectLine: Int?
    var fileHistory: [FileHistoryEntry] = []
    var fileHistorySelected: String?
    var fileHistoryDiff: DiffDocument?
    var blameLines: [BlameLine] = []
    var fileInspectLoading = false
    @ObservationIgnored var fileInspectGeneration = 0
    @ObservationIgnored var fileHistoryGeneration = 0
    var fileInspectError: String?
    /// diff 화면에서 고른 줄(DiffLine.id)과 Shift 범위의 시작
    var diffSelection: Set<Int> = []
    var diffSelectionAnchor: Int?
    /// 이미지 파일의 바뀌기 전·후
    var diffImages: DiffImages?
    /// 보기 설정(나란히·공백 무시)이 바뀐 것을 화면에 알리는 값
    var diffSettingsVersion = 0

    // CI/CD (GitLab 파이프라인 · GitHub Actions)
    var ciPipelines: [CIPipeline] = [] {
        didSet {
            // 커밋마다 가장 최근 파이프라인(그래프·PR 목록의 CI 표시)
            var map: [String: CIPipeline] = [:]
            for p in ciPipelines where map[p.sha] == nil { map[p.sha] = p }
            if map.mapValues({ "\($0.id) \($0.status)" }) != ciBySha.mapValues({ "\($0.id) \($0.status)" }) { ciBySha = map }
        }
    }
    /// 커밋 SHA → 그 커밋의 가장 최근 파이프라인
    var ciBySha: [String: CIPipeline] = [:]
    var ciBadgeTask: Task<Void, Never>?
    var ciState: LoadState = .idle
    var ciJobs: [Int: [CIJob]] = [:]
    var ciDeployments: [Int: [CIDeployment]] = [:]
    /// 진행 중인 버튼 동작(같은 버튼을 두 번 누르지 않게)
    var ciBusy: Set<String> = []
    /// A pipeline the Actions page should expand and scroll to (set from a commit's CI icon)
    var ciFocus: Int?
    var ciCurrentBranchOnly = UserDefaults.standard.bool(forKey: "ciCurrentBranchOnly") {
        didSet { UserDefaults.standard.set(ciCurrentBranchOnly, forKey: "ciCurrentBranchOnly") }
    }

    private var watcher: FileWatcher?
    /// 여러 워크트리가 함께 쓰는 .git(연결된 워크트리면 gitDir 과 다르다)
    private var commonDir: URL?
    private var reloadGeneration = 0
    /// 상태만 다시 읽는 가벼운 새로 고침의 세대(전체 새로 고침이 시작되면 함께 올라간다)
    private var statusGeneration = 0
    private var watchTask: Task<Void, Never>?
    /// 파일 감시가 모아 둔 새로 고침 종류(전체가 상태만보다 우선)
    private var pendingKind: ReloadKind?
    /// 마지막으로 인덱스를 새로 고친 때와 그 뒤 .git/index 의 수정 시각(우리가 쓴 변경엔 다시 읽지 않게)
    private var lastIndexRefresh: Date?
    private var ownIndexStamp: Date?
    /// 마지막으로 그래프를 만든 git log 출력·'작업 중인 변경' 행 여부·HEAD — 같으면 다시 해석·배치하지 않는다
    private var lastLog: (data: Data, wip: Bool, head: String?, pending: String)?

    enum ReloadKind: Comparable { case status, full }
    var detailTask: Task<Void, Never>?
    var diffTask: Task<Void, Never>?

    var currentBranch: Branch? { localBranches.first { $0.isCurrent } }

    // MARK: - 열기·닫기

    /// 폴더가 속한 저장소의 최상위 경로(저장소가 아니면 nil)
    static func toplevel(of folder: URL) async -> URL? {
        guard let r = try? await Git.raw(["rev-parse", "--show-toplevel"], in: folder), r.status == 0 else { return nil }
        let p = r.output.trimmed
        return p.isEmpty ? nil : URL(fileURLWithPath: p, isDirectory: true)
    }

    /// 연결된 워크트리(메인이 아닌)로 연 탭인지
    var isLinkedWorktree: Bool { gitDir?.path.contains("/worktrees/") ?? false }

    /// 탭으로 돌아왔을 때: 뒤에 있는 동안 바뀐 게 있으면 다시 읽는다
    func activated() async {
        guard url != nil else { return }
        if pendingReload {
            pendingReload = false
            let k = pendingKind ?? .full
            pendingKind = nil
            if k == .full { await reload(quiet: true) } else { await reloadStatus() }
        }
    }

    @discardableResult
    /// quick: switching worktrees, so skip the minimum loading animation
    func open(_ folder: URL, quick: Bool = false) async -> OpenResult {
        let started = Date()
        loading = LoadingInfo(title: String(localized: "Opening \(folder.lastPathComponent)"), step: String(localized: "Checking repository…"))
        defer { if url == nil { loading = nil } }
        let r: GitResult
        do {
            r = try await Git.raw(["rev-parse", "--show-toplevel", "--absolute-git-dir", "--git-common-dir"], in: folder)
        } catch {
            return .failed(describe(error))
        }
        guard r.status == 0 else {
            if r.stderr.contains("not a git repository") { return .notRepository(folder) }
            return .failed(r.stderr.trimmed)
        }
        let lines = r.output.split(separator: "\n").map(String.init)
        guard lines.count >= 2 else { return .failed(String(localized: "Couldn't verify the repository path.")) }

        resetState()
        let top = URL(fileURLWithPath: lines[0], isDirectory: true)
        loading = LoadingInfo(title: String(localized: "Opening \(top.lastPathComponent)"), step: String(localized: "Reading commits and branches…"))
        url = top
        let git = URL(fileURLWithPath: lines[1], isDirectory: true)
        gitDir = git
        // --git-common-dir 은 상대 경로(.git)로 나올 수 있다. 경로를 정리(standardize)하면 /private 가 빠져
        // FSEvents 가 알려 주는 실제 경로와 달라지므로 git 이 준 그대로 쓴다.
        let common = lines.count > 2
            ? (lines[2].hasPrefix("/") ? URL(fileURLWithPath: lines[2], isDirectory: true) : top.appendingPathComponent(lines[2], isDirectory: true))
            : git
        commonDir = common
        recents = Recents.add(top)
        loadGraphFilters()
        Task { await loadRepoInfo(in: top) }
        // 작업 트리 + 그 밖에 있는 git 폴더(연결된 워크트리의 .git/worktrees/<이름>, 공용 .git)
        var watched = [top.path]
        for d in [git.path, common.path] where !d.hasPrefix(top.path + "/") && !watched.contains(d) { watched.append(d) }
        watcher = FileWatcher(paths: watched) { [weak self] paths in
            Task { @MainActor in self?.fileSystemChanged(paths) }
        }
        await reload()
        selectDefault()
        if worktrees.count > 1 { Task { await refreshWorktreeStats() } }
        if worktreePoll == nil {
            worktreePoll = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    guard let self else { return }
                    if self.isActive, NSApp.isActive, self.worktrees.count > 1 { await self.refreshWorktreeStats() }
                }
            }
        }
        restoreWorkspaceDestination()
        // 로딩 화면이 번쩍 지나가지 않게 애니메이션 한 호흡(약 0.9초)은 보여 준다
        let shown = Date().timeIntervalSince(started)
        if !quick && shown < 0.9 { try? await Task.sleep(for: .milliseconds(Int((0.9 - shown) * 1000))) }
        loading = nil
        return .opened
    }

    /// 다른 저장소·워크트리를 새 탭으로 여는 동작(창이 넣어 준다)
    var openRepo: ((URL) -> Void)?

    /// 다른 저장소·워크트리 열기: 빈 창이면 이 자리에, 저장소가 열린 창이면 새 탭으로
    /// (이미 열린 저장소면 그 탭이 앞으로 온다)
    func openOrReport(_ folder: URL) async {
        guard url != nil, let openRepo else { await openInPlace(folder); return }
        guard let top = await Self.toplevel(of: folder) else { notRepoPrompt = folder; return }
        if top.standardizedFileURL.path == url?.standardizedFileURL.path { return }
        openRepo(top)
    }

    func openInPlace(_ folder: URL, quick: Bool = false) async {
        switch await open(folder, quick: quick) {
        case .opened: break
        case .notRepository(let u): notRepoPrompt = u
        case .failed(let m): errorMessage = m
        }
    }

    /// 그래프를 읽는 동안 나란히: 내 이름·이메일, 저장소의 해시 방식(빈 트리 SHA 가 SHA-1 / SHA-256 에 따라 다르다)
    func loadRepoInfo(in top: URL) async {
        async let configR = Git.raw(["config", "--get-regexp", "^user\\.(name|email)$"], in: top)
        async let formatR = Git.raw(["rev-parse", "--show-object-format"], in: top)
        let (config, format) = (try? await configR, try? await formatR)
        guard url == top else { return }
        if format?.status == 0, format?.output.trimmed == "sha256" {
            emptyTree = "6ef19b41225c5369f1c104d45d8d85efa9b057b53b14b4b9b939dd74decc5321"
        }
        var name = "", email = ""
        for line in (config?.output ?? "").split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            if parts[0] == "user.name" { name = parts[1] } else if parts[0] == "user.email" { email = parts[1] }
        }
        if !name.isEmpty { me = Identity(name: name, email: email) }
    }

    /// Without a repository the window shows the global Git identity (Windows: entities/repo/model/layers/core.ts)
    func loadGlobalIdentity() async {
        guard url == nil else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let result = try? await Git.raw(["config", "--global", "--get-regexp", "^user\\.(name|email)$"], in: home), url == nil else { return }
        var name = "", email = ""
        for line in result.output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            if parts[0] == "user.name" { name = parts[1] } else if parts[0] == "user.email" { email = parts[1] }
        }
        me = name.isEmpty ? nil : Identity(name: name, email: email)
    }

    func close() {
        worktreePoll?.cancel()
        worktreePoll = nil
        closeAllTerminals()
        watcher = nil
        commonDir = nil
        resetState()
        url = nil
        gitDir = nil
    }

    func forgetRecent(_ u: URL) {
        recents = Recents.remove(u)
    }

    func presentOpenPanel() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.prompt = String(localized: "Open")
        p.message = String(localized: "Choose a Git repository folder")
        if p.runModal() == .OK, let u = p.url {
            Task { await openOrReport(u) }
        }
    }

    func presentInitPanel() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = String(localized: "Create here")
        p.message = String(localized: "Choose a folder for the new Git repository")
        if p.runModal() == .OK, let u = p.url {
            Task { await initRepository(at: u) }
        }
    }

    func initRepository(at folder: URL) async {
        do {
            try await Git.run(["init"], in: folder)
            await openOrReport(folder)
        } catch {
            errorMessage = describe(error)
        }
    }

    func clone(remote: String, parent: URL, folder: String) async {
        busy = String(localized: "Cloning…")
        if url == nil { loading = LoadingInfo(title: String(localized: "Cloning \(folder)"), step: String(localized: "Receiving from the remote repository…")) }
        do {
            try await Git.run(["clone", "--", remote, folder], in: parent, timeout: 3600,
                              env: AccountStore.shared.gitEnvironment(target: nil, repoPath: nil))
            busy = nil
            await openOrReport(parent.appendingPathComponent(folder, isDirectory: true))
        } catch {
            busy = nil
            if url == nil { loading = nil }
            errorMessage = describe(error)
        }
    }

    private func resetState() {
        confirmationGuard.invalidate()
        cancelPushReview()
        cancelChangeQuestion()
        historyTools.reset()
        collaboration.reset()
        issueList.reset(); issueList.contextKey = ""
        localWorkflows.reset()
        repositoryAssistant.reset()
        hostingHub = .init()
        destination = .home
        sheet = nil; confirm = nil
        busy = nil; errorMessage = nil
        newPullRequestDraft = nil
        pullRequestWorkflowID = nil
        reviewLoadID = UUID()
        reviewActionID = nil
        review = nil; reviewLoading = false; reviewBusy = false; reviewError = nil
        pullRequestSelection = nil; pullRequestDiff = nil; pullRequestInspect = nil
        worktreeDiffs = [:]; worktreeInspects = [:]
        showCommandPalette = false; selectedBranchID = nil
        resetCommitImpact()
        closeFileInspect()
        entries = []; maxLanes = 1; commitIndex = [:]; refsByCommit = [:]
        localBranches = []; remoteBranches = []; remotes = []; tags = []; stashes = []
        status = WorkingStatus(); headHash = nil; headBranch = nil; repoState = .clean
        hasMore = false; limit = 2000; lastLog = nil
        emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
        selection = nil; detail = nil; detailFiles = []; diffSource = nil; diff = nil
        area = .changes; historySelection = nil; changesDiff = nil; historyDiff = nil
        changesInspect = nil; historyInspect = nil; operationNotice = nil
        summary = ""; message = ""; amend = false; mergeMessageFilled = false
        worktrees = []; worktreeStats = [:]; worktreeStatus = [:]; remoteURLs = [:]; target = nil; pullRequests = []; prState = .idle
        aiWorking = nil; aiNotice = nil; explanations = [:]; explaining = []; undoStack = []
        ciBadgeTask?.cancel(); ciBadgeTask = nil
        detailTask?.cancel(); diffTask?.cancel(); watchTask?.cancel()
    }

    // MARK: - 새로 고침

    private static let statusArgs = ["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"]

    /// GITROCHI_TRACE=1 이면 새로 고침 종류와 걸린 시간을 표준 오류로(성능 확인용)
    static let tracing = ProcessInfo.processInfo.environment["GITROCHI_TRACE"] == "1"
    static func trace(_ s: @autoclosure () -> String) {
        if tracing { FileHandle.standardError.write(Data("[gitrochi] \(s())\n".utf8)) }
    }

    /// 바뀐 값만 넣는다(같은 값을 다시 넣어도 화면이 다시 그려져서, 큰 저장소에서 2,000줄 그래프가 매번 다시 계산된다)
    private func update<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<RepoStore, T>, _ value: T) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    /// git status 를 실행하고 걸린 시간도 돌려준다(오래 걸리면 인덱스를 새로 고친다)
    private static func timedStatus(_ url: URL) async throws -> (GitResult, Duration) {
        let clock = ContinuousClock()
        let start = clock.now
        let r = try await Git.run(statusArgs, in: url)
        return (r, clock.now - start)
    }

    static func samePath(_ a: String, _ b: String) -> Bool {
        a == b || URL(fileURLWithPath: a).resolvingSymlinksInPath().path == URL(fileURLWithPath: b).resolvingSymlinksInPath().path
    }

    /// Other worktrees with uncommitted changes: each gets a row above its HEAD in the graph
    func pendingWorktrees(_ list: [Worktree]) -> [Worktree] {
        guard let url else { return [] }
        return list.filter { w in
            !w.prunable && w.head != nil && !Self.samePath(w.path, url.path) && !(worktreeStatus[w.path]?.isEmpty ?? true)
        }
    }

    static func pendingKey(_ list: [Worktree]) -> String {
        list.map { $0.path + "@" + ($0.head ?? "") }.joined(separator: "|")
    }

    /// The graph key the last full reload drew its worktree rows with
    var drawnPendingKey: String? { lastLog?.pending }

    func reload(quiet: Bool = false) async {
        guard let url else { return }
        reloadGeneration += 1
        statusGeneration += 1
        let gen = reloadGeneration
        let started = ContinuousClock.now
        defer { Self.trace("full reload \(ContinuousClock.now - started)") }
        do {
            async let statusR = Self.timedStatus(url)
            async let logR = Git.run(["log"] + logScope + ["--date-order", "-n", String(limit + 1),
                                      "--format=" + Parsers.logFormat], in: url, ok: [0, 128])
            async let refsR = Git.run(["for-each-ref", "--format=" + Parsers.refFormat,
                                       "refs/heads", "refs/remotes", "refs/tags"], in: url)
            async let stashR = Git.run(["stash", "list", "--format=" + Parsers.stashFormat], in: url, ok: [0, 1, 128])
            async let headR = Git.run(["rev-parse", "--verify", "-q", "HEAD"], in: url, ok: [0, 1, 128])
            async let remoteR = Git.run(["remote", "-v"], in: url)
            async let worktreeR = Git.run(["worktree", "list", "--porcelain", "-z"], in: url, ok: [0, 128])
            async let unstagedNumR = Git.run(["diff", "--no-ext-diff", "--numstat", "-z"], in: url, ok: [0, 128])
            async let stagedNumR = Git.run(["diff", "--cached", "--no-ext-diff", "-M", "--numstat", "-z"], in: url, ok: [0, 128])
            let ((st, statusTime), lg, rf, sh, hd, rm, wt) = try await (statusR, logR, refsR, stashR, headR, remoteR, worktreeR)
            let (un, sn) = try await (unstagedNumR, stagedNumR)
            guard gen == reloadGeneration, self.url == url else { return }

            let newStatus = Parsers.status(st.data)
            let head = hd.status == 0 ? hd.output.trimmed : nil
            // 커밋이 그대로면(파일만 고친 경우 등) 해석·배치를 건너뛰고 지금 그래프를 그대로 쓴다
            let wip = !newStatus.isEmpty
            let parsedWorktrees = Parsers.worktrees(wt.output)
            let pending = pendingWorktrees(parsedWorktrees)
            let pendingKey = Self.pendingKey(pending)
            var graph: (commits: [Commit], layout: (rows: [GraphRow], maxLanes: Int), more: Bool)?
            if lastLog?.data != lg.data || lastLog?.wip != wip || lastLog?.head != head || lastLog?.pending != pendingKey || entries.isEmpty {
                var commits = await Task.detached(priority: .userInitiated) { Parsers.log(lg.data) }.value
                guard gen == reloadGeneration, self.url == url else { return }
                let more = commits.count > limit
                if more { commits.removeLast(commits.count - limit) }
                if wip { commits.insert(.wip(parent: head), at: 0) }
                let known = Set(commits.map(\.id))
                commits.insert(contentsOf: pending.compactMap { w in w.head.flatMap { known.contains($0) ? Commit.worktreeWIP(path: w.path, parent: $0) : nil } },
                               at: wip ? 1 : 0)
                if loading != nil { loading?.step = String(localized: "Drawing the graph with \(commits.count) commits…") }
                let list = commits
                let layout = await Task.detached(priority: .userInitiated) { GraphLayout.compute(list) }.value
                graph = (list, layout, more)
            }
            guard gen == reloadGeneration, self.url == url else { return }
            if graph != nil { lastLog = (lg.data, wip, head, pendingKey) }
            Self.trace("  graph \(graph == nil ? "reused" : "rebuilt (\(graph!.commits.count) commits)"), status \(statusTime)")

            let refs = Parsers.refs(rf.output)
            update(\.status, newStatus)
            update(\.headHash, head)
            update(\.headBranch, newStatus.branch)
            update(\.localBranches, refs.locals)
            update(\.remoteBranches, refs.remotes)
            update(\.tags, refs.tags)
            update(\.stashes, Parsers.stashes(sh.output))
            let parsedRemotes = Parsers.remotes(rm.output)
            update(\.remotes, parsedRemotes.names)
            update(\.remoteURLs, parsedRemotes.urls)
            update(\.worktrees, parsedWorktrees)
            // this worktree's card counts come from the status just read; other worktrees are polled
            if let here = parsedWorktrees.first(where: { Self.samePath($0.path, url.path) }) {
                let stats = WorktreeStats(newStatus)
                if worktreeStats[here.path] != stats { worktreeStats[here.path] = stats }
            }
            update(\.unstagedStats, Parsers.numstat(un.data))
            update(\.stagedStats, Parsers.numstat(sn.data))
            let newTarget = Hosting.target(remotes: remotes, urls: remoteURLs,
                                           gitlabHosts: AccountStore.shared.accounts(for: .gitlab).map(\.host), sshAliases: AccountStore.shared.sshHostAliases)
            if let t = newTarget, t.provider == .github { AvatarStore.shared.noteGitHubRepo(t.path) }
            if newTarget != target {
                target = newTarget
                resetCI()
                Task {
                    await loadPullRequests()
                    await refreshCIBadges()
                }
            }
            if let graph {
                update(\.hasMore, graph.more)
                update(\.maxLanes, graph.layout.maxLanes)
                entries = zip(graph.commits, graph.layout.rows).map { GraphEntry(commit: $0, row: $1) }
                commitIndex = Dictionary(entries.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
            }
            update(\.refsByCommit, buildRefMap(head: head))
            update(\.repoState, detectState())
            let key = (newStatus.branch ?? "") + "\n" + rf.output
            if key != gitchKey {
                gitchKey = key
                Task { await refreshGitch() }
            }
            prefillMergeMessage()
            fixSelection()
            if !searchMatchSet.isEmpty {
                update(\.searchMatches, entries.compactMap { searchMatchSet.contains($0.id) ? $0.id : nil })
            }
            refreshIndexIfSlow(statusTime)
        } catch {
            guard gen == reloadGeneration, !quiet else { return }
            errorMessage = describe(error)
        }
    }

    func loadMore() async {
        limit += 3000
        await reload()
    }

    /// 바뀐 파일로 필요한 새로 고침을 고른다:
    /// 작업 트리 파일·.git/index 만 바뀌었으면 상태만, HEAD·브랜치·태그·packed-refs·FETCH_HEAD 등이 바뀌었으면 전체.
    private func fileSystemChanged(_ paths: [String]) {
        guard let root = url?.path else { return }
        let gitDirs = Set([gitDir?.path ?? root + "/.git", commonDir?.path].compactMap { $0 })
        var kind: ReloadKind?
        var stagedSnapshotChanged = false
        for p in paths {
            if let g = gitDirs.first(where: { p == $0 || p.hasPrefix($0 + "/") }) {
                let rel = p == g ? "" : String(p.dropFirst(g.count + 1))
                if rel.isEmpty || rel.hasPrefix("objects") || rel.hasPrefix("logs/") || rel.hasSuffix(".lock") || rel.hasPrefix("lfs/") {
                    continue
                }
                if rel == "index" {
                    // 우리가 방금 새로 고쳐 쓴 인덱스면 다시 읽을 것 없음
                    if let own = ownIndexStamp, own == indexModified() { continue }
                    stagedSnapshotChanged = true
                    kind = max(kind ?? .status, .status)
                } else {
                    if rel == "HEAD" || rel.hasPrefix("refs/") || rel == "packed-refs" { stagedSnapshotChanged = true }
                    kind = .full
                }
            } else {
                kind = max(kind ?? .status, .status)
            }
            if kind == .full { break }
        }
        if stagedSnapshotChanged { queueCommitImpactValidation() }
        guard let kind else { return }
        pendingKind = max(pendingKind ?? kind, kind)
        guard isActive else { pendingReload = true; return }
        watchTask?.cancel()
        watchTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, busy == nil else { return }
            let k = pendingKind ?? .full
            pendingKind = nil
            if k == .full { await reload(quiet: true) } else { await reloadStatus() }
        }
    }

    /// 가벼운 새로 고침: 작업 트리·스테이지 상태와 줄 수만(커밋 목록·브랜치는 그대로).
    /// 변경이 생기거나 다 없어져 '작업 중인 변경' 행이 생기고 없어지면 전체를 다시 읽는다.
    func reloadStatus() async {
        guard let url else { return }
        statusGeneration += 1
        let gen = statusGeneration
        let started = ContinuousClock.now
        defer { Self.trace("status reload \(ContinuousClock.now - started)") }
        do {
            async let statusR = Self.timedStatus(url)
            async let unstagedNumR = Git.run(["diff", "--no-ext-diff", "--numstat", "-z"], in: url, ok: [0, 128])
            async let stagedNumR = Git.run(["diff", "--cached", "--no-ext-diff", "-M", "--numstat", "-z"], in: url, ok: [0, 128])
            let ((st, statusTime), un, sn) = try await (statusR, unstagedNumR, stagedNumR)
            guard gen == statusGeneration, self.url == url else { return }
            let newStatus = Parsers.status(st.data)
            if newStatus.isEmpty != status.isEmpty || newStatus.branch != status.branch {
                await reload(quiet: true)
                return
            }
            update(\.status, newStatus)
            update(\.unstagedStats, Parsers.numstat(un.data))
            update(\.stagedStats, Parsers.numstat(sn.data))
            update(\.repoState, detectState())
            prefillMergeMessage()
            fixSelection()
            refreshIndexIfSlow(statusTime)
        } catch {
            await reload(quiet: true)
        }
    }

    private func indexModified() -> Date? {
        guard let g = gitDir else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: g.appendingPathComponent("index").path))?[.modificationDate] as? Date
    }

    /// git status 가 느리면(인덱스의 파일 정보가 낡아 매번 파일 내용을 다시 해시하는 경우) 인덱스를 한 번 새로 고친다.
    /// 앱의 git 명령은 GIT_OPTIONAL_LOCKS=0 이라 status 가 인덱스를 고쳐 쓰지 않아서, 그대로 두면 계속 느리다.
    /// 터미널의 git 과 index.lock 이 부딪히지 않게 1분에 한 번까지만.
    private func refreshIndexIfSlow(_ statusTime: Duration) {
        guard statusTime > .milliseconds(120), let url else { return }
        if let last = lastIndexRefresh, Date().timeIntervalSince(last) < 60 { return }
        lastIndexRefresh = Date()
        Self.trace("status took \(statusTime) — refreshing index")
        Task {
            _ = try? await Git.raw(["update-index", "-q", "--refresh"], in: url)
            guard self.url == url else { return }
            ownIndexStamp = indexModified()
        }
    }

    private func buildRefMap(head: String?) -> [String: [RefLabel]] {
        var map: [String: [RefLabel]] = [:]
        if headBranch == nil, let head {
            map[head, default: []].append(RefLabel(name: "HEAD", kind: .head, isCurrent: true))
        }
        for b in localBranches where b.isCurrent || !hiddenRefs.contains("refs/heads/" + b.name) {
            map[b.target, default: []].append(RefLabel(name: b.name, kind: .local, isCurrent: b.isCurrent))
        }
        for b in remoteBranches where !hiddenRefs.contains("refs/remotes/" + b.name) {
            map[b.target, default: []].append(RefLabel(name: b.name, kind: .remote, isCurrent: false))
        }
        for t in tags {
            map[t.target, default: []].append(RefLabel(name: t.name, kind: .tag, isCurrent: false))
        }
        for k in map.keys {
            map[k]?.sort { ($0.isCurrent ? 0 : 1, $0.kind.rawValue) < ($1.isCurrent ? 0 : 1, $1.kind.rawValue) }
        }
        return map
    }

    private func detectState() -> RepoState {
        guard let g = gitDir else { return .clean }
        let fm = FileManager.default
        func has(_ p: String) -> Bool { fm.fileExists(atPath: g.appendingPathComponent(p).path) }
        if has("rebase-merge") || has("rebase-apply") { return .rebasing }
        if has("MERGE_HEAD") { return .merging }
        if has("CHERRY_PICK_HEAD") { return .cherryPicking }
        if has("REVERT_HEAD") { return .reverting }
        return .clean
    }

    /// 머지·cherry-pick 충돌 중이면 git 이 준비한 MERGE_MSG 로 커밋 메시지를 한 번 채운다.
    private func prefillMergeMessage() {
        guard repoState != .clean else { mergeMessageFilled = false; return }
        guard !mergeMessageFilled, summary.isEmpty, message.isEmpty, let g = gitDir,
              let text = try? String(contentsOf: g.appendingPathComponent("MERGE_MSG"), encoding: .utf8) else { return }
        mergeMessageFilled = true
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("#") }.map(String.init)
        summary = lines.first?.trimmed ?? ""
        message = lines.dropFirst().joined(separator: "\n").trimmed
    }

    private func fixSelection() {
        let wasPreparing = workspaceNavigationPreparing
        workspaceNavigationPreparing = true
        defer { workspaceNavigationPreparing = wasPreparing }
        switch selection {
        case .wip?:
            break
        case .commit(let sha)?:
            if commitIndex[sha] == nil && !stashes.contains(where: { $0.hash == sha }) { showArea(.history) }
        case .worktree(let path)?:
            if !worktrees.contains(where: { $0.path == path }) { selectDefault() }
        case .pullRequest?:
            break
        case nil:
            selectDefault()
        }
        if case .working(let c)? = diffSource {
            let all = status.staged + status.unstaged + status.conflicted
            if let match = all.first(where: { $0.path == c.path && $0.staged == c.staged }) {
                diffSource = .working(match)
                loadDiff(keepCurrent: true)
            } else if let match = all.first(where: { $0.path == c.path }) {
                // 파일 전체를 스테이지한 직후에도 같은 파일의 diff 를 이어서 보여 준다.
                openDiff(.working(match), revealPage: false)
            } else {
                closeDiff()
            }
        }
    }

    func selectDefault() {
        if !status.isEmpty || headHash == nil {
            select(.wip)
            scrollTarget = entries.first?.id
        } else if let h = headHash {
            select(.commit(h))
            scrollTarget = h
        }
    }
}
