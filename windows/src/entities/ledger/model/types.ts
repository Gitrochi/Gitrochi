/**
 * The Ledger contract (v0): what the backend answers and the screens read. Times are epoch milliseconds.
 * (macOS: Core/LedgerModels.swift)
 */
export type Ms = number;

export const ledgerStatuses = ["active", "done", "merged", "closed", "dropped", "shelved"] as const;
export type LedgerStatus = (typeof ledgerStatuses)[number];

/** Computed by the backend, never stored; listed in priority order (first match wins) */
export const ledgerVerdicts = ["archived", "needs_human", "expirable", "confirm", "shelved", "pending_merge", "stale", "active"] as const;
export type LedgerVerdict = (typeof ledgerVerdicts)[number];

export const ledgerRoles = ["decision", "implementation", "research", "document", "other"] as const;
export type LedgerRole = (typeof ledgerRoles)[number];

export type LedgerActor = "agent" | "human" | "auto" | "hook";

export interface LedgerSessionLinks {
  repoPath?: string;
  branch?: string;
  worktree?: string;
  pr?: { host: string; number: number; url: string };
  agentId?: string;
  agentSessionId?: string;
  cwd?: string;
}

export interface LedgerSession {
  id: string;
  project: string;
  title: string;
  kind: string;
  role: LedgerRole;
  status: LedgerStatus;
  verdict: LedgerVerdict;
  baseVersion?: string;
  baseCurrent?: string;
  mergedInto?: string;
  touches: string[];
  related: string[];
  chatUrl?: string;
  links: LedgerSessionLinks;
  color: number;
  createdAt: Ms;
  lastAt: Ms;
  lastAgentAt?: Ms;
  ackAt?: Ms;
  snoozeUntil?: Ms;
  archivedAt?: Ms;
  openQuestions: number;
  stream?: { line: string };
  autoContinue?: { enabled: boolean; delaySec: number };
}

export interface LedgerArtifact {
  name: string;
  ssot?: string;
  ver?: string;
}

export interface LedgerEvent {
  id: number;
  sessionId: string;
  ts: Ms;
  type: string;
  actor: LedgerActor;
  summary?: string;
  body?: string;
  version?: string;
  artifacts?: LedgerArtifact[];
  data?: Record<string, unknown>;
  deliveredAt?: Ms;
}

export interface LedgerQuestion {
  id: number;
  sessionId: string;
  text: string;
  state: "open" | "answered" | "dismissed";
  answer?: string;
  answeredBy?: "human" | "auto";
  createdAt: Ms;
  answeredAt?: Ms;
  deliveredAt?: Ms;
}

export interface LedgerBaseline {
  project: string;
  version: string;
  ts: Ms;
  source: "tag" | "folder" | "registered" | "release" | "inferred";
  note?: string;
  bySession?: string;
}

export interface LedgerStreamCycle {
  sessionId: string;
  line: string;
  version: string;
  state: "applied" | "active" | "skipped";
  syncedAt?: Ms;
  appliedAt?: Ms;
  releasedBy?: string;
  eventIds: number[];
}

export interface LedgerOverlap {
  a: string;
  b: string;
  paths: string[];
  kind: "same" | "coupled";
}

export type LedgerPromptKind = "stop_question" | "ask_user_question" | "exit_plan_mode" | "permission";

export interface LedgerPendingPrompt {
  id: number;
  sessionId?: string;
  agentId?: string;
  kind: LedgerPromptKind;
  payload: Record<string, unknown>;
  createdAt: Ms;
  /** 0 = no automatic answer for this prompt (a person chose "Not automatically this time") */
  deadline: Ms;
  state: "waiting" | "answered" | "auto" | "released" | "expired";
  answer?: Record<string, unknown>;
  answeredBy?: "human" | "auto";
}

export interface LedgerAttention {
  questions: number;
  tidy: number;
  decide: number;
  autoReview: number;
  total: number;
}

export interface LedgerProject {
  key: string;
  name: string;
  open: number;
}

export interface LedgerState {
  schemaVersion: 1;
  rev: number;
  now: Ms;
  projects: LedgerProject[];
  baselines: LedgerBaseline[];
  sessions: LedgerSession[];
  questions: LedgerQuestion[];
  streams: LedgerStreamCycle[];
  overlaps: LedgerOverlap[];
  pendingPrompts: LedgerPendingPrompt[];
  attention: LedgerAttention;
  hiddenBefore: number;
}

export interface LedgerGraphNode {
  id: string;
  lane: number;
  ts: Ms;
  color: number;
  kind: "baseline" | "start" | "event" | "merge" | "release" | "end";
  sessionId?: string;
  version?: string;
  label?: string;
}

export interface LedgerGraphEdge {
  from: string;
  to: string;
  kind: "trunk" | "branch" | "merge" | "handoff";
  color: number;
}

export interface LedgerGraph {
  lanes: number;
  nodes: LedgerGraphNode[];
  edges: LedgerGraphEdge[];
  from: Ms;
  to: Ms;
}

// MARK: Method arguments and answers

/** The period the state and the graph cover; "all" has no lower bound */
export const ledgerRanges = ["7d", "30d", "all"] as const;
export type LedgerRange = (typeof ledgerRanges)[number];

export interface LedgerInfo {
  schemaVersion: number;
  dbPath: string;
  rev: number;
  enabled: boolean;
}

export interface LedgerSessionDetail {
  session: LedgerSession;
  events: LedgerEvent[];
  questions: LedgerQuestion[];
  overlaps: LedgerOverlap[];
  cycles: LedgerStreamCycle[];
}

export type LedgerSearchKind = "session" | "question" | "event" | "baseline";

export interface LedgerSearchHit {
  kind: LedgerSearchKind;
  id: string;
  sessionId?: string;
  title: string;
  snippet: string;
}

export interface LedgerImportResult {
  index: number;
  ok: boolean;
  duplicate: boolean;
  error?: string;
  sessionId?: string;
}

/** A person's operations; each one is an event with actor "human" */
export type LedgerHumanAction = "ack" | "unack" | "archive" | "unarchive" | "set_status" | "answer" | "dismiss" | "snooze" | "shelve" | "link" | "message";

/** `human` arguments besides `action` and `sessionId` */
export interface LedgerHumanArgs {
  status?: LedgerStatus;
  version?: string;
  questionId?: number;
  promptId?: number;
  text?: string;
  /** snooze: until when the session counts as active (0 clears) */
  until?: Ms;
}

export interface LedgerHumanRequest extends LedgerHumanArgs {
  action: LedgerHumanAction;
  sessionId: string;
}

export type LedgerPromptAnswer =
  | { action: "reply"; text: string }
  | { action: "allow" }
  | { action: "deny" }
  | { action: "release" }
  | { action: "hold" };

/** Each method's arguments and answer, so `LedgerBackend.call` is typed end to end */
export interface LedgerMethods {
  info: { args: Record<string, never>; result: LedgerInfo };
  rev: { args: Record<string, never>; result: { rev: number } };
  state: { args: { project?: string; range?: LedgerRange }; result: LedgerState };
  session: { args: { id: string }; result: LedgerSessionDetail };
  graph: { args: { project: string; range?: LedgerRange }; result: LedgerGraph };
  search: { args: { query: string; project?: string; limit?: number }; result: { hits: LedgerSearchHit[] } };
  import: { args: { text: string; project?: string }; result: { results: LedgerImportResult[] } };
  human: { args: LedgerHumanRequest; result: { ok: boolean; rev: number } };
  prompt_answer: { args: { id: number; answer: LedgerPromptAnswer }; result: { ok: boolean } };
  backup: { args: Record<string, never>; result: { path: string } };
}
export type LedgerMethod = keyof LedgerMethods;
