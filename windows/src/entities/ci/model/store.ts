import { type Branch, branchRemote, branchShort, type ConfirmRequest, type GraphEntry, type HostAccount, type Provider, type RepoTarget } from "@/entities/git";
import * as Hosting from "@/entities/hosting";
import { accounts } from "@/entities/hosting";
import { ipc } from "@/shared/api";
import { joinPath, settings } from "@/shared/config";
import { t } from "@/shared/i18n";
import { Observable } from "@/shared/lib";
import { describe } from "@/shared/platform";
import { type CIAccess, CIAPI } from "../api/ci-api";
import { pipelineVariables } from "../lib/yaml";
import { type CIDeployment, type CIInput, type CIJob, type CIPipeline, type CIWorkflow, isActiveCI } from "./types";

/** CI 가 읽는 저장소 탭 — 순환 참조를 피하려고 필요한 것만(RepoStore 가 채운다) */
export interface CIHost {
  readonly path: string | null;
  readonly target: RepoTarget | null;
  readonly hostingAccount: HostAccount | null;
  readonly currentBranch: Branch | null;
  readonly remoteBranches: Branch[];
  readonly commitIndex: Map<string, number>;
  readonly entries: GraphEntry[];
  readonly isActive: boolean;
  showError(message: string): void;
  ask(request: ConfirmRequest): void;
}

/** 저장소 탭마다 하나: 파이프라인 목록·작업·버튼 동작 */
export class CIStore extends Observable {
  pipelines: CIPipeline[] = [];
  state: { kind: "idle" } | { kind: "loading" } | { kind: "loaded" } | { kind: "needsAccount" } | { kind: "failed"; message: string } = { kind: "idle" };
  jobs = new Map<number, CIJob[]>();
  deployments = new Map<number, CIDeployment[]>();
  /** 커밋 SHA → 그 커밋의 가장 최근 파이프라인(그래프·PR 목록의 CI 표시) */
  bySha = new Map<string, CIPipeline>();
  private badgeTimer: ReturnType<typeof setTimeout> | null = null;
  /** 진행 중인 버튼 동작(같은 버튼을 두 번 누르지 않게) */
  busy = new Set<string>();

  constructor(private repo: CIHost) {
    super();
  }

  get currentBranchOnly() {
    return settings.get("ciCurrentBranchOnly", false);
  }

  setCurrentBranchOnly(v: boolean) {
    settings.set("ciCurrentBranchOnly", v);
    this.emit();
  }

  reset() {
    if (this.badgeTimer) clearTimeout(this.badgeTimer);
    this.badgeTimer = null;
    this.bySha = new Map();
    this.pipelines = [];
    this.jobs = new Map();
    this.deployments = new Map();
    this.state = { kind: "idle" };
    this.emit();
  }

  /** PR·MR 과 같은 계정을 쓴다 */
  async access(): Promise<CIAccess | null> {
    const target = this.repo.target;
    const a = this.repo.hostingAccount;
    if (!target || !a) return null;
    const token = await accounts.token(a);
    if (!token) return null;
    return { target: target, token, apiBase: a.provider === "github" ? "https://api.github.com" : a.server + "/api/v4" };
  }

  get hasAccess() {
    return !!this.repo.target && !!this.repo.hostingAccount;
  }

  /** 서버에서의 현재 브랜치 이름(추적 브랜치가 있으면 그 이름) */
  get currentRef(): string | null {
    const b = this.repo.currentBranch;
    if (!b) return null;
    if (b.upstream && b.upstream.includes("/")) return b.upstream.slice(b.upstream.indexOf("/") + 1);
    return b.name;
  }

  /** 실행할 수 있는 브랜치: 이 저장소 원격의 브랜치(현재 브랜치가 맨 앞) */
  get branches(): string[] {
    const target = this.repo.target;
    if (!target) return [];
    const names = this.repo.remoteBranches.filter((b) => branchRemote(b) === target.remote && !branchShort(b).endsWith("HEAD")).map(branchShort);
    const cur = this.currentRef;
    const i = cur ? names.indexOf(cur) : -1;
    if (i > 0) names.unshift(...names.splice(i, 1));
    return names;
  }

  /** 커밋 제목(GitLab 파이프라인에는 없어서 그래프의 커밋에서) */
  subject(sha: string): string | null {
    const i = this.repo.commitIndex.get(sha);
    return i === undefined ? null : this.repo.entries[i].commit.subject;
  }

  private same(target: RepoTarget) {
    const cur = this.repo.target;
    return !!cur && cur.host === target.host && cur.path === target.path && cur.provider === target.provider;
  }

  /** 받은 파이프라인 목록을 보여 준다(커밋마다 가장 최근 것도 정리) */
  showPipelines(list: CIPipeline[]) {
    this.pipelines = list;
    const map = new Map<string, CIPipeline>();
    for (const p of list) if (!map.has(p.sha)) map.set(p.sha, p);
    this.bySha = map;
    this.state = { kind: "loaded" };
    this.emit();
  }

  /** 그래프·PR 목록의 CI 표시: 최근 파이프라인만(작업 목록은 읽지 않음). 실행 중인 게 있으면 20초마다 다시. */
  async refreshBadges() {
    if (!this.repo.target || !this.repo.hostingAccount) return;
    await this.load(true, false);
    if (this.badgeTimer || !this.pipelines.some((p) => isActiveCI(p.status))) return;
    const tick = async () => {
      this.badgeTimer = null;
      if (this.repo.isActive) await this.load(true, false);
      if (this.pipelines.some((p) => isActiveCI(p.status))) this.badgeTimer = setTimeout(() => void tick(), 20_000);
    };
    this.badgeTimer = setTimeout(() => void tick(), 20_000);
  }

  async load(silent = false, withJobs = true) {
    const target = this.repo.target;
    if (!target) return this.reset();
    if (!this.repo.hostingAccount && accounts.accountsFor(target.provider).length) await accounts.discoverAlias(target, true);
    const c = await this.access();
    if (!c) {
      if (target.provider === "gitlab") accounts.suggestedGitLabServer = `https://${target.host}`;
      this.pipelines = [];
      this.state = this.repo.hostingAccount
        ? { kind: "failed", message: t("Couldn't read the saved account credentials. Unlock your credentials, then retry.") }
        : { kind: "needsAccount" };
      this.emit();
      return;
    }
    if (!silent || this.state.kind !== "loaded") {
      this.state = { kind: "loading" };
      this.emit();
    }
    try {
      const list = await CIAPI.pipelines(c, this.currentBranchOnly ? this.currentRef : null);
      if (!this.same(target)) return;
      const before = new Map(this.pipelines.map((p) => [p.id, p.status]));
      this.showPipelines(list);
      const ids = new Set(list.map((p) => p.id));
      for (const k of [...this.jobs.keys()]) if (!ids.has(k)) this.jobs.delete(k);
      for (const k of [...this.deployments.keys()]) if (!ids.has(k)) this.deployments.delete(k);
      this.emit();
      // 최근 파이프라인은 작업까지 읽어 둔다(수동 실행 대기 ▶ 표시·승인 대기)
      const recent = !withJobs ? [] : target.provider === "gitlab" ? list.slice(0, 5) : list.filter((p) => p.status === "waiting");
      for (const p of recent) {
        if (!this.jobs.has(p.id) || before.get(p.id) !== p.status || isActiveCI(p.status)) await this.loadJobs(p, true);
      }
    } catch (e) {
      if (!this.same(target)) return;
      // 자동 새로 고침이 한 번 실패한 것으로 목록을 지우지 않는다
      if (!silent || !this.pipelines.length) this.state = { kind: "failed", message: describe(e) };
      this.emit();
    }
  }

  async loadJobs(p: CIPipeline, silent = false) {
    const c = await this.access();
    if (!c) return;
    try {
      const jobs = await CIAPI.jobs(c, p.id);
      if (!this.same(c.target)) return;
      this.jobs.set(p.id, jobs);
      const current = this.pipelines.find((x) => x.id === p.id) ?? p;
      if (c.target.provider === "github" && current.status === "waiting") {
        this.deployments.set(p.id, await CIAPI.pendingDeployments(c, p.id).catch(() => []));
      } else this.deployments.delete(p.id);
    } catch (e) {
      if (!this.jobs.has(p.id)) this.jobs.set(p.id, []);
      if (!silent) this.repo.showError(ciError(e, c.target.provider));
    }
    this.emit();
  }

  // MARK: 버튼

  playJob(job: CIJob, p: CIPipeline) {
    this.repo.ask({
      title: t("Run the '{0}' job?", job.name),
      message: t("{0} · pipeline #{1}", p.ref, p.number) + (job.stage ? t(" · {0} stages", job.stage) : ""),
      actionTitle: t("Run"),
      destructive: false,
      action: () => this.act(`job:${job.id}`, p, (c) => CIAPI.play(c, job.id)),
    });
  }

  retryJob(job: CIJob, p: CIPipeline) {
    return this.act(`job:${job.id}`, p, (c) => CIAPI.retryJob(c, job.id));
  }

  cancelJob(job: CIJob, p: CIPipeline) {
    return this.act(`job:${job.id}`, p, (c) => CIAPI.cancelJob(c, job.id));
  }

  retryPipeline(p: CIPipeline, failedOnly: boolean) {
    return this.act(`pipeline:${p.id}`, p, (c) => CIAPI.retryPipeline(c, p.id, failedOnly));
  }

  cancelPipeline(p: CIPipeline) {
    this.repo.ask({
      title: t("Cancel pipeline #{0}?", p.number),
      message: t("Running work in {0} will stop.", p.ref),
      actionTitle: t("Cancel run"),
      action: () => this.act(`pipeline:${p.id}`, p, (c) => CIAPI.cancelPipeline(c, p.id)),
    });
  }

  /** GitHub 환경 보호 규칙의 배포 승인·거부 */
  reviewDeployment(p: CIPipeline, deps: CIDeployment[], approve: boolean) {
    const names = deps.map((d) => d.environment).join(", ");
    this.repo.ask({
      title: approve ? t("Approve the '{0}' deployment?", names) : t("Reject the '{0}' deployment?", names),
      message: `${p.name} #${p.number} · ${p.ref}`,
      actionTitle: approve ? t("Approve") : t("Reject"),
      destructive: !approve,
      action: () =>
        this.act(`pipeline:${p.id}`, p, (c) =>
          CIAPI.review(
            c,
            p.id,
            deps.map((d) => d.environmentID),
            approve,
          ),
        ),
    });
  }

  /** GitLab: 새 파이프라인 */
  runPipeline(ref: string, variables: [string, string][]) {
    return this.act("run", null, (c) => CIAPI.runPipeline(c, ref, variables));
  }

  /** GitHub: workflow_dispatch 실행(실행 목록에 나타나기까지 몇 초 걸려 한 번 더 읽는다) */
  async runWorkflow(w: CIWorkflow, ref: string, inputs: Record<string, string>) {
    await this.act("run", null, (c) => CIAPI.dispatch(c, w.id, ref, inputs));
    await new Promise((r) => setTimeout(r, 4000));
    await this.load(true);
  }

  async workflows(ref: string): Promise<CIWorkflow[]> {
    const c = await this.access();
    return c ? CIAPI.workflows(c, ref) : [];
  }

  /** .gitlab-ci.yml 에서 설명이 붙은 변수(파이프라인 실행 화면에 미리 채움) */
  async gitlabVariables(): Promise<CIInput[]> {
    if (!this.repo.path) return [];
    const text = await ipc.readText(joinPath(this.repo.path, ".gitlab-ci.yml")).catch(() => null);
    return text ? pipelineVariables(text) : [];
  }

  private async act(key: string, p: CIPipeline | null, work: (c: CIAccess) => Promise<unknown>) {
    const c = await this.access();
    if (!c || this.busy.has(key)) return;
    this.busy.add(key);
    this.emit();
    try {
      await work(c);
    } catch (e) {
      this.repo.showError(ciError(e, c.target.provider));
      return;
    } finally {
      this.busy.delete(key);
      this.emit();
    }
    await new Promise((r) => setTimeout(r, 700));
    await this.load(true);
    if (p) await this.loadJobs(p, true);
  }
}

export function ciError(e: unknown, provider: Provider): string {
  const base = describe(e);
  if (!(e instanceof Hosting.HostingError) || (e.status !== 403 && e.status !== 404)) return base;
  return provider === "gitlab"
    ? base + t("\n\nTo run it, your token needs the api scope (read_api is not enough) and you need Developer or higher on the project. Protected branches and environments need those permissions too.")
    : base + t("\n\nTo run it, your token needs write access to Actions (classic token: repo; fine-grained token: Actions: Read and write). Try reconnecting the account in Settings.");
}
