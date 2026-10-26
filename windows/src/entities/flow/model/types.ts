/**
 * The app-side shape of the JSON the flow engine (gitch-flow) writes (tools/gitch-flow/schema/flow-*-v1.schema.json, like the macOS FlowModels.swift).
 * The app only reads what the engine wrote and never judges: verdicts, signatures and rollback always belong to the engine.
 */

/** `list --json` */
export interface FlowList {
  project: string | null;
  trusted: boolean;
  flows: FlowItem[];
  suites: { name: string; use: string; tags: string[] }[];
}

export interface FlowItem {
  name: string;
  description: string | null;
  trigger: string[];
  env: string | null;
  nodes: number;
  last: { runId: string; state: string; finishedAt: string | null; durationMs: number | null; signed: boolean | null } | null;
}

export interface FlowPlanNode {
  id: string;
  title?: string | null;
  block: string;
  needs: string[];
  decision: "run" | "skip" | "rejected";
  reason?: { code?: string | null; message?: string | null } | null;
  outward?: boolean;
  destructive?: boolean;
  branchOf?: string | null;
  group?: string | null;
  run?: string | null;
  undo?: string | null;
  executor?: string;
  src?: string | null;
}

/** What the app uses from `plan <flow> --json` */
export interface FlowPlan {
  flow: string;
  env: string;
  envClass?: string;
  trust: { trusted: boolean; changed?: string[]; approvedAt?: string | null };
  outward: string[];
  gates: string[];
  services: string[];
  warnings: string[];
  estimateMs?: number;
  nodes: FlowPlanNode[];
}

/** Whether a person must confirm once more (an outward action, a block that is hard to undo, a manual approval step) */
export const needsConfirmation = (p: FlowPlan) => p.outward.length > 0 || p.gates.length > 0 || p.nodes.some((n) => n.destructive && n.decision === "run");

/** `run --detach --json` */
export interface FlowDetached {
  runId: string;
  pid?: number;
  runDir: string;
  eventsPath: string;
}

/** One line of `status --all --json` */
export interface FlowRunRow {
  runId: string;
  flow: string;
  env?: string;
  state: string;
  code?: string | null;
  running?: boolean;
  startedAt?: string;
  durationMs?: number | null;
  signed?: boolean;
}

/** `init --dry-run --json` */
export interface FlowInitProposal {
  exists: boolean;
  valid: boolean;
  findings: { kind: string; evidence: string; confidence: string; note?: string | null }[];
  yaml: string;
}

/** `gate status --json` */
export interface FlowGate {
  gate: "OFF" | "OK" | "WARN";
  flow?: string | null;
}

/** One line of events.ndjson */
export interface FlowEvent {
  seq: number;
  at: string;
  type: string;
  node?: string;
  data: Record<string, unknown>;
}

/** The engine's error envelope (`{"schemaVersion":1,"error":{…}}`, the last JSON line on stderr) */
export function parseEngineError(stderr: string): { message: string; code: string | null; action: string | null } | null {
  for (const line of stderr.split("\n").reverse()) {
    const s = line.trim();
    if (!s.startsWith("{")) continue;
    try {
      const o = JSON.parse(s) as { error?: { code?: string; flowCode?: string; message?: string; action?: string } };
      if (o.error?.message) return { message: o.error.message, code: o.error.flowCode ?? o.error.code ?? null, action: o.error.action ?? null };
    } catch {
      // try the next line
    }
  }
  return null;
}
