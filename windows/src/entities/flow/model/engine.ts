import { gitch } from "@/entities/gitch";
import { ipc } from "@/shared/api";
import { env, isWindows, joinPath, slash } from "@/shared/config";
import { language, t } from "@/shared/i18n";
import { type FlowDetached, type FlowGate, type FlowInitProposal, type FlowList, type FlowPlan, type FlowRunRow, parseEngineError } from "./types";

/**
 * 흐름 엔진(gitch-flow, tools/gitch-flow) 부르기(맥 FlowEngine.swift 와 같다). 앱 설치 폴더의 gitch-flow.exe 를 먼저 쓰고,
 * 없으면 셸 명령 gitch 옆(~/.local/share/gitch)의 것을 쓴다.
 * 앱이 보내는 것은 사람이 누른 동작뿐이라 실행 주체를 gitrochi-app 으로 밝힌다 — 엔진의 신뢰 · 확인 규칙은 그대로다
 * (AI 가 부르는 gitch flow 는 신뢰 승인 · 게이트 · 잠금 해제를 할 수 없다).
 */
export class FlowEngineError extends Error {
  constructor(
    message: string,
    /** 엔진의 실패 코드(TRUST-01 · SPEC-02 …) */
    public code: string | null = null,
    /** 엔진이 알려 준 조치 */
    public action: string | null = null,
  ) {
    super(message);
  }
}

const exe = isWindows() ? "gitch-flow.exe" : "gitch-flow";

class FlowEngineService {
  private found: string | null | undefined;

  /** 쓸 엔진 경로(없으면 null). 한 번 찾으면 앱이 켜진 동안 그대로 쓴다. */
  async executable(): Promise<string | null> {
    if (this.found !== undefined) return this.found;
    const dir = env.resourceDir.replace(/^\\\\\?\\/, "");
    const candidates = [dir ? slash(joinPath(dir, exe)) : "", joinPath(env.home, ".local/share/gitch", exe)].filter(Boolean);
    for (const c of candidates) {
      if (await ipc.exists(c)) return (this.found = c);
    }
    return (this.found = null);
  }

  private async environment(): Promise<Record<string, string>> {
    const e: Record<string, string> = { GITSW_ACTOR: "gitrochi-app", GITCH_FLOW_LANG: language === "ko" ? "ko" : "en" };
    // 엔진이 영향 그래프 · gitch 블록에서 gitch 를 되부를 때
    const g = gitch.bundled;
    if (g && (await ipc.exists(g))) e.GITCH_PATH = g;
    const bash = await gitch.bash();
    if (bash) e.GITCH_BASH = bash;
    return e;
  }

  async run(args: string[], repo: string, timeoutMs = 120_000) {
    const path = await this.executable();
    if (!path) throw new FlowEngineError(t("The flow engine (gitch-flow) isn't in this Gitrochi. Update Gitrochi, or build it with tools/gitch-flow/build.sh."), "ENGINE-03");
    return ipc.run(path, args, { cwd: repo, env: await this.environment(), timeoutMs });
  }

  /** JSON 을 내는 명령. 실패하면 엔진의 오류 봉투로 던진다. */
  async json<T>(args: string[], repo: string, ok: number[] = [0], timeoutMs = 120_000): Promise<T> {
    const r = await this.run([...args, "--json"], repo, timeoutMs);
    if (ok.includes(r.status)) {
      try {
        return JSON.parse(r.stdout) as T;
      } catch {
        // 아래에서 오류로
      }
    }
    throw this.failure(r);
  }

  failure(r: { status: number; stdout: string; stderr: string }): FlowEngineError {
    const e = parseEngineError(r.stderr);
    if (e) return new FlowEngineError(e.message, e.code, e.action);
    const text = (r.stderr || r.stdout).trim();
    return new FlowEngineError(text ? text.slice(0, 2000) : `exit ${r.status}`);
  }

  private async plainOk(args: string[], repo: string) {
    const r = await this.run(args, repo);
    if (r.status !== 0) throw this.failure(r);
    return r.stdout;
  }

  hasFlowFile(repo: string) {
    return ipc.exists(joinPath(repo, ".gitch/flow.yml"));
  }

  list(repo: string) {
    return this.json<FlowList>(["list"], repo);
  }

  plan(flow: string, repo: string, affected = false) {
    return this.json<FlowPlan>(["plan", flow, ...(affected ? ["--affected=worktree"] : [])], repo);
  }

  /** 사람이 신뢰 확인 화면에서 승인했을 때만 부른다. */
  async trust(repo: string) {
    await this.plainOk(["trust", "--yes", "--json"], repo);
  }

  /** 분리 실행: 엔진이 뒤에서 돌고 앱은 이벤트를 따라 읽는다(앱을 닫아도 실행은 끝까지 간다). */
  start(flow: string, repo: string, affected: boolean, yes: boolean) {
    return this.json<FlowDetached>(["run", flow, "--detach", "--trigger", "app", ...(affected ? ["--affected=worktree"] : []), ...(yes ? ["--yes"] : [])], repo);
  }

  async cancel(runId: string, repo: string) {
    await this.plainOk(["cancel", runId, "--json"], repo);
  }

  async runs(repo: string): Promise<FlowRunRow[]> {
    return (await this.json<{ runs: FlowRunRow[] }>(["status", "--all"], repo)).runs;
  }

  /** 끝난 실행의 기록 전체(run.json — 노드별 판정 · 실패 위치 · 되돌림) */
  record(runId: string, repo: string) {
    return this.json<Record<string, unknown>>(["status", runId], repo, [0, 1]);
  }

  /** seq 다음부터의 이벤트(NDJSON 글) */
  async events(runId: string, since: number, repo: string): Promise<string> {
    const r = await this.run(["events", runId, "--since", String(since)], repo, 30_000);
    return r.status === 0 ? r.stdout : "";
  }

  /** 사람 · AI 에게 붙여 넣기 좋은 Markdown 요약 */
  markdown(runId: string, repo: string) {
    return this.plainOk(["report", runId, "--format", "md"], repo);
  }

  proposeInit(repo: string) {
    return this.json<FlowInitProposal>(["init", "--dry-run"], repo);
  }

  async writeInit(repo: string) {
    await this.plainOk(["init", "--yes", "--json"], repo);
  }

  gate(repo: string) {
    return this.json<FlowGate>(["gate", "status"], repo);
  }

  async setGate(on: boolean, flow: string, repo: string) {
    await this.plainOk(["gate", on ? "on" : "off", ...(on ? ["--flow", flow] : []), "--json"], repo);
  }

  async version(): Promise<{ version: string; flowApi: number } | null> {
    try {
      const r = await this.run(["version", "--json"], env.home, 15_000);
      const v = JSON.parse(r.stdout) as { version?: string; flowApi?: number };
      return typeof v.flowApi === "number" ? { version: String(v.version ?? ""), flowApi: v.flowApi } : null;
    } catch {
      return null;
    }
  }
}

export const flowEngine = new FlowEngineService();
