import { ipc } from "@/shared/api";
import { joinPath, samePathKey, settings } from "@/shared/config";
import { Observable, decodeValidationBindings, type ValidationBinding } from "@/shared/lib";
import { worktreeStamp } from "@/shared/platform";
import { FlowEngineError, flowEngine } from "./engine";
import { recordIsRunning, recoverRunHistory } from "./history";
import { consumeEvents, newRunView, type RunView } from "./run-view";
import type { FlowGate, FlowList, FlowRunRow } from "./types";

/**
 * One per repository: the flows, recent runs and the run being followed (like the macOS FlowStore.swift).
 * Kept apart from the repository tab (RepoStore) so a run keeps being followed after its tab is closed and reopened.
 */
export class FlowStore extends Observable {
  list: FlowList | null = null;
  hasFlowFile = false;
  engine: string | null | undefined = undefined;
  error: FlowEngineError | null = null;
  loading = false;
  runs: FlowRunRow[] = [];
  gate: FlowGate | null = null;
  /** Run ID → screen state (being followed, or as last seen) */
  views = new Map<string, RunView>();
  /** Records of finished runs (run.json) */
  records = new Map<string, Record<string, unknown>>();
  private tails = new Set<string>();
  validationBindings: ValidationBinding[];

  constructor(public readonly repo: string) {
    super();
    this.validationBindings = decodeValidationBindings(settings.get(`workValidation:${samePathKey(repo)}`, []));
  }

  private saveValidation() { settings.set(`workValidation:${samePathKey(this.repo)}`, this.validationBindings.slice(-100)); }

  /** Only a trusted local plan can start from change evidence; other plans use the existing review UI. */
  async startVerified(flow: string, candidates: string[]): Promise<string> {
    const plan = await flowEngine.plan(flow, this.repo, false);
    if (!plan.trust.trusted || plan.outward.length || plan.gates.length || plan.nodes.some(node => node.decision === "run" && (node.destructive || node.outward || node.executor && node.executor !== "local"))) throw new Error("Review and approve this flow in the Flows workspace before running it here.");
    const before = await worktreeStamp(this.repo);
    const run = await flowEngine.start(flow, this.repo, false, false);
    this.validationBindings.push({ schemaVersion: 1, runID: run.runId, head: before.head, before: before.stamp, candidates, observedAt: new Date().toISOString() });
    this.saveValidation();
    this.follow(run.runId);
    void this.refresh();
    return run.runId;
  }

  changed() {
    this.emit();
  }

  async refresh() {
    this.engine = await flowEngine.executable();
    this.hasFlowFile = await flowEngine.hasFlowFile(this.repo);
    if (!this.engine) return this.changed();
    this.loading = true;
    this.changed();
    try {
      if (this.hasFlowFile) {
        try {
          this.list = await flowEngine.list(this.repo);
          this.error = null;
        } catch (e) {
          this.list = null;
          this.error = e instanceof FlowEngineError ? e : new FlowEngineError(String(e));
        }
      } else {
        this.list = null;
        this.error = null;
      }
      this.runs = await flowEngine.runs(this.repo).catch(() => []);
      this.gate = await flowEngine.gate(this.repo).catch(() => null);
      // After the app reopens, keep following runs that are still going.
      for (const r of this.runs) if (r.running && !this.tails.has(r.runId)) this.follow(r.runId);
    } finally {
      this.loading = false;
      this.changed();
    }
  }

  /** Starts a run and follows its events. Returns the run ID. */
  async start(flow: string, affected: boolean, yes: boolean): Promise<string> {
    const d = await flowEngine.start(flow, this.repo, affected, yes);
    this.follow(d.runId);
    void this.refresh();
    return d.runId;
  }

  async cancel(runId: string) {
    await flowEngine.cancel(runId, this.repo);
  }

  async trust() {
    await flowEngine.trust(this.repo);
    await this.refresh();
  }

  async setGate(on: boolean, flow: string) {
    await flowEngine.setGate(on, flow, this.repo);
    this.gate = await flowEngine.gate(this.repo).catch(() => null);
    this.changed();
  }

  /** Opening a run: read its record, follow it while it runs, or build the screen state from all its events once it has finished. */
  async open(runId: string) {
    const rec = await flowEngine.record(runId, this.repo).catch(() => null);
    if (rec) this.records.set(runId, rec);
    if (!this.tails.has(runId)) {
      let view = this.views.get(runId) ?? newRunView(runId);
      if (!this.views.has(runId)) consumeEvents(view, await flowEngine.events(runId, 0, this.repo));
      if (rec) view = recoverRunHistory(view, rec, await this.savedPlan(rec), this.runs.find(row => row.runId === runId)?.running);
      this.views.set(runId, view);
      if (rec && !view.done && recordIsRunning(rec, this.runs.find(row => row.runId === runId)?.running)) this.follow(runId);
    }
    this.changed();
  }

  private async savedPlan(record: Record<string, unknown>): Promise<unknown> {
    const directory = typeof record.runDir === "string" ? record.runDir
      : typeof record.eventsPath === "string" ? record.eventsPath.replace(/[\\/][^\\/]+$/, "") : null;
    if (!directory) return null;
    try {
      const source = await ipc.readText(joinPath(directory, "plan.json"));
      return source ? JSON.parse(source) as unknown : null;
    } catch { return null; }
  }

  private follow(runId: string) {
    if (this.tails.has(runId)) return;
    this.tails.add(runId);
    const v = this.views.get(runId) ?? newRunView(runId);
    this.views.set(runId, v);
    let rest = "";
    let quiet = 0;
    const tick = async () => {
      const text = await flowEngine.events(runId, v.lastSeq, this.repo).catch(() => "");
      if (text) {
        rest = consumeEvents(v, rest + text);
        quiet = 0;
        this.changed();
      } else quiet++;
      // After a long silence, check that the engine is alive (a killed engine or a power cut stops without run.done).
      if (!v.done && quiet > 0 && quiet % 15 === 0) {
        const row = (await flowEngine.runs(this.repo).catch(() => [])).find((r) => r.runId === runId);
        if (row && !row.running) {
          v.state = row.state;
          v.code = row.code ?? null;
          v.done = true;
        }
      }
      if (v.done) {
        this.tails.delete(runId);
        const rec = await flowEngine.record(runId, this.repo).catch(() => null);
        if (rec) {
          this.records.set(runId, rec);
          this.views.set(runId, recoverRunHistory(v, rec, await this.savedPlan(rec)));
        }
        const binding = this.validationBindings.find(value => value.runID === runId && !value.after);
        if (binding && rec && ["SUCCEEDED", "FAILED", "REJECTED", "CANCELLED", "ROLLED_BACK", "ROLLBACK_FAILED"].includes(String(rec.state)) && typeof rec.finishedAt === "string") {
          try { binding.after = (await worktreeStamp(this.repo)).stamp; this.saveValidation(); }
          catch { /* A missing end snapshot remains unbound. */ }
        }
        await this.refresh();
        return;
      }
      setTimeout(() => void tick(), 700);
    };
    void tick();
  }
}

const stores = new Map<string, FlowStore>();

/** Repository path → that repository's flow state (the same object for the same repository) */
export function flowStoreFor(repo: string): FlowStore {
  const key = samePathKey(repo);
  let s = stores.get(key);
  if (!s) {
    s = new FlowStore(repo);
    stores.set(key, s);
  }
  return s;
}
