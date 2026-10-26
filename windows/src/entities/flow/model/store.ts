import { samePathKey } from "@/shared/config";
import { Observable } from "@/shared/lib";
import { FlowEngineError, flowEngine } from "./engine";
import { consumeEvents, newRunView, type RunView } from "./run-view";
import type { FlowGate, FlowList, FlowRunRow } from "./types";

const activeStates = new Set(["RUNNING", "PENDING", "PREFLIGHT", "ROLLING_BACK"]);

/**
 * 저장소마다 하나: 흐름 목록 · 최근 실행 · 따라 읽는 실행(맥 FlowStore.swift 와 같다).
 * 저장소 탭(RepoStore)과 따로 두어 탭을 닫았다 열어도 돌던 실행을 계속 따라 읽는다.
 */
export class FlowStore extends Observable {
  list: FlowList | null = null;
  hasFlowFile = false;
  engine: string | null | undefined = undefined;
  error: FlowEngineError | null = null;
  loading = false;
  runs: FlowRunRow[] = [];
  gate: FlowGate | null = null;
  /** 실행 ID → 화면 상태(따라 읽는 중이거나 마지막에 본 것) */
  views = new Map<string, RunView>();
  /** 끝난 실행의 기록(run.json) */
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
      // 앱을 다시 열었을 때도 돌고 있는 실행을 이어서 따라 읽는다.
      for (const r of this.runs) if (r.running && !this.tails.has(r.runId)) this.follow(r.runId);
    } finally {
      this.loading = false;
      this.changed();
    }
  }

  /** 실행을 시작하고 이벤트를 따라 읽는다. 실행 ID 를 돌려준다. */
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

  /** 실행을 열 때: 기록을 읽고, 아직 돌면 따라 읽고, 끝났으면 이벤트 전체로 화면 상태를 만든다. */
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
      // 오래 조용하면 엔진이 살아 있는지 본다(강제 종료 · 전원 꺼짐이면 run.done 없이 멈춘다).
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

/** 저장소 경로 → 그 저장소의 흐름 상태(같은 저장소는 같은 객체) */
export function flowStoreFor(repo: string): FlowStore {
  const key = samePathKey(repo);
  let s = stores.get(key);
  if (!s) {
    s = new FlowStore(repo);
    stores.set(key, s);
  }
  return s;
}
