import { samePathKey } from "@/shared/config";
import { Observable } from "@/shared/lib";
import { FlowEngineError, flowEngine } from "./engine";
import { consumeEvents, newRunView, type RunView } from "./run-view";
import type { FlowGate, FlowList, FlowRunRow } from "./types";

const activeStates = new Set(["RUNNING", "PENDING", "PREFLIGHT", "ROLLING_BACK"]);

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

  constructor(public readonly repo: string) {
    super();
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
    if (!this.views.has(runId)) {
      if (rec && activeStates.has(String(rec.state))) this.follow(runId);
      else {
        const v = newRunView(runId);
        consumeEvents(v, await flowEngine.events(runId, 0, this.repo));
        this.views.set(runId, v);
      }
    }
    this.changed();
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
        if (rec) this.records.set(runId, rec);
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
