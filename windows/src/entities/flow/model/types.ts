/**
 * 흐름 엔진(gitch-flow)이 내는 JSON 의 앱 쪽 모양(tools/gitch-flow/schema/flow-*-v1.schema.json · 맥 FlowModels.swift 와 같다).
 * 앱은 엔진이 낸 것을 읽기만 하고 판정하지 않는다 — 판정 · 서명 · 되돌림은 언제나 엔진이 한다.
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

/** `plan <흐름> --json` 중 앱이 쓰는 것 */
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

/** 사람이 한 번 더 확인해야 하는지(바깥 동작 · 되돌리기 어려운 블록 · 사람 확인 단계) */
export const needsConfirmation = (p: FlowPlan) => p.outward.length > 0 || p.gates.length > 0 || p.nodes.some((n) => n.destructive && n.decision === "run");

/** `run --detach --json` */
export interface FlowDetached {
  runId: string;
  pid?: number;
  runDir: string;
  eventsPath: string;
}

/** `status --all --json` 의 한 줄 */
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

/** events.ndjson 한 줄 */
export interface FlowEvent {
  seq: number;
  at: string;
  type: string;
  node?: string;
  data: Record<string, unknown>;
}

/** 엔진 오류 봉투(`{"schemaVersion":1,"error":{…}}`, 표준오류의 마지막 JSON 줄) */
export function parseEngineError(stderr: string): { message: string; code: string | null; action: string | null } | null {
  for (const line of stderr.split("\n").reverse()) {
    const s = line.trim();
    if (!s.startsWith("{")) continue;
    try {
      const o = JSON.parse(s) as { error?: { code?: string; flowCode?: string; message?: string; action?: string } };
      if (o.error?.message) return { message: o.error.message, code: o.error.flowCode ?? o.error.code ?? null, action: o.error.action ?? null };
    } catch {
      // 다음 줄
    }
  }
  return null;
}
