import type { LedgerPendingPrompt, LedgerQuestion, LedgerSession } from "@/entities/ledger";

/** Contract objects for the Ledger tests: neutral values, overridden per case */
export const session = (over: Partial<LedgerSession> = {}): LedgerSession => ({
  id: "S1031-01", project: "atlas", title: "Session", kind: "decision", role: "decision", status: "active", verdict: "active",
  touches: [], related: [], links: {}, color: 1, createdAt: 0, lastAt: 0, openQuestions: 0, ...over,
});

export const question = (over: Partial<LedgerQuestion> = {}): LedgerQuestion => ({ id: 1, sessionId: "S1031-01", text: "Which one?", state: "open", createdAt: 0, ...over });

export const prompt = (over: Partial<LedgerPendingPrompt> = {}): LedgerPendingPrompt => ({ id: 1, kind: "stop_question", payload: {}, createdAt: 0, deadline: 1, state: "waiting", ...over });

// MARK: Contract shapes

export type Spec = string | Spec[] | { [key: string]: Spec } | ((value: unknown) => boolean);
export const enumOf = (...values: unknown[]) => (v: unknown) => values.includes(v);
const record = (v: unknown) => !!v && typeof v === "object" && !Array.isArray(v);

function check(value: unknown, spec: Spec, path: string, errors: string[], strict: boolean) {
  if (typeof spec === "function") {
    if (!spec(value)) errors.push(`${path}: unexpected ${JSON.stringify(value)}`);
  } else if (typeof spec === "string") {
    if (typeof value !== spec) errors.push(`${path}: ${typeof value}, not ${spec}`);
  } else if (Array.isArray(spec)) {
    if (!Array.isArray(value)) errors.push(`${path}: not an array`);
    else value.forEach((item, i) => check(item, spec[0], `${path}[${i}]`, errors, strict));
  } else if (!record(value)) errors.push(`${path}: not an object`);
  else {
    const object = value as Record<string, unknown>;
    for (const [key, inner] of Object.entries(spec)) {
      const name = key.replace(/\?$/, "");
      if (object[name] === undefined) { if (!key.endsWith("?")) errors.push(`${path}.${name}: missing`); }
      else check(object[name], inner, `${path}.${name}`, errors, strict);
    }
    if (!strict) return;
    const known = new Set(Object.keys(spec).map((k) => k.replace(/\?$/, "")));
    for (const key of Object.keys(object)) if (!known.has(key)) errors.push(`${path}.${key}: not in the contract`);
  }
}

/**
 * Where a value differs from a contract shape. Strict (the demo): every key the contract names and nothing else. Not
 * strict (the core): every key the screens read, with the right type; the core may add fields the screens ignore.
 */
export function shapeErrors(value: unknown, spec: Spec, strict = true): string[] {
  const errors: string[] = [];
  check(value, spec, "$", errors, strict);
  return errors;
}

const sessionShape: Spec = {
  id: "string", project: "string", title: "string", kind: "string", role: enumOf("decision", "implementation", "research", "document", "other"),
  status: enumOf("active", "done", "merged", "closed", "dropped", "shelved"), verdict: enumOf("archived", "needs_human", "expirable", "confirm", "shelved", "pending_merge", "stale", "active"), "baseVersion?": "string", "baseCurrent?": "string", "mergedInto?": "string",
  touches: ["string"], related: ["string"], "chatUrl?": "string",
  links: { "repoPath?": "string", "branch?": "string", "worktree?": "string", "pr?": { host: "string", number: "number", url: "string" }, "agentId?": "string", "agentSessionId?": "string", "cwd?": "string" },
  color: "number", createdAt: "number", lastAt: "number", "lastAgentAt?": "number", "ackAt?": "number", "snoozeUntil?": "number", "archivedAt?": "number", openQuestions: "number",
  "stream?": { line: "string" }, "autoContinue?": { enabled: "boolean", delaySec: "number" },
};
const eventShape: Spec = { id: "number", sessionId: "string", ts: "number", type: "string", actor: enumOf("agent", "human", "auto", "hook"), "summary?": "string", "body?": "string", "version?": "string", "artifacts?": [{ name: "string", "ssot?": "string", "ver?": "string" }], "data?": record, "deliveredAt?": "number" };
const questionShape: Spec = { id: "number", sessionId: "string", text: "string", state: enumOf("open", "answered", "dismissed"), "answer?": "string", "answeredBy?": enumOf("human", "auto"), createdAt: "number", "answeredAt?": "number", "deliveredAt?": "number" };
const baselineShape: Spec = { project: "string", version: "string", ts: "number", source: enumOf("tag", "folder", "registered", "release", "inferred"), "note?": "string", "bySession?": "string" };
const cycleShape: Spec = { sessionId: "string", line: "string", version: "string", state: enumOf("applied", "active", "skipped"), "syncedAt?": "number", "appliedAt?": "number", "releasedBy?": "string", eventIds: ["number"] };
const overlapShape: Spec = { a: "string", b: "string", paths: ["string"], kind: enumOf("same", "coupled") };
const promptShape: Spec = { id: "number", "sessionId?": "string", "agentId?": "string", kind: enumOf("stop_question", "ask_user_question", "exit_plan_mode", "permission"), payload: record, createdAt: "number", deadline: "number", state: enumOf("waiting", "answered", "auto", "released", "expired"), "answer?": record, "answeredBy?": enumOf("human", "auto") };
const stateShape: Spec = {
  schemaVersion: enumOf(1), rev: "number", now: "number", projects: [{ key: "string", name: "string", open: "number" }], baselines: [baselineShape], sessions: [sessionShape], questions: [questionShape],
  streams: [cycleShape], overlaps: [overlapShape], pendingPrompts: [promptShape], "autoReview?": [promptShape], attention: { questions: "number", tidy: "number", decide: "number", autoReview: "number", total: "number" }, hiddenBefore: "number",
};
const graphShape: Spec = {
  lanes: "number", from: "number", to: "number",
  nodes: [{ id: "string", lane: "number", ts: "number", color: "number", kind: enumOf("baseline", "start", "event", "merge", "release", "end"), "type?": "string", "sessionId?": "string", "version?": "string", "label?": "string" }],
  edges: [{ from: "string", to: "string", kind: enumOf("trunk", "branch", "merge", "handoff"), color: "number" }],
};

/** The contract's shapes as the Windows screens read them (entities/ledger/model/types.ts) */
export const specs = {
  session: sessionShape, event: eventShape, question: questionShape, baseline: baselineShape, cycle: cycleShape, overlap: overlapShape, prompt: promptShape,
  state: stateShape, graph: graphShape,
  detail: { session: sessionShape, events: [eventShape], questions: [questionShape], overlaps: [overlapShape], cycles: [cycleShape] } as Spec,
  info: { schemaVersion: "number", dbPath: "string", rev: "number", enabled: "boolean" } as Spec,
  search: { hits: [{ kind: enumOf("session", "question", "event", "baseline"), id: "string", "sessionId?": "string", title: "string", snippet: "string" }] } as Spec,
  importResults: { results: [{ index: "number", ok: "boolean", duplicate: "boolean", "error?": "string", "sessionId?": "string" }] } as Spec,
  backup: { path: "string" } as Spec,
};
