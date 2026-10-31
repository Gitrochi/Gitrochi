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
  /** Baselines newer than baseCurrent (the core adds it to v0) */
  behind?: number;
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
  /** The session settled the question itself (the core adds it to v0) */
  resolvedBy?: "agent";
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
  /** Prompts auto-continue answered that nobody has reviewed yet (the core adds this list to v0) */
  autoReview?: LedgerPendingPrompt[];
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
  /** The event type behind the node (the core adds it to v0); a question is drawn as a diamond */
  type?: string;
  /** The core's row, 0 = newest; when every node has one it sets the order */
  row?: number;
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
  /** set_status merged: the baseline the result went into */
  into?: string;
  questionId?: number;
  /** answer: the person's answer */
  answer?: string;
  /** message: a note the session reads with its next report */
  text?: string;
  /** snooze: until when the session counts as active (0 clears) */
  until?: Ms;
}

export interface LedgerHumanRequest extends LedgerHumanArgs {
  action: LedgerHumanAction;
  sessionId: string;
}

/**
 * A person's answer to a waiting prompt, stored as given for the hook handler; the same shapes as macOS
 * (LedgerPromptReply): a typed reply, AskUserQuestion choices (question → label), allow or deny, leave it to the
 * agent's terminal, or no automatic answer this time.
 */
export type LedgerPromptAnswer =
  | { text: string }
  | { answers: Record<string, string> }
  | { decision: "allow" }
  | { decision: "deny"; message?: string }
  | { release: true }
  | { hold: true };

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
  /** `ok` is false when the prompt no longer waits (auto-continue answered first) */
  prompt_answer: { args: { id: number; answer: LedgerPromptAnswer }; result: { ok: boolean; rev?: number; state?: LedgerPendingPrompt["state"] } };
  /** Marks automatic answers as seen; they leave the Inbox */
  prompt_review: { args: { id: number } | { all: true }; result: { ok: boolean; rev: number; reviewed: number } };
  backup: { args: Record<string, never>; result: { path: string } };
}
export type LedgerMethod = keyof LedgerMethods;
