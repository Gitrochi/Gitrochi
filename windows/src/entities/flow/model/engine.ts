import { gitch } from "@/entities/gitch";
import { ipc } from "@/shared/api";
import { env, isWindows, joinPath, slash } from "@/shared/config";
import { language, t } from "@/shared/i18n";
import { type FlowDetached, type FlowGate, type FlowInitProposal, type FlowList, type FlowPlan, type FlowRunRow, parseEngineError } from "./types";

/**
 * Calls the flow engine (gitch-flow, tools/gitch-flow), like the macOS FlowEngine.swift. The app's gitch-flow.exe comes first,
 * then the one next to the shell's gitch (~/.local/share/gitch).
 * The app sends only actions a person clicked, so it identifies itself as gitrochi-app; the engine's trust and confirmation rules still apply
 * (gitch flow called by an AI agent can never approve trust, switch the gate or release a hold).
 */
export class FlowEngineError extends Error {
  constructor(
    message: string,
    /** The engine's failure code (TRUST-01, SPEC-02 …) */
    public code: string | null = null,
    /** What the engine says to do */
    public action: string | null = null,
  ) {
    super(message);
  }
}

const exe = isWindows() ? "gitch-flow.exe" : "gitch-flow";

class FlowEngineService {
  private found: string | null | undefined;

  /** The engine to use (null when there is none). Once found, it is kept while the app runs. */
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
    // For when the engine calls gitch back (the affected graph, gitch blocks)
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

  /** A command that prints JSON. On failure it throws the engine's error envelope. */
  async json<T>(args: string[], repo: string, ok: number[] = [0], timeoutMs = 120_000): Promise<T> {
    const r = await this.run([...args, "--json"], repo, timeoutMs);
    if (ok.includes(r.status)) {
      try {
        return JSON.parse(r.stdout) as T;
      } catch {
        // handled as an error below
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

  async hasFlowFile(repo: string) {
    if (await ipc.exists(joinPath(repo, ".gitch/flow.yml")) || await ipc.exists(joinPath(repo, ".gitch/flow.yaml"))) return true;
    return (await ipc.list(joinPath(repo, ".gitch/flows")).catch(() => [])).some((file) => /\.ya?ml$/.test(file) && !file.startsWith("."));
  }

  validate(repo: string) {
    return this.json<{ valid: boolean }>(["validate"], repo);
  }

  list(repo: string) {
    return this.json<FlowList>(["list"], repo);
  }

  plan(flow: string, repo: string, affected = false) {
    return this.json<FlowPlan>(["plan", flow, ...(affected ? ["--affected=worktree"] : [])], repo);
  }

  /** Called only after a person approved in the trust dialog. */
  async trust(repo: string) {
    await this.plainOk(["trust", "--yes", "--json"], repo);
  }

  /** Detached run: the engine runs in the background and the app follows its events (the run finishes even if the app quits). */
  start(flow: string, repo: string, affected: boolean, yes: boolean) {
    return this.json<FlowDetached>(["run", flow, "--detach", "--trigger", "app", ...(affected ? ["--affected=worktree"] : []), ...(yes ? ["--yes"] : [])], repo);
  }

  async cancel(runId: string, repo: string) {
    await this.plainOk(["cancel", runId, "--json"], repo);
  }

  async runs(repo: string): Promise<FlowRunRow[]> {
    return (await this.json<{ runs: FlowRunRow[] }>(["status", "--all"], repo)).runs;
  }

  /** The full record of a finished run (run.json: verdict per node, failure locations, rollback) */
  record(runId: string, repo: string) {
    return this.json<Record<string, unknown>>(["status", runId], repo, [0, 1]);
  }

  /** Events after seq (NDJSON text) */
  async events(runId: string, since: number, repo: string): Promise<string> {
    const r = await this.run(["events", runId, "--since", String(since)], repo, 30_000);
    return r.status === 0 ? r.stdout : "";
  }

  /** A Markdown summary that is easy to paste for people or AI agents */
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
