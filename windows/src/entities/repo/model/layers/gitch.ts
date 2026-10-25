import { countGraphRules, gitch, type GitchAccount, type GitchBackup, type GitchPreflight, type GitchStatus, type GraphCheck, type GraphPage, type GraphRelation, type GraphReview, graphRelations, graphRulesFile } from "@/entities/gitch";
import { ipc } from "@/shared/api";
import { joinPath } from "@/shared/config";
import { t } from "@/shared/i18n";
import { describe } from "@/shared/platform";
import { RepoTerminal } from "./terminal";

/** gitch graph 로 만드는 페이지 — 한 번에 하나(그동안 구조 그래프 메뉴의 항목을 끈다) */
export type GraphJob = { kind: "draw"; relation: GraphRelation } | { kind: "diff"; relation: GraphRelation } | { kind: "checkPage" } | { kind: "review" };

export type CommitImpactState =
  | { kind: "running" }
  | { kind: "done"; result: GraphReview; revision: number; notice?: string }
  | { kind: "failed"; message: string };

/** 의존 규칙 검사 창이 보여 줄 것 */
export type GraphCheckState =
  | { kind: "running" }
  /** rules: 규칙 줄 수(0 이면 --init 이 만든 예시 그대로 — 모두 주석) */
  | { kind: "done"; result: GraphCheck; rules: number }
  | { kind: "failed"; message: string };

/** gitch(여러 Git 계정 도구): 이 저장소의 계정(잠금)·커밋/push 전 점검·저장소 단위 gitch 명령 (맥 버전 RepoStore+Gitch) */
export abstract class RepoGitch extends RepoTerminal {
  /** gitch 가 관리하는 저장소일 때만(계정을 만들어 두지 않았으면 null — 화면에 gitch 바가 없다) */
  gitchStatus: GitchStatus | null = null;
  gitchPreflight: GitchPreflight | null = null;
  gitchAccounts: GitchAccount[] = [];
  /** 직접 push 를 막은 브랜치(gitch protect) */
  gitchProtected = new Set<string>();
  gitchChecking = false;
  private gitchGen = 0;

  /** 사용자가 누를 때만 분석한다. 분석하는 동안에도 스테이지나 커밋 작업은 막지 않는다. */
  commitImpact: CommitImpactState | null = null;
  commitImpactVerifying = false;
  private commitImpactGen = 0;

  get commitImpactStale(): boolean {
    return this.commitImpact?.kind === "done" && (this.commitImpact.result.stale || this.commitImpact.revision !== this.statusGeneration);
  }

  protected resetState() {
    super.resetState();
    this.commitImpactGen++;
    this.commitImpact = null;
    this.commitImpactVerifying = false;
  }

  async reload(quiet = false) {
    await super.reload(quiet);
    void this.verifyCommitImpact();
  }

  async reloadStatus() {
    await super.reloadStatus();
    void this.verifyCommitImpact();
  }

  /** 같은 파일을 다시 올리면 파일 수나 줄 수가 그대로여도 스테이지 내용은 바뀔 수 있다. */
  private async verifyCommitImpact() {
    const state = this.commitImpact;
    const path = this.path;
    if (!path || state?.kind !== "done" || state.result.stale || state.revision === this.statusGeneration) return;
    const request = ++this.commitImpactGen;
    const revision = this.statusGeneration;
    this.commitImpactVerifying = true;
    this.emit();
    try {
      const stamp = await gitch.commitReviewStamp(path);
      if (request !== this.commitImpactGen || this.path !== path || this.commitImpact !== state) return;
      this.commitImpact = { ...state, revision, result: { ...state.result, stale: stamp !== state.result.stamp } };
    } catch (error) {
      if (request !== this.commitImpactGen || this.path !== path || this.commitImpact !== state) return;
      this.commitImpact = { ...state, result: { ...state.result, stale: true }, notice: describe(error) };
    } finally {
      if (request === this.commitImpactGen) {
        this.commitImpactVerifying = false;
        this.emit();
      }
    }
  }

  async analyzeCommitImpact() {
    const path = this.path;
    if (!path || this.commitImpact?.kind === "running" || !this.status.staged.length || this.status.conflicted.length) return;
    const request = ++this.commitImpactGen;
    this.commitImpact = { kind: "running" };
    this.commitImpactVerifying = false;
    this.emit();
    try {
      const result = await gitch.commitReview(path);
      if (request !== this.commitImpactGen || this.path !== path) return;
      const revision = this.statusGeneration;
      const stamp = await gitch.commitReviewStamp(path);
      if (request !== this.commitImpactGen || this.path !== path) return;
      this.commitImpact = { kind: "done", result: { ...result, stale: result.stale || stamp !== result.stamp }, revision };
    } catch (error) {
      if (request === this.commitImpactGen && this.path === path) this.commitImpact = { kind: "failed", message: describe(error) };
    } finally {
      if (request === this.commitImpactGen) this.emit();
    }
  }

  /** 최신 여부 확인과 HTML 생성 모두 스테이지와 HEAD를 비교하는 같은 분석을 사용한다. */
  async openCommitImpactGraph() {
    const path = this.path;
    const state = this.commitImpact;
    if (!path || state?.kind !== "done" || this.commitImpactStale || this.commitImpactVerifying || this.graphJob) return;
    const job: GraphJob = { kind: "review" };
    this.graphJob = job;
    this.emit();
    const stillCurrent = () => this.path === path && this.commitImpact === state;
    const stale = () => {
      if (stillCurrent()) this.commitImpact = { ...state, result: { ...state.result, stale: true } };
    };
    try {
      if (await gitch.commitReviewStamp(path) !== state.result.stamp) { stale(); return; }
      if (!stillCurrent()) return;
      const page = await gitch.commitReviewGraph(path);
      if (!stillCurrent()) return;
      if (await gitch.commitReviewStamp(path) !== state.result.stamp) { stale(); return; }
      if (stillCurrent()) await this.openStructureGraphPage(page);
    } catch (error) {
      if (stillCurrent()) this.commitImpact = { ...state, notice: describe(error) };
    } finally {
      if (this.graphJob === job) this.graphJob = null;
      this.emit();
    }
  }

  /** gitch 가 보는 이 저장소의 계정과 점검을 다시 읽는다. fetch 면 원격을 받아 받을 커밋까지 본다(몇 초). */
  async refreshGitch(fetch = false) {
    const path = this.path;
    const gen = ++this.gitchGen;
    // 저장소 메뉴의 구조 그래프를 켤지(앱에 든 gitch 버전) — 계정 설정과 상관없이 한 번 봐 둔다
    void gitch.checkGraph();
    if (!path || !(await gitch.hasConfig())) {
      if (this.gitchStatus || this.gitchPreflight || this.gitchAccounts.length || this.gitchProtected.size) {
        this.gitchStatus = null;
        this.gitchPreflight = null;
        this.gitchAccounts = [];
        this.gitchProtected = new Set();
        this.emit();
      }
      return;
    }
    this.gitchChecking = true;
    this.emit();
    const [status, preflight, accounts, protectedOut] = await Promise.all([
      gitch.status(path),
      gitch.preflight(path, fetch),
      gitch.accounts(),
      this.g(["config", "--get-all", "gitswitch.protect"], { ok: [0, 1] }).catch(() => null),
    ]);
    if (gen !== this.gitchGen || this.path !== path) return;
    this.gitchChecking = false;
    const managed = status?.inRepo ? status : null;
    this.gitchStatus = managed;
    this.gitchPreflight = managed ? preflight : null;
    this.gitchAccounts = accounts;
    this.gitchProtected = new Set((protectedOut?.stdout ?? "").split(/\r?\n/).filter(Boolean));
    this.emit();
  }

  /**
   * gitch 명령으로 이 저장소를 바꾸고 작성자·그래프·gitch 상태를 다시 읽는다. 실패하면 gitch 가 낸 문구를 보여 준다.
   * gitch 는 브랜치를 옮기기 전에 스스로 백업하므로(gitch rescue) 앱의 되돌리기 기록에는 넣지 않는다.
   */
  async runGitch(args: string[]): Promise<boolean> {
    const path = this.path;
    if (!path || this.busy != null) return false;
    this.busy = t("Running gitch…");
    this.emit();
    let ok = true;
    try {
      await gitch.run(args, path, 900_000);
    } catch (e) {
      this.fail(e);
      ok = false;
    }
    await this.reloadIdentity();
    await this.reload(!ok);
    this.busy = null;
    this.emit();
    await this.refreshGitch();
    return ok;
  }

  /** gitch use · unlock 은 작성자를 바꾸므로 커밋 칸의 내 이름·이메일을 다시 읽는다 */
  private async reloadIdentity() {
    const r = await this.g(["config", "--get-regexp", "^user\\.(name|email)$"], { ok: [0, 1] }).catch(() => null);
    const conf = Object.fromEntries((r?.stdout ?? "").split(/\r?\n/).filter(Boolean).map((l) => [l.slice(0, l.indexOf(" ")), l.slice(l.indexOf(" ") + 1).trim()]));
    this.me = conf["user.name"] ? { name: conf["user.name"], email: conf["user.email"] ?? "" } : null;
  }

  /** 이 저장소를 다른 gitch 계정으로(gitch use): 작성자·원격 주소·잠금이 바뀐다 */
  useGitchAccount(id: string) {
    return this.runGitch(["use", id]);
  }

  /** 계정 잠금 풀기(작성자 설정은 그대로) */
  unlockGitch() {
    return this.runGitch(["unlock", "--yes"]);
  }

  /** gitch 검사(작성자·비밀값·push)에서 빼거나 되돌리기 */
  setGitchIgnored(ignored: boolean) {
    return this.runGitch(ignored ? ["ignore", "--yes"] : ["ignore", "--off"]);
  }

  /** 직접 push 를 막는 브랜치로(다른 브랜치에서 PR 로만 합치게) */
  setGitchProtected(branch: string, on: boolean) {
    return this.runGitch(on ? ["protect", branch] : ["protect", "--rm", branch]);
  }

  /** 기본 브랜치 최신을 따라가기(gitch up): push 전이면 rebase, push 한 브랜치면 merge */
  gitchUp() {
    return this.runGitch(["up"]);
  }

  /** 포크를 원본(upstream) 최신으로(gitch sync) */
  gitchSync() {
    return this.runGitch(["sync"]);
  }

  /** push 안 한 커밋 중 작성자가 이 저장소 계정이 아닌 것: 고칠 것이 있으면 확인받고 gitch fix --yes, 없으면 gitch 가 낸 안내 */
  async confirmGitchFix() {
    if (!this.path) return;
    try {
      const r = await gitch.runRaw(["fix"], this.path);
      // 2 = 고칠 커밋이 있어 확인이 필요(목록은 출력에), 0 = 고칠 것 없음
      if (r.status === 2) {
        this.ask({
          title: t("Fix commit authors?"),
          message: r.output.replace(/\n확인이 필요합니다[\s\S]*$/, ""),
          actionTitle: t("Fix"),
          action: () => this.runGitch(["fix", "--yes"]),
        });
      } else if (r.status === 0) {
        this.ask({ title: t("Commit authors are fine"), message: r.output, actionTitle: t("OK"), action: () => {} });
      } else this.showError(r.output);
    } catch (e) {
      this.fail(e);
    }
  }

  gitchBackups(): Promise<GitchBackup[]> {
    return this.path ? gitch.backups(this.path) : Promise.resolve([]);
  }

  /** 백업으로 되돌리기(지금 상태도 먼저 백업) 또는 새 브랜치로 꺼내기. 번호는 실행 직전에 다시 찾는다(그 사이 백업이 늘 수 있어서). */
  async gitchRestore(backup: GitchBackup, toBranch: string | null): Promise<boolean> {
    const index = (await this.gitchBackups()).findIndex((b) => b.ref === backup.ref);
    if (index < 0) {
      this.showError(t("That backup no longer exists."));
      return false;
    }
    const pick = String(index + 1);
    return this.runGitch(toBranch ? ["rescue", pick, "--branch", toBranch] : ["rescue", pick, "--restore", "--yes"]);
  }

  /** gitch graph 로 만들고 있는 페이지(구조 그래프 · 바뀐 의존 · 규칙 위반). 읽기만 하는 일이라 busy 와 달리 다른 작업은 막지 않는다 */
  graphJob: GraphJob | null = null;
  /** 의존 규칙 검사 창에 보일 결과(gitch graph check) */
  graphCheck: GraphCheckState | null = null;

  /** gitch graph 가 페이지를 만드는 동안 툴바에 보일 글(관계 이름까지 넣으면 툴바 버튼이 밀려나서 짧게) */
  get graphProgress(): string | null {
    if (!this.graphJob) return null;
    if (this.graphJob.kind === "review") return t("Drawing staged change impact…");
    return this.graphJob.kind === "diff" ? t("Comparing dependencies…") : t("Drawing the structure graph…");
  }

  /** 구조 그래프(gitch graph)를 html 로 만들어 기본 브라우저로 연다. 실패하면 gitch 가 낸 문구를 보여 준다. */
  async openStructureGraph(relation: GraphRelation, precise = false) {
    const path = this.path;
    if (!path || this.graphJob) return;
    this.graphJob = { kind: "draw", relation };
    this.emit();
    try {
      const page = await gitch.graph(relation, path, precise);
      if (this.path !== path) return;
      if (page.nodes === 0) {
        // 빈 페이지를 띄우기보다 gitch 가 찾지 못한 것을 먼저 알린다
        const title = graphRelations().find((r) => r.id === relation)?.title ?? relation;
        this.ask({
          title: t("Nothing to draw"),
          message: page.hint ?? t("gitch found nothing to draw for {0}.", title),
          actionTitle: t("Open anyway"),
          action: () => this.openStructureGraphPage(page).catch((e) => this.fail(e)),
        });
      } else await this.openStructureGraphPage(page);
    } catch (e) {
      if (this.path === path) this.fail(e);
    } finally {
      this.graphJob = null;
      this.emit();
    }
  }

  async openAffectedGraph(base: string | null = null) {
    const path = this.path;
    if (!path || this.graphJob) return;
    this.graphJob = { kind: "draw", relation: "files" };
    this.emit();
    try {
      const page = await gitch.affectedGraph(path, base);
      if (this.path === path) await this.openStructureGraphPage(page);
    } catch (error) {
      if (this.path === path) this.fail(error);
    } finally {
      this.graphJob = null;
      this.emit();
    }
  }

  private openStructureGraphPage(page: GraphPage) {
    return page.liveUrl ? ipc.openUrl(page.liveUrl) : ipc.openHtml(page.file);
  }

  /**
   * 이 브랜치에서 바뀐 의존(gitch graph diff)을 html 로 만들어 기본 브라우저로 연다.
   * base 가 null 이면 gitch 의 기본값(기본 브랜치와 갈라진 곳), 있으면 그 브랜치 · 태그와 이 브랜치가 갈라진 곳과 비교한다.
   */
  async openGraphDiff(relation: GraphRelation, base: string | null = null) {
    const path = this.path;
    if (!path || this.graphJob) return;
    this.graphJob = { kind: "diff", relation };
    this.emit();
    try {
      const file = await gitch.graphDiff(relation, base, path);
      if (this.path !== path) return;
      await ipc.openHtml(file);
    } catch (e) {
      if (this.path === path) this.fail(e);
    } finally {
      this.graphJob = null;
      this.emit();
    }
  }

  /**
   * 의존 규칙 검사(gitch graph check): 규칙 파일이 없으면 예시로 만들지 묻고, 있으면 결과 창을 띄우고 검사한다.
   * 검사가 돌고 있으면(창을 닫았다 바로 다시 연 때) 새로 돌리지 않고 그 결과를 기다린다
   */
  async checkGraphRules() {
    const path = this.path;
    if (!path) return;
    if (!(await ipc.exists(joinPath(path, graphRulesFile)))) {
      this.ask({
        title: t("No dependency rules yet"),
        message: t("gitch graph check reads its rules from .gitch/graph.rules in this repository. Create the file with commented-out examples (gitch graph check --init) and open it?"),
        actionTitle: t("Create rules file"),
        destructive: false,
        action: () => this.createGraphRules(),
      });
      return;
    }
    if (this.graphCheck?.kind !== "running") this.graphCheck = null; // 지난 결과가 잠깐 보이지 않게
    this.openSheet({ kind: "graphCheck" });
    await this.runGraphCheck();
  }

  /** 규칙 검사를 (다시) 돌려 결과 창에 넣는다. 위반이 있어 gitch 가 1 로 끝나도 결과다. */
  async runGraphCheck() {
    const path = this.path;
    if (!path || this.graphCheck?.kind === "running") return;
    this.graphCheck = { kind: "running" };
    this.emit();
    // 그동안 저장소가 바뀌면 결과를 버리되, 「검사하는 중」으로 남아 다시 검사를 막지 않게 비운다
    try {
      const result = await gitch.graphRulesCheck(path);
      const rules = countGraphRules((await ipc.readText(joinPath(path, graphRulesFile))) ?? "");
      if (this.path !== path) return void (this.graphCheck = null);
      this.graphCheck = { kind: "done", result, rules };
    } catch (e) {
      if (this.path !== path) return void (this.graphCheck = null);
      this.graphCheck = { kind: "failed", message: describe(e) };
    }
    this.emit();
  }

  /** gitch graph check --init 으로 예시가 든 규칙 파일을 만들고 메모장으로 연다(예시는 모두 주석이라 고친 뒤에 검사한다) */
  async createGraphRules() {
    const path = this.path;
    if (!path) return;
    try {
      await gitch.graphRulesInit(path);
      await this.openGraphRules();
    } catch (e) {
      this.fail(e);
    }
  }

  async openGraphRules() {
    const path = this.path;
    if (path) await ipc.openRules(joinPath(path, graphRulesFile)).catch((e) => this.fail(e));
  }

  /** 규칙 위반을 그린 페이지(gitch graph check --format html)를 기본 브라우저로 연다. 결과 창에서 부르므로 실패하면 그 문구를 돌려준다 */
  async openGraphCheckPage(): Promise<string | null> {
    const path = this.path;
    if (!path || this.graphJob) return null;
    this.graphJob = { kind: "checkPage" };
    this.emit();
    try {
      const file = await gitch.graphCheckPage(path);
      if (this.path === path) await ipc.openHtml(file);
      return null;
    } catch (e) {
      return describe(e);
    } finally {
      this.graphJob = null;
      this.emit();
    }
  }

  /** 아래 터미널 탭에서 gitch 명령(doctor 처럼 길게 보여 주는 것) */
  async runGitchInTerminal(args: string[]) {
    const c = await gitch.terminalCommand(args);
    if (!c) {
      this.showError(t("Couldn't find gitch inside Gitrochi."));
      return;
    }
    this.newTerminal(this.path ?? undefined, { program: c.program, args: c.args, title: `gitch ${args.join(" ")}` });
  }
}
