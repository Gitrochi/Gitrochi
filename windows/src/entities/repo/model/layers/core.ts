import { RepositoryConfirmationGuard } from "../../lib/confirmation-guard";
import type { AgentHost } from "@/entities/agent";
import { isWorkspaceDestination, repositoryDestinations, restoredDestination, returnsToRepository, type WorkspaceDestination } from "@/entities/git";
import { avatars } from "@/entities/avatar";
import { type CIPipeline, CIStore } from "@/entities/ci";
import * as P from "@/entities/git";
import { type BlameLine, type Branch, type CommitDetail, type ConfirmRequest, type ConflictChoice, type ConflictDocument, type DiffDocument, type DiffSource, type DropRequest, emptyStatus, type FileChange, type FileHistoryEntry, type FileInspect, type GraphEntry, type Identity, layoutGraphAsync, type LineStat, type LoadingInfo, type LoadState, type PullRequest, type RebasePlan, type RefLabel, refOrder, type RepoState, type RepoTarget, sameTarget, type SearchScope, type Selection, selectionID, type SheetKind, short, type SplitGroup, type Stash, statusCount, statusIsEmpty, type Tag, wipCommit, type WorkingStatus, type Worktree, type WorktreeStats, worktreeWIPCommit } from "@/entities/git";
import * as Hosting from "@/entities/hosting";
import { accounts, type PullRequestReview } from "@/entities/hosting";
import { TerminalSession, type TerminalSpec, type TermNode } from "@/entities/terminal";
import { ipc } from "@/shared/api";
import { addRecent, basename, env, joinPath, samePath, settings, slash } from "@/shared/config";
import { t } from "@/shared/i18n";
import { Observable } from "@/shared/lib";
import { describe, git, type GitOptions, gitRaw, repoIndex, unsafeRepository } from "@/shared/platform";
import type { UndoPoint } from "../../lib/undo-model";

/** Which worktree rows a graph was drawn with */
export const pendingRowsKey = (list: Worktree[]) => list.map((w) => w.path + "@" + w.head).join("|");

export const EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";

/** 개발자 도구에서 localStorage.gitrochiTrace = "1" 이면 새로 고침 종류와 걸린 시간을 콘솔에(성능 확인용) */
function trace(s: string) {
  try {
    if (localStorage.getItem("gitrochiTrace") === "1") console.debug("[gitrochi]", s);
  } catch {
    /* 무시 */
  }
}

/** 저장소 하나(=탭 하나)의 상태, 열기·닫기, 새로 고침 */
export abstract class RepoCore extends Observable implements AgentHost {
  // 뒤 단계(repo/*.ts)에서 채우는 것들
  /** CI/CD 패널(파이프라인·Actions) — RepoStore 가 만든다 */
  abstract readonly ci: CIStore;
  abstract select(sel: Selection | null): void;
  abstract closeDiff(): void;
  abstract closeConflict(): void;
  abstract closeFileInspect(): void;
  protected abstract loadDiff(keepCurrent: boolean): void;
  abstract get repoStateTitle(): string;
  abstract loadPullRequests(): Promise<void>;
  abstract newTerminal(path?: string, spec?: Partial<TerminalSpec>): TerminalSession;
  abstract focusTerminal(s: TerminalSession): void;
  abstract closeAllTerminals(): void;
  abstract switchWorktree(path: string): Promise<void>;
  abstract refreshWorktreeStats(): Promise<void>;
  abstract run(label: string, args: string[], o?: { network?: boolean; input?: string; env?: Record<string, string> }): Promise<boolean>;
  abstract refreshGitch(fetch?: boolean): Promise<void>;
  abstract cancelPushReview(): void;
  abstract cancelChangeQuestion(): void;
  abstract cancelRepositoryAssistant(): void;
  abstract preserveDiscardedChanges(paths?: string[]): Promise<boolean>;
  abstract clearHistorySelection(): void;

  readonly id = crypto.randomUUID();
  /** 지금 보이는 탭인지 — 뒤에 있는 탭은 파일이 바뀌어도 바로 다시 읽지 않고 돌아왔을 때 읽는다 */
  isActive = false;
  protected pendingReload = false;

  // 저장소
  path: string | null = null;
  destination: WorkspaceDestination = "home";
  /** A page the repository screen links to was opened from there, so it shows "‹ Repository" (macOS: cameFromRepository) */
  cameFromRepository = false;
  /** True while a reload reconciles the selection, so it never changes the page (macOS: workspaceNavigationPreparing) */
  private reconcilingSelection = false;
  gitDir: string | null = null;
  get name() {
    return this.path ? basename(this.path) : "Gitrochi";
  }

  /** Shows a page; pages that need a repository are refused until one is open. The page is remembered per repository. */
  navigate(page: WorkspaceDestination, prepare = true) {
    if (!isWorkspaceDestination(page) || (repositoryDestinations.has(page) && !this.path)) return false;
    // the Pull requests and Issues pages offer a way back when the repository screen opened them
    if (this.destination !== page) this.cameFromRepository = this.destination === "repository" && returnsToRepository.has(page);
    this.destination = page;
    if (this.path) settings.set("workspaceDestinations", { ...settings.get<Record<string, string>>("workspaceDestinations", {}), [this.path]: page });
    // the Pull requests page shows one request at a time; an unrelated diff or file view would hide its list
    if (prepare && page === "pullRequests" && this.selection?.kind !== "pullRequest") { this.closeDiff(); this.closeFileInspect(); }
    this.emit(); return true;
  }

  /** "‹ Repository" and its shortcut Ctrl+[ (macOS: ⌘[): back to the repository screen from a page it opened */
  returnToRepository() {
    return this.cameFromRepository && returnsToRepository.has(this.destination) && this.navigate("repository");
  }

  /** The run the Actions page should select and show next, set by a CI badge in the graph (macOS: ciFocus) */
  ciFocus: number | null = null;
  /** The run shown on the right of the Actions page (macOS: ciSelected) */
  ciSelected: number | null = null;

  /** Opens the Actions page on a run; the page selects it, loads its jobs and lets go of the focus */
  openCI(pipeline: CIPipeline) {
    if (!this.navigate("actions")) return;
    this.ciFocus = pipeline.id;
    this.emit();
  }

  /** Shows the run on the right of the Actions page and reads its jobs */
  selectRun(pipeline: CIPipeline) {
    this.ciSelected = pipeline.id;
    this.emit();
    void this.ci.loadJobs(pipeline);
  }

  /** A graph selection made from the Pull requests page (keyboard, routes) belongs to the repository screen */
  syncWorkspaceSelection(selection: Selection | null) {
    if (this.reconcilingSelection || !selection || this.destination !== "pullRequests" || selection.kind === "pullRequest") return;
    this.navigate("repository", false);
  }

  /** The page a repository was on last time, or the repository screen; Home without a repository */
  private restoreWorkspaceDestination() {
    const saved = this.path ? settings.get<Record<string, unknown>>("workspaceDestinations", {})[this.path] : null;
    this.navigate(restoredDestination(saved, !!this.path));
  }

  // 데이터
  entries: GraphEntry[] = [];
  maxLanes = 1;
  commitIndex = new Map<string, number>();
  refsByCommit = new Map<string, RefLabel[]>();
  localBranches: Branch[] = [];
  remoteBranches: Branch[] = [];
  remotes: string[] = [];
  tags: Tag[] = [];
  stashes: Stash[] = [];
  status: WorkingStatus = emptyStatus();
  headHash: string | null = null;
  headBranch: string | null = null;
  repoState: RepoState = "clean";
  hasMore = false;
  protected limit = 2000;

  // 선택·상세
  selection: Selection | null = null;
  newPullRequestDraft: { branch: string; title: string; body: string; base: string; draft: boolean; issue?: P.ProjectTaskReference } | null = null;
  detail: CommitDetail | null = null;
  detailFiles: FileChange[] = [];
  detailStats: Record<string, LineStat> = {};
  diffSource: DiffSource | null = null;
  diff: DiffDocument | null = null;
  diffLoading = false;
  /** diff 화면에서 고른 줄(lines 의 위치)과 Shift 범위의 시작 */
  diffSelection = new Set<number>();
  diffAnchor: number | null = null;
  /** 이미지 파일의 바뀌기 전·후(data: 주소) */
  diffImages: { old: string | null; new: string | null } | null = null;
  scrollTarget: string | null = null;

  // 커밋 입력
  summary = "";
  message = "";
  amend = false;
  protected mergeMessageFilled = false;

  // UI
  busy: string | null = null;
  errorMessage: string | null = null;
  sheet: SheetKind | null = null;
  private readonly confirmationGuard = new RepositoryConfirmationGuard();
  private pendingConfirmation: ConfirmRequest | null = null;
  get confirm(): ConfirmRequest | null { return this.pendingConfirmation; }
  set confirm(request: ConfirmRequest | null) {
    this.pendingConfirmation = request ? { ...request, action: this.confirmationGuard.wrap(this.path, () => this.path, request.action) } : null;
  }
  notRepoPrompt: string | null = null;
  /** git 이 "소유자가 달라 믿을 수 없는 저장소"로 막았을 때(WSL·외장 디스크 등): 등록할 경로 */
  unsafePrompt: { folder: string; safePath: string } | null = null;
  dropRequest: DropRequest | null = null;
  loading: LoadingInfo | null = null;
  /** 탭이 처음 무엇을 보여 줄지 정했는지(그 전에는 로딩 화면) */
  booted = false;

  // 줄 수·나
  stagedStats: Record<string, LineStat> = {};
  unstagedStats: Record<string, LineStat> = {};
  me: Identity | null = null;
  /** The global Git author (git config --global), shown while no repository is open */
  globalIdentity: Identity | null = null;

  /** Reads the global author through the system git; a repository's own identity is `me` */
  async loadGlobalIdentity() {
    const result = await gitRaw(["config", "--global", "--get-regexp", "^user\\.(name|email)$"], env.home || ".").catch(() => null);
    const next = result && (result.status === 0 || result.status === 1) ? P.parseIdentityConfig(result.stdout) : this.globalIdentity;
    if (JSON.stringify(next) === JSON.stringify(this.globalIdentity)) return;
    this.globalIdentity = next; this.emit();
  }

  // 검색
  searchText = "";
  searchScope: SearchScope = "commits";
  searchMatches: string[] = [];
  searchMatchSet = new Set<string>();
  searchUnloaded = 0;
  searching = false;
  searchFocusRequest = 0;
  /** The graph's search bar stays hidden until Ctrl+F; it also shows while a search is active (macOS: showSearchBar) */
  showSearchBar = false;
  protected searchGen = 0;
  protected searchTimer: ReturnType<typeof setTimeout> | null = null;

  // 워크트리·호스팅·Claude
  worktrees: Worktree[] = [];
  worktreeStats: Record<string, WorktreeStats> = {};
  /** Other worktrees' status (they aren't watched, so it is polled while this tab is in front) */
  worktreeStatus: Record<string, WorkingStatus> = {};
  remoteURLs: Record<string, string> = {};
  target: RepoTarget | null = null;
  pullRequests: PullRequest[] = [];
  prState: LoadState = { kind: "idle" };
  aiWorking: string | null = null;
  splitPlan: SplitGroup[] | null = null;
  aiNotice: string | null = null;
  explanations: Record<string, string> = {};
  explaining = new Set<string>();

  /** 되돌릴 수 있는 작업(마지막이 맨 뒤) */
  undoStack: UndoPoint[] = [];
  /** 그래프에서 숨긴 브랜치(refs/heads/x · refs/remotes/o/x), 사이드바 맨 위에 고정한 로컬 브랜치, 현재 브랜치만 보기 */
  /** 고른 PR·MR 의 대화·바뀐 파일·승인 */
  review: PullRequestReview | null = null;
  reviewLoading = false;
  reviewError: string | null = null;
  reviewBusy = false;
  /** 가운데에 띄운 파일 히스토리·blame */
  fileInspect: FileInspect | null = null;
  fileInspectLine: number | null = null;
  fileHistory: FileHistoryEntry[] = [];
  fileHistorySelected: string | null = null;
  fileHistoryDiff: DiffDocument | null = null;
  blameLines: BlameLine[] = [];
  fileInspectLoading = false;
  fileInspectError: string | null = null;
  hiddenRefs = new Set<string>();
  pinnedBranches = new Set<string>();
  graphCurrentOnly = false;
  /** 충돌 해결 중인 파일과 블록마다 고른 것 */
  conflictDoc: ConflictDocument | null = null;
  conflictChoices = new Map<number, ConflictChoice>();
  conflictPath: string | null = null;
  /** 커밋 정리(인터랙티브 리베이스) 창에 넘길 계획 */
  rebasePlan: RebasePlan | null = null;

  // 터미널 패널
  terminals: TerminalSession[] = [];
  activeTerminalID: string | null = null;
  /** How the terminal panel is split into panes of tabs */
  terminalLayout: TermNode | null = null;
  showTerminal = false;

  /** 다른 저장소·워크트리를 새 탭으로 여는 동작(작업 공간이 넣어 준다) */
  openRepo: ((path: string) => void) | null = null;
  /** 이 탭을 앞으로(에이전트 세션으로 이동할 때) */
  activateTab: (() => void) | null = null;
  /** Brings forward another tab already showing path; false if there is none */
  showTab: ((path: string) => boolean) | null = null;

  protected reloadGeneration = 0;
  protected watchIds: string[] = [];
  protected unlisten: (() => void)[] = [];
  protected watchTimer: ReturnType<typeof setTimeout> | null = null;
  /** 파일 감시가 모아 둔 새로 고침 종류(전체가 상태만보다 우선) */
  protected pendingKind: "status" | "full" | null = null;
  /** 상태만 다시 읽는 가벼운 새로 고침의 세대(전체 새로 고침이 시작되면 함께 올라간다) */
  protected statusGeneration = 0;
  /** 마지막으로 그래프·브랜치를 만든 git 출력 — 같으면 다시 해석·배치하지 않는다(행 객체도 그대로라 화면이 다시 그리지 않음) */
  protected lastLog: { out: string; wip: boolean; head: string | null; pending: string } | null = null;
  private worktreePoll: ReturnType<typeof setInterval> | null = null;
  protected lastRefs: string | null = null;
  protected lastIndexRefresh = 0;
  protected gitchKey: string | null = null;
  /** 공용 .git(연결된 워크트리면 gitDir 과 다르다) */
  protected commonDir: string | null = null;
  protected detailGen = 0;
  protected diffGen = 0;

  /** 화면이 바뀐 값을 다시 그리게 */
  changed() {
    this.emit();
  }

  /** 시트(작은 대화상자)를 띄운다 */
  openSheet(sheet: SheetKind) {
    this.sheet = sheet;
    this.changed();
  }

  get currentBranch() {
    return this.localBranches.find((b) => b.isCurrent) ?? null;
  }

  get selectedID(): string | null {
    return selectionID(this.selection);
  }

  /** 연결된 워크트리(메인이 아닌)로 연 탭인지 */
  get isLinkedWorktree() {
    return !!this.gitDir && slash(this.gitDir).includes("/worktrees/");
  }

  protected g(args: string[], o: GitOptions = {}) {
    return git(args, this.path!, o);
  }

  // MARK: - 열기·닫기

  /** 폴더가 속한 저장소의 최상위 경로(저장소가 아니면 null) */
  static async toplevel(folder: string): Promise<string | null> {
    try {
      const r = await gitRaw(["rev-parse", "--show-toplevel"], folder);
      return r.status === 0 && r.stdout.trim() ? r.stdout.trim() : null;
    } catch {
      return null;
    }
  }

  /** 탭으로 돌아왔을 때: 뒤에 있는 동안 바뀐 게 있으면 다시 읽는다 */
  async activated() {
    if (!this.path) return;
    if (this.pendingReload) {
      this.pendingReload = false;
      const k = this.pendingKind ?? "full";
      this.pendingKind = null;
      await (k === "full" ? this.reload(true) : this.reloadStatus());
    }
  }

  /** quick: switching worktrees, so skip the minimum loading animation */
  async open(folder: string, quick = false): Promise<{ kind: "opened" } | { kind: "notRepository"; path: string } | { kind: "failed"; message: string }> {
    const started = Date.now();
    this.loading = { title: t("Opening {0}", basename(folder)), step: t("Checking repository…") };
    this.emit();
    let r;
    try {
      r = await gitRaw(["rev-parse", "--show-toplevel", "--absolute-git-dir"], folder);
    } catch (e) {
      if (!this.path) this.loading = null;
      this.emit();
      return { kind: "failed", message: describe(e) };
    }
    if (r.status !== 0) {
      if (!this.path) this.loading = null;
      this.emit();
      const unsafe = unsafeRepository(r.stderr);
      if (unsafe) {
        this.unsafePrompt = { folder, safePath: unsafe };
        this.emit();
        return { kind: "failed", message: "" };
      }
      if (r.stderr.includes("not a git repository")) return { kind: "notRepository", path: folder };
      return { kind: "failed", message: r.stderr.trim() };
    }
    const lines = r.stdout.trim().split(/\r?\n/);
    if (lines.length < 2) {
      this.loading = null;
      this.emit();
      return { kind: "failed", message: t("Couldn't verify the repository path.") };
    }
    this.stopWatching();
    this.resetState();
    const top = lines[0].trim();
    this.loading = { title: t("Opening {0}", basename(top)), step: t("Reading commits and branches…") };
    this.path = top;
    this.gitDir = lines[1].trim();
    addRecent(top);
    this.loadGraphFilters();
    this.emit();
    // 내 이름·이메일과 공용 .git 위치를 한 번에(따로 띄우면 Windows 에선 git 하나에 수십 ms)
    const [cfg, common] = await Promise.all([
      this.g(["config", "--get-regexp", "^user\\.(name|email)$"], { ok: [0, 1] }).catch(() => null),
      this.g(["rev-parse", "--path-format=absolute", "--git-common-dir"]).catch(() => null),
    ]);
    const identity = P.parseIdentityConfig(cfg?.stdout ?? "");
    if (identity) this.me = identity;
    this.commonDir = common?.stdout.trim() || null;
    await this.startWatching();
    await this.reload();
    this.selectDefault();
    this.restoreWorkspaceDestination();
    if (this.worktrees.length > 1) void this.refreshWorktreeStats();
    this.worktreePoll ??= setInterval(() => {
      if (this.isActive && document.hasFocus() && this.worktrees.length > 1) void this.refreshWorktreeStats();
    }, 5000);
    // 로딩 화면이 번쩍 지나가지 않게 애니메이션 한 호흡(약 0.9초)은 보여 준다
    const shown = Date.now() - started;
    if (!quick && shown < 900) await new Promise((res) => setTimeout(res, 900 - shown));
    this.loading = null;
    this.emit();
    return { kind: "opened" };
  }

  async openInPlace(folder: string, quick = false) {
    const r = await this.open(folder, quick);
    if (r.kind === "notRepository") this.notRepoPrompt = r.path;
    else if (r.kind === "failed" && r.message) this.errorMessage = r.message;
    this.booted = true;
    this.emit();
  }

  /** 다른 저장소·워크트리 열기: 빈 탭이면 이 자리에, 저장소가 열린 탭이면 새 탭으로 */
  async openOrReport(folder: string) {
    if (!this.path) {
      await this.openInPlace(folder);
      return;
    }
    const top = await RepoCore.toplevel(folder);
    if (!top) {
      const r = await gitRaw(["rev-parse", "--show-toplevel"], folder).catch(() => null);
      const unsafe = r ? unsafeRepository(r.stderr) : null;
      if (unsafe) this.unsafePrompt = { folder, safePath: unsafe };
      else this.notRepoPrompt = folder;
      this.emit();
      return;
    }
    if (samePath(top, this.path)) return;
    this.openRepo?.(top);
  }

  /** 막힌 저장소를 git 의 safe.directory 에 등록하고 다시 연다 */
  async trustRepository() {
    const p = this.unsafePrompt;
    if (!p) return;
    this.unsafePrompt = null;
    this.emit();
    try {
      await git(["config", "--global", "--add", "safe.directory", p.safePath], env.home || env.temp);
    } catch (e) {
      this.fail(e);
      return;
    }
    await this.openOrReport(p.folder);
  }

  close() {
    if (this.worktreePoll) clearInterval(this.worktreePoll);
    this.worktreePoll = null;
    this.closeAllTerminals();
    this.stopWatching();
    this.resetState();
    this.path = null;
    this.gitDir = null;
    this.emit();
  }

  protected async startWatching() {
    if (!this.path) return;
    const dirs = [this.path];
    // 연결된 워크트리는 HEAD·refs 가 저장소 밖(.git/worktrees, 공용 .git)에 있어 그쪽도 본다
    for (const d of [this.gitDir, this.commonDir]) {
      if (d && !slash(d).toLowerCase().startsWith(slash(this.path).toLowerCase() + "/") && !dirs.some((x) => samePath(x, d))) dirs.push(d);
    }
    for (const d of dirs) {
      const id = `${this.id}-${this.watchIds.length}`;
      try {
        await ipc.watchStart(id, d);
        this.watchIds.push(id);
        this.unlisten.push(await ipc.onWatch(id, (paths) => this.fileSystemChanged(paths)));
      } catch {
        /* 감시를 못 해도 새로 고침(F5)으로 볼 수 있다 */
      }
    }
  }

  protected stopWatching() {
    for (const id of this.watchIds) void ipc.watchStop(id);
    for (const u of this.unlisten) u();
    this.watchIds = [];
    this.unlisten = [];
  }

  protected resetState() {
    this.confirmationGuard.invalidate();
    this.destination = "home";
    this.cameFromRepository = false;
    this.ciFocus = null;
    this.ciSelected = null;
    this.showSearchBar = false;
    this.cancelPushReview();
    this.cancelChangeQuestion();
    this.cancelRepositoryAssistant();
    this.sheet = null;
    this.confirm = null;
    this.busy = null;
    this.errorMessage = null;
    this.newPullRequestDraft = null;
    this.closeConflict();
    this.closeFileInspect();
    this.fileInspect = null;
    this.fileInspectLine = null;
    this.fileHistory = [];
    this.fileHistorySelected = null;
    this.fileHistoryDiff = null;
    this.blameLines = [];
    this.fileInspectError = null;
    this.gitchKey = null;
    this.entries = [];
    this.maxLanes = 1;
    this.commitIndex = new Map();
    this.refsByCommit = new Map();
    this.localBranches = [];
    this.remoteBranches = [];
    this.remotes = [];
    this.tags = [];
    this.stashes = [];
    this.status = emptyStatus();
    this.headHash = null;
    this.headBranch = null;
    this.repoState = "clean";
    this.hasMore = false;
    this.limit = 2000;
    this.lastLog = null;
    this.undoStack = [];
    this.lastRefs = null;
    this.pendingKind = null;
    this.commonDir = null;
    this.selection = null;
    this.detail = null;
    this.detailFiles = [];
    this.diffSource = null;
    this.diff = null;
    this.summary = "";
    this.message = "";
    this.amend = false;
    this.mergeMessageFilled = false;
    this.worktrees = [];
    this.worktreeStats = {};
    this.worktreeStatus = {};
    this.remoteURLs = {};
    this.target = null;
    this.pullRequests = [];
    this.review = null;
    this.reviewLoading = false;
    this.reviewBusy = false;
    this.reviewError = null;
    this.prState = { kind: "idle" };
    this.ci.reset();
    this.aiWorking = null;
    this.aiNotice = null;
    this.explanations = {};
    this.explaining = new Set();
    this.detailGen++;
    this.diffGen++;
  }

  async pickAndOpen() {
    const p = await ipc.pickFolder(t("Choose a Git repository folder"));
    if (p) await this.openOrReport(p);
  }

  async pickAndInit() {
    const p = await ipc.pickFolder(t("Choose a folder for the new Git repository"));
    if (p) await this.initRepository(p);
  }

  async initRepository(folder: string) {
    try {
      await git(["init"], folder);
      await this.openOrReport(folder);
    } catch (e) {
      this.fail(e);
    }
  }

  async clone(remote: string, parent: string, folder: string) {
    this.busy = t("Cloning…");
    if (!this.path) this.loading = { title: t("Cloning {0}", folder), step: t("Receiving from the remote repository…") };
    this.emit();
    try {
      await git(["clone", "--", remote, folder], parent, { timeoutMs: 3_600_000, env: await accounts.gitEnvironment(null, null) });
      this.busy = null;
      await this.openOrReport(joinPath(parent, folder));
    } catch (e) {
      this.busy = null;
      if (!this.path) this.loading = null;
      this.fail(e);
    }
  }

  fail(e: unknown) {
    this.errorMessage = describe(e);
    this.emit();
  }

  showError(message: string) {
    this.errorMessage = message;
    this.emit();
  }

  // MARK: - 새로 고침

  protected latestReload: Promise<void> | null = null;

  /** 저장소를 다시 읽는다. 도중에 더 새 읽기가 시작되면 그것까지 기다린다(부른 쪽이 늘 최신 상태를 보게). */
  async reload(quiet = false) {
    const p = this.readAll(quiet);
    this.latestReload = p;
    await p;
    while (this.latestReload && this.latestReload !== p) {
      const q: Promise<void> = this.latestReload;
      await q;
      if (this.latestReload === q) break;
    }
  }

  /** Other worktrees with uncommitted changes: each gets a row above its HEAD in the graph */
  protected pendingWorktrees(worktrees: Worktree[]) {
    return worktrees.filter((w) => !w.prunable && !!w.head && !samePath(w.path, this.path) && !statusIsEmpty(this.worktreeStatus[w.path] ?? emptyStatus()));
  }

  protected async readAll(quiet: boolean) {
    const path = this.path;
    if (!path) return;
    const gen = ++this.reloadGeneration;
    this.statusGeneration++;
    const started = performance.now();
    try {
      const [[st, statusMs], lg, rf, sh, hd, rm, wt, un, sn] = await Promise.all([
        this.timedStatus(),
        this.g(["log", ...this.logScope, "--date-order", "-n", String(this.limit + 1), "--format=" + P.logFormat], { ok: [0, 128] }),
        this.g(["for-each-ref", "--format=" + P.refFormat, "refs/heads", "refs/remotes", "refs/tags"]),
        this.g(["stash", "list", "--format=" + P.stashFormat], { ok: [0, 1, 128] }),
        this.g(["rev-parse", "--verify", "-q", "HEAD"], { ok: [0, 1, 128] }),
        this.g(["remote", "-v"]),
        this.g(["worktree", "list", "--porcelain", "-z"], { ok: [0, 128] }),
        this.g(["diff", "--no-ext-diff", "--numstat", "-z"], { ok: [0, 128] }),
        this.g(["diff", "--cached", "--no-ext-diff", "-M", "--numstat", "-z"], { ok: [0, 128] }),
      ]);
      if (gen !== this.reloadGeneration || this.path !== path) return;

      const newStatus = P.parseStatus(st.stdout);
      const head = hd.status === 0 ? hd.stdout.trim() : null;
      // 커밋이 그대로면(파일만 고친 경우 등) 해석·배치를 건너뛰고 지금 그래프를 그대로 쓴다
      const wip = !statusIsEmpty(newStatus);
      const worktrees = P.parseWorktrees(wt.stdout);
      const pending = this.pendingWorktrees(worktrees);
      const pendingKey = pendingRowsKey(pending);
      const sameLog =
        !!this.lastLog && this.lastLog.out === lg.stdout && this.lastLog.wip === wip && this.lastLog.head === head && this.lastLog.pending === pendingKey && this.entries.length > 0;
      if (!sameLog) {
        let commits = await P.parseLogAsync(lg.stdout);
        if (gen !== this.reloadGeneration || this.path !== path) return;
        const more = commits.length > this.limit;
        if (more) commits = commits.slice(0, this.limit);
        if (wip) commits.unshift(wipCommit(head));
        const known = new Set(commits.map((c) => c.id));
        commits.splice(wip ? 1 : 0, 0, ...pending.filter((w) => known.has(w.head!)).map((w) => worktreeWIPCommit(w.path, w.head!)));
        if (this.loading) {
          this.loading = { ...this.loading, step: t("Drawing the graph with {0} commits…", commits.length) };
          this.emit();
        }
        const layout = await layoutGraphAsync(commits);
        if (gen !== this.reloadGeneration || this.path !== path) return;
        this.hasMore = more;
        this.maxLanes = layout.maxLanes;
        this.entries = commits.map((c, i) => ({ commit: c, row: layout.rows[i] }));
        this.commitIndex = new Map();
        this.entries.forEach((e, i) => {
          if (!this.commitIndex.has(e.commit.id)) this.commitIndex.set(e.commit.id, i);
        });
        this.lastLog = { out: lg.stdout, wip, head, pending: pendingKey };
      }

      this.status = newStatus;
      this.headHash = head;
      this.headBranch = newStatus.branch;
      const refsChanged = this.lastRefs !== rf.stdout || !sameLog || this.refsByCommit.size === 0;
      if (this.lastRefs !== rf.stdout) {
        const refs = P.parseRefs(rf.stdout);
        this.localBranches = refs.locals;
        this.remoteBranches = refs.remotes;
        this.tags = refs.tags;
        this.lastRefs = rf.stdout;
      }
      this.stashes = P.parseStashes(sh.stdout);
      const parsed = P.parseRemotes(rm.stdout);
      this.remotes = parsed.names;
      this.remoteURLs = parsed.urls;
      this.worktrees = worktrees;
      // this worktree's card counts come from the status just read; other worktrees are polled
      const here = worktrees.find((w) => samePath(w.path, path));
      const stats = here && P.worktreeStats(newStatus);
      if (here && JSON.stringify(stats) !== JSON.stringify(this.worktreeStats[here.path])) this.worktreeStats = { ...this.worktreeStats, [here.path]: stats! };
      this.unstagedStats = P.parseNumstat(un.stdout);
      this.stagedStats = P.parseNumstat(sn.stdout);
      const newTarget = Hosting.findTarget(
        this.remotes,
        this.remoteURLs,
        accounts.accountsFor("gitlab").map((a) => new URL(a.server).host.toLowerCase()),
        accounts.sshHostAliases,
      );
      if (newTarget?.provider === "github") avatars.noteGitHubRepo(newTarget.path);
      if (!sameTarget(newTarget, this.target)) {
        this.target = newTarget;
        this.ci.reset();
        void this.loadPullRequests().then(() => this.ci.refreshBadges());
      }
      if (refsChanged || this.headBranch == null) this.refsByCommit = this.buildRefMap(head);
      this.repoState = await this.detectState();
      // 브랜치·ref 가 바뀌면 gitch 의 계정·점검을 다시(파일만 고친 것으로는 다시 보지 않는다)
      const gitchKey = (this.headBranch ?? "") + "\n" + rf.stdout;
      if (gitchKey !== this.gitchKey) {
        this.gitchKey = gitchKey;
        void this.refreshGitch();
      }
      await this.prefillMergeMessage();
      this.fixSelection();
      if (this.searchMatchSet.size) this.searchMatches = this.entries.filter((e) => this.searchMatchSet.has(e.commit.id)).map((e) => e.commit.id);
      this.emit();
      trace(`full reload ${Math.round(performance.now() - started)}ms (graph ${sameLog ? "reused" : "rebuilt"}, status ${Math.round(statusMs)}ms)`);
      this.refreshIndexIfSlow(statusMs);
      // Refs may have moved; the repository index catches up in the background (a no-op when current).
      void repoIndex.refresh(path);
    } catch (e) {
      if (gen !== this.reloadGeneration || quiet) return;
      this.fail(e);
    }
  }

  async loadMore() {
    this.limit += 3000;
    await this.reload();
  }

  /**
   * 바뀐 파일로 필요한 새로 고침을 고른다:
   * 작업 트리 파일·.git/index 만 바뀌었으면 상태만, HEAD·브랜치·태그·packed-refs·FETCH_HEAD 등이 바뀌었으면 전체.
   */
  protected fileSystemChanged(paths: string[]) {
    if (!this.path || !paths.length) return;
    const gitDirs = [this.gitDir ?? joinPath(this.path, ".git"), this.commonDir].filter((d): d is string => !!d).map((d) => slash(d).toLowerCase());
    let kind: "status" | "full" | null = null;
    for (const raw of paths) {
      if (raw === "*") {
        kind = "full";
        break;
      }
      const p = slash(raw).toLowerCase();
      const g = gitDirs.find((d) => p === d || p.startsWith(d + "/"));
      if (g) {
        const rel = p === g ? "" : p.slice(g.length + 1);
        // gitrochi/ holds the repository index, which syncs after reloads: watching it would loop.
        if (!rel || rel.startsWith("objects") || rel.startsWith("logs/") || rel.endsWith(".lock") || rel.startsWith("lfs/") || rel.startsWith("gitrochi/")) continue;
        if (rel === "index") {
          kind ??= "status";
          continue;
        }
        kind = "full";
        break;
      }
      kind ??= "status";
    }
    if (!kind) return;
    this.pendingKind = this.pendingKind === "full" || kind === "full" ? "full" : "status";
    if (!this.isActive) {
      this.pendingReload = true;
      return;
    }
    if (this.watchTimer) clearTimeout(this.watchTimer);
    this.watchTimer = setTimeout(() => {
      if (this.busy != null) return;
      const k = this.pendingKind ?? "full";
      this.pendingKind = null;
      void (k === "full" ? this.reload(true) : this.reloadStatus());
    }, 500);
  }

  /** git status 를 실행하고 걸린 시간(ms)도 */
  protected async timedStatus(): Promise<[Awaited<ReturnType<typeof git>>, number]> {
    const secs = performance.now();
    const r = await this.g(["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"]);
    return [r, performance.now() - secs];
  }

  /**
   * 가벼운 새로 고침: 작업 트리·스테이지 상태와 줄 수만(커밋 목록·브랜치는 그대로).
   * 변경이 생기거나 다 없어져 '작업 중인 변경' 행이 생기고 없어지면 전체를 다시 읽는다.
   */
  async reloadStatus() {
    const path = this.path;
    if (!path) return;
    const gen = ++this.statusGeneration;
    const started = performance.now();
    try {
      const [[st, statusMs], un, sn] = await Promise.all([
        this.timedStatus(),
        this.g(["diff", "--no-ext-diff", "--numstat", "-z"], { ok: [0, 128] }),
        this.g(["diff", "--cached", "--no-ext-diff", "-M", "--numstat", "-z"], { ok: [0, 128] }),
      ]);
      if (gen !== this.statusGeneration || this.path !== path) return;
      const newStatus = P.parseStatus(st.stdout);
      if (statusIsEmpty(newStatus) !== statusIsEmpty(this.status) || newStatus.branch !== this.status.branch) {
        await this.reload(true);
        return;
      }
      this.status = newStatus;
      this.unstagedStats = P.parseNumstat(un.stdout);
      this.stagedStats = P.parseNumstat(sn.stdout);
      this.repoState = await this.detectState();
      await this.prefillMergeMessage();
      this.fixSelection();
      this.emit();
      trace(`status reload ${Math.round(performance.now() - started)}ms (status ${Math.round(statusMs)}ms)`);
      this.refreshIndexIfSlow(statusMs);
    } catch {
      await this.reload(true);
    }
  }

  /**
   * git status 가 느리면(인덱스의 파일 정보가 낡아 매번 파일 내용을 다시 해시하는 경우) 인덱스를 한 번 새로 고친다.
   * 앱의 git 명령은 GIT_OPTIONAL_LOCKS=0 이라 status 가 인덱스를 고쳐 쓰지 않아서, 그대로 두면 계속 느리다.
   * 터미널의 git 과 index.lock 이 부딪히지 않게 1분에 한 번까지만. 새로 고친 인덱스에 대한 감시 알림은 상태만 다시 읽는다.
   */
  protected refreshIndexIfSlow(statusMs: number) {
    if (statusMs < 250 || !this.path || Date.now() - this.lastIndexRefresh < 60_000) return;
    this.lastIndexRefresh = Date.now();
    trace(`status took ${Math.round(statusMs)}ms — refreshing index`);
    void this.g(["update-index", "-q", "--refresh"], { ok: [0, 1, 128] }).catch(() => undefined);
  }

  /** 그래프에 그릴 커밋의 범위(git log 인자) */
  protected get logScope(): string[] {
    if (this.graphCurrentOnly) {
      const up = this.status.upstream;
      return ["HEAD", ...(up && this.remoteBranches.some((b) => b.name === up) ? [`refs/remotes/${up}`] : [])];
    }
    return [...[...this.hiddenRefs].sort().map((r) => `--exclude=${r}`), "--exclude=refs/stash", "--all"];
  }

  /** 저장소를 열 때: 이 저장소에서 숨긴·고정한 브랜치, 현재 브랜치만 보기 */
  protected loadGraphFilters() {
    const p = this.path;
    if (!p) return;
    this.hiddenRefs = new Set(settings.get<Record<string, string[]>>("graphHiddenRefs", {})[p] ?? []);
    this.pinnedBranches = new Set(settings.get<Record<string, string[]>>("pinnedBranches", {})[p] ?? []);
    this.graphCurrentOnly = settings.get<Record<string, boolean>>("graphCurrentOnly", {})[p] ?? false;
  }

  protected buildRefMap(head: string | null) {
    const map = new Map<string, RefLabel[]>();
    const add = (k: string, r: RefLabel) => {
      const l = map.get(k);
      if (l) l.push(r);
      else map.set(k, [r]);
    };
    if (!this.headBranch && head) add(head, { name: "HEAD", kind: "head", isCurrent: true });
    for (const b of this.localBranches) if (b.isCurrent || !this.hiddenRefs.has(`refs/heads/${b.name}`)) add(b.target, { name: b.name, kind: "local", isCurrent: b.isCurrent });
    for (const b of this.remoteBranches) if (!this.hiddenRefs.has(`refs/remotes/${b.name}`)) add(b.target, { name: b.name, kind: "remote", isCurrent: false });
    for (const tag of this.tags) add(tag.target, { name: tag.name, kind: "tag", isCurrent: false });
    for (const l of map.values()) l.sort((a, b) => (a.isCurrent ? 0 : 1) - (b.isCurrent ? 0 : 1) || refOrder[a.kind] - refOrder[b.kind]);
    return map;
  }

  protected async detectState(): Promise<RepoState> {
    const g = this.gitDir;
    if (!g) return "clean";
    const has = (p: string) => ipc.exists(joinPath(g, p));
    const [rm, ra, mh, ch, rh] = await Promise.all([has("rebase-merge"), has("rebase-apply"), has("MERGE_HEAD"), has("CHERRY_PICK_HEAD"), has("REVERT_HEAD")]);
    if (rm || ra) return "rebasing";
    if (mh) return "merging";
    if (ch) return "cherryPicking";
    if (rh) return "reverting";
    return "clean";
  }

  /** 머지·cherry-pick 충돌 중이면 git 이 준비한 MERGE_MSG 로 커밋 메시지를 한 번 채운다 */
  protected async prefillMergeMessage() {
    if (this.repoState === "clean") {
      this.mergeMessageFilled = false;
      return;
    }
    if (this.mergeMessageFilled || this.summary || this.message || !this.gitDir) return;
    const text = await ipc.readText(joinPath(this.gitDir, "MERGE_MSG"));
    if (!text) return;
    this.mergeMessageFilled = true;
    const lines = text.replace(/\r/g, "").split("\n").filter((l) => !l.startsWith("#"));
    this.summary = (lines[0] ?? "").trim();
    this.message = lines.slice(1).join("\n").trim();
  }

  protected fixSelection() {
    const sel = this.selection;
    this.reconcilingSelection = true;
    try {
      if (!sel) this.selectDefault();
      else if (sel.kind === "commit" && !this.commitIndex.has(sel.sha) && !this.stashes.some((s) => s.hash === sel.sha)) this.selectDefault();
    } finally { this.reconcilingSelection = false; }
    const ds = this.diffSource;
    if (ds?.kind === "working") {
      const all = [...this.status.staged, ...this.status.unstaged, ...this.status.conflicted];
      const match = all.find((c) => c.path === ds.change.path && c.staged === ds.change.staged);
      if (match) {
        this.diffSource = { kind: "working", change: match };
        this.loadDiff(true);
      } else this.closeDiff();
    }
  }

  selectDefault() {
    if (!statusIsEmpty(this.status) || !this.headHash) {
      this.select({ kind: "wip" });
      this.scrollTarget = this.entries[0]?.commit.id ?? null;
    } else {
      this.select({ kind: "commit", sha: this.headHash });
      this.scrollTarget = this.headHash;
    }
  }

  // MARK: - 기타

  revealFile(c: FileChange) {
    void this.revealPath(c.path);
  }

  /** 저장소 안 경로를 탐색기에서 고른다. 지워진 파일이면 남아 있는 가장 가까운 폴더를 연다. */
  async revealPath(rel: string) {
    if (!this.path) return;
    let p = rel.replace(/\/+$/, "");
    while (p && !(await ipc.exists(joinPath(this.path, p)))) p = p.includes("/") ? p.slice(0, p.lastIndexOf("/")) : "";
    await ipc.reveal(p ? joinPath(this.path, p) : this.path).catch((e) => this.fail(e));
  }


  copy(text: string) {
    void navigator.clipboard.writeText(text);
  }

  openUrl(url: string) {
    void ipc.openUrl(url).catch((e) => this.fail(e));
  }

  // 요약 문자열

  get subtitle() {
    if (!this.headBranch) return this.headHash ? t("Detached HEAD · {0}", short(this.headHash)) : "";
    let s = this.headBranch;
    if (this.status.upstream) {
      s += `  →  ${this.status.upstream}`;
      if (this.status.ahead) s += `  ↑${this.status.ahead}`;
      if (this.status.behind) s += `  ↓${this.status.behind}`;
    }
    if (this.repoState !== "clean") s += `  ·  ${this.repoStateTitle}`;
    return s;
  }

  get wipCount() {
    return statusCount(this.status);
  }
}
