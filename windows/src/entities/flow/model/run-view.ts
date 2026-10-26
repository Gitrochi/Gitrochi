import type { FlowEvent } from "./types";

/** Node state (the same names as the engine's state table) */
export type FlowNodeState = "PENDING" | "RUNNING" | "PASSED" | "FAILED" | "INDETERMINATE" | "SKIPPED" | "CACHED" | "REJECTED" | "CANCELLED";

export const isBadState = (s: string | null | undefined) => s === "FAILED" || s === "INDETERMINATE" || s === "REJECTED" || s === "CANCELLED";

export interface RunNode {
  id: string;
  title: string;
  block: string;
  needs: string[];
  branchOf: string | null;
  state: FlowNodeState;
  code: string | null;
  durationMs: number | null;
  testsPassed: number | null;
  testsExecuted: number | null;
  reason: string | null;
  log: string | null;
  tail: string[];
}

export interface RunStep {
  id: number;
  node: string | null;
  text: string;
  state: string;
}

/** The screen state of one run: feeding events in order builds up node states, log tails and rollback steps (lines with an equal or smaller seq are dropped). */
export interface RunView {
  runId: string;
  flow: string;
  state: string;
  code: string | null;
  exitCode: number | null;
  lastSeq: number;
  nodes: RunNode[];
  /** Things that happen outside nodes, like services and rollback */
  steps: RunStep[];
  done: boolean;
}

export const TAIL_LIMIT = 400;

export function newRunView(runId: string): RunView {
  return { runId, flow: "", state: "PENDING", code: null, exitCode: null, lastSeq: 0, nodes: [], steps: [], done: false };
}

const str = (v: unknown) => (typeof v === "string" ? v : null);
const num = (v: unknown) => (typeof v === "number" ? v : null);
const obj = (v: unknown) => (v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : {});

export function applyEvent(v: RunView, e: FlowEvent): void {
  if (!(e.seq > v.lastSeq)) return;
  v.lastSeq = e.seq;
  const d = obj(e.data);
  switch (e.type) {
    case "run.planned":
      v.flow = str(d.flow) ?? v.flow;
      v.nodes = (Array.isArray(d.nodes) ? d.nodes : []).flatMap((x) => {
        const n = obj(x);
        const id = str(n.id);
        if (!id) return [];
        return [
          {
            id,
            title: str(n.title) ?? id,
            block: str(n.block) ?? "",
            needs: Array.isArray(n.needs) ? n.needs.filter((s): s is string => typeof s === "string") : [],
            branchOf: str(n.branchOf),
            state: "PENDING" as FlowNodeState,
            code: null,
            durationMs: null,
            testsPassed: null,
            testsExecuted: null,
            reason: null,
            log: null,
            tail: [],
          },
        ];
      });
      break;
    case "run.state":
      v.state = str(d.state) ?? v.state;
      break;
    case "node.state": {
      const n = v.nodes.find((x) => x.id === e.node);
      if (!n) return;
      const s = str(d.state);
      if (s) n.state = s as FlowNodeState;
      n.code = str(d.code) ?? n.code;
      n.durationMs = num(d.durationMs) ?? n.durationMs;
      n.log = str(d.log) ?? n.log;
      const tests = obj(d.tests);
      if (num(tests.executed) != null) {
        n.testsExecuted = num(tests.executed);
        n.testsPassed = num(tests.passed);
      }
      n.reason = str(obj(d.reason).message) ?? str(d.detail) ?? n.reason;
      break;
    }
    case "log": {
      const n = v.nodes.find((x) => x.id === e.node);
      if (!n) return;
      const lines = (Array.isArray(d.lines) ? d.lines : []).flatMap((l) => {
        const t = typeof l === "string" ? l : str(obj(l).t);
        return t == null ? [] : [t];
      });
      n.tail.push(...lines);
      if (n.tail.length > TAIL_LIMIT) n.tail.splice(0, n.tail.length - TAIL_LIMIT);
      break;
    }
    case "service.state":
      v.steps.push({ id: e.seq, node: null, text: str(d.service) ?? "?", state: str(d.state) ?? "" });
      break;
    case "rollback.step":
      v.steps.push({ id: e.seq, node: e.node ?? null, text: str(d.title) ?? "", state: str(d.state) ?? "" });
      break;
    case "run.done":
      v.state = str(d.state) ?? v.state;
      v.code = str(d.code);
      v.exitCode = num(d.exitCode);
      v.done = true;
      break;
  }
}

/** An NDJSON chunk: reads only complete lines and returns the leftover half line (to put before the next chunk). */
export function consumeEvents(v: RunView, text: string): string {
  const cut = text.lastIndexOf("\n");
  if (cut < 0) return text;
  for (const line of text.slice(0, cut).split("\n")) {
    const s = line.trim();
    if (!s) continue;
    try {
      applyEvent(v, JSON.parse(s) as FlowEvent);
    } catch {
      // skip broken lines
    }
  }
  return text.slice(cut + 1);
}

export function runCounts(v: RunView) {
  const main = v.nodes.filter((n) => n.branchOf == null);
  return {
    passed: main.filter((n) => n.state === "PASSED" || n.state === "CACHED").length,
    failed: main.filter((n) => isBadState(n.state)).length,
    running: main.filter((n) => n.state === "RUNNING").length,
    total: main.length,
  };
}

export function formatDuration(ms: number): string {
  if (ms < 1000) return `${ms}ms`;
  const s = ms / 1000;
  if (s < 60) return `${s.toFixed(1)}s`;
  return `${Math.floor(s / 60)}m ${Math.floor(s) % 60}s`;
}
