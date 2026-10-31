import { afterEach, describe, expect, it, vi } from "vitest";
import { DemoLedgerBackend, type LedgerBackend, LedgerError, ledgerFailure, ledgerResult, type LedgerMethod, type LedgerMethods, LedgerStore, ledgerVerdicts, nativeLedgerBackend, plotLedgerGraph } from "@/entities/ledger";
import { ipc } from "@/shared/api";

const MIN = 60_000, HOUR = 60 * MIN, DAY = 24 * HOUR;
const START = Date.UTC(2026, 9, 31, 9);

/** A demo on a clock the test moves */
function demo(options: { large?: boolean; repoPath?: string } = {}) {
  let now = START;
  const backend = new DemoLedgerBackend({ now: () => now, lively: false, ...options });
  return { backend, advance: (ms: number) => (now += ms), now: () => now };
}

// MARK: Contract shapes — every key the contract names, nothing else

type Spec = string | Spec[] | { [key: string]: Spec } | ((value: unknown) => boolean);
const enumOf = (...values: unknown[]) => (v: unknown) => values.includes(v);
const record = (v: unknown) => !!v && typeof v === "object" && !Array.isArray(v);

function check(value: unknown, spec: Spec, path: string, errors: string[]) {
  if (typeof spec === "function") {
    if (!spec(value)) errors.push(`${path}: unexpected ${JSON.stringify(value)}`);
  } else if (typeof spec === "string") {
    if (typeof value !== spec) errors.push(`${path}: ${typeof value}, not ${spec}`);
  } else if (Array.isArray(spec)) {
    if (!Array.isArray(value)) errors.push(`${path}: not an array`);
    else value.forEach((item, i) => check(item, spec[0], `${path}[${i}]`, errors));
  } else if (!record(value)) errors.push(`${path}: not an object`);
  else {
    const object = value as Record<string, unknown>;
    for (const [key, inner] of Object.entries(spec)) {
      const name = key.replace(/\?$/, "");
      if (object[name] === undefined) { if (!key.endsWith("?")) errors.push(`${path}.${name}: missing`); }
      else check(object[name], inner, `${path}.${name}`, errors);
    }
    const known = new Set(Object.keys(spec).map((k) => k.replace(/\?$/, "")));
    for (const key of Object.keys(object)) if (!known.has(key)) errors.push(`${path}.${key}: not in the contract`);
  }
}
const expectShape = (value: unknown, spec: Spec) => {
  const errors: string[] = [];
  check(value, spec, "$", errors);
  expect(errors.slice(0, 10)).toEqual([]);
};

const session: Spec = {
  id: "string", project: "string", title: "string", kind: "string", role: enumOf("decision", "implementation", "research", "document", "other"),
  status: enumOf("active", "done", "merged", "closed", "dropped", "shelved"), verdict: enumOf(...ledgerVerdicts), "baseVersion?": "string", "baseCurrent?": "string", "mergedInto?": "string",
  touches: ["string"], related: ["string"], "chatUrl?": "string",
  links: { "repoPath?": "string", "branch?": "string", "worktree?": "string", "pr?": { host: "string", number: "number", url: "string" }, "agentId?": "string", "agentSessionId?": "string", "cwd?": "string" },
  color: "number", createdAt: "number", lastAt: "number", "lastAgentAt?": "number", "ackAt?": "number", "snoozeUntil?": "number", "archivedAt?": "number", openQuestions: "number",
  "stream?": { line: "string" }, "autoContinue?": { enabled: "boolean", delaySec: "number" },
};
const event: Spec = { id: "number", sessionId: "string", ts: "number", type: "string", actor: enumOf("agent", "human", "auto", "hook"), "summary?": "string", "body?": "string", "version?": "string", "artifacts?": [{ name: "string", "ssot?": "string", "ver?": "string" }], "data?": record, "deliveredAt?": "number" };
const question: Spec = { id: "number", sessionId: "string", text: "string", state: enumOf("open", "answered", "dismissed"), "answer?": "string", "answeredBy?": enumOf("human", "auto"), createdAt: "number", "answeredAt?": "number", "deliveredAt?": "number" };
const baseline: Spec = { project: "string", version: "string", ts: "number", source: enumOf("tag", "folder", "registered", "release", "inferred"), "note?": "string", "bySession?": "string" };
const cycle: Spec = { sessionId: "string", line: "string", version: "string", state: enumOf("applied", "active", "skipped"), "syncedAt?": "number", "appliedAt?": "number", "releasedBy?": "string", eventIds: ["number"] };
const overlap: Spec = { a: "string", b: "string", paths: ["string"], kind: enumOf("same", "coupled") };
const prompt: Spec = { id: "number", "sessionId?": "string", "agentId?": "string", kind: enumOf("stop_question", "ask_user_question", "exit_plan_mode", "permission"), payload: record, createdAt: "number", deadline: "number", state: enumOf("waiting", "answered", "auto", "released", "expired"), "answer?": record, "answeredBy?": enumOf("human", "auto") };
const state: Spec = {
  schemaVersion: enumOf(1), rev: "number", now: "number", projects: [{ key: "string", name: "string", open: "number" }], baselines: [baseline], sessions: [session], questions: [question],
  streams: [cycle], overlaps: [overlap], pendingPrompts: [prompt], "autoReview?": [prompt], attention: { questions: "number", tidy: "number", decide: "number", autoReview: "number", total: "number" }, hiddenBefore: "number",
};
const graph: Spec = {
  lanes: "number", from: "number", to: "number",
  nodes: [{ id: "string", lane: "number", ts: "number", color: "number", kind: enumOf("baseline", "start", "event", "merge", "release", "end"), "type?": "string", "sessionId?": "string", "version?": "string", "label?": "string" }],
  edges: [{ from: "string", to: "string", kind: enumOf("trunk", "branch", "merge", "handoff"), color: "number" }],
};

describe("Ledger demo backend: contract", () => {
  it("answers every method in the contract's shape", async () => {
    const { backend } = demo();
    const s = await backend.call("state", {});
    expectShape(s, state);
    expectShape(await backend.call("info", {}), { schemaVersion: "number", dbPath: "string", rev: "number", enabled: "boolean" });
    expectShape(await backend.call("rev", {}), { rev: "number" });
    for (const one of s.sessions) expectShape(await backend.call("session", { id: one.id }), { session, events: [event], questions: [question], overlaps: [overlap], cycles: [cycle] });
    for (const project of s.projects) for (const range of ["7d", "30d", "all"] as const) expectShape(await backend.call("graph", { project: project.key, range }), graph);
    expectShape(await backend.call("search", { query: "cache" }), { hits: [{ kind: enumOf("session", "question", "event", "baseline"), id: "string", "sessionId?": "string", title: "string", snippet: "string" }] });
    expectShape(await backend.call("import", { text: "{\"event\":\"note\"}" }), { results: [{ index: "number", ok: "boolean", duplicate: "boolean", "error?": "string", "sessionId?": "string" }] });
    expectShape(await backend.call("human", { action: "ack", sessionId: s.sessions[0].id }), { ok: "boolean", rev: "number" });
    expectShape(await backend.call("prompt_answer", { id: s.pendingPrompts.find((p) => p.state === "waiting")!.id, answer: { hold: true } }), { ok: "boolean", "rev?": "number", "state?": "string" });
    expectShape(await backend.call("prompt_review", { all: true }), { ok: "boolean", rev: "number", reviewed: "number" });
    expectShape(await backend.call("backup", {}), { path: "string" });
  });

  it("has two projects, every verdict, a stream with three cycles, overlaps and waiting prompts", async () => {
    const { backend } = demo();
    const s = await backend.call("state", { range: "all" });
    expect(s.projects.map((p) => p.key)).toEqual(["atlas", "harbor"]);
    expect(new Set(s.sessions.map((x) => x.verdict))).toEqual(new Set(ledgerVerdicts));
    const stream = s.sessions.find((x) => x.stream)!;
    expect(s.streams.filter((c) => c.sessionId === stream.id).map((c) => [c.version, c.state])).toEqual([["1.4.2", "active"], ["1.4.1", "applied"], ["1.4.0", "skipped"]]);
    expect(s.streams.find((c) => c.version === "1.4.2")!.releasedBy).toBe(s.sessions.find((x) => x.title === "Cache invalidation design")!.id);
    expect(s.overlaps.map((o) => o.kind).sort()).toEqual(["coupled", "same"]);
    expect(s.pendingPrompts.map((p) => p.kind).sort()).toEqual(["ask_user_question", "exit_plan_mode", "permission", "stop_question"]);
    expect(s.pendingPrompts.every((p) => p.state === "waiting" && p.deadline > s.now)).toBe(true);
    expect(s.autoReview!.map((p) => [p.state, p.answeredBy])).toEqual([["auto", "auto"], ["auto", "auto"]]);
    expect(s.questions.every((q) => q.state === "open")).toBe(true);
    // payloads in auto-continue's shape
    expect(s.pendingPrompts.every((p) => p.payload.schemaVersion === 1 && typeof p.payload.question === "string")).toBe(true);
    expect(s.attention).toEqual({ questions: 3, tidy: 4, decide: 3, autoReview: 2, total: 12 });
    expect(s.sessions.filter((x) => x.links.pr).every((x) => new URL(x.links.pr!.url).hostname === "example.com")).toBe(true);
  });

  it("uses only neutral names and example.com addresses", async () => {
    const { backend } = demo();
    const text = JSON.stringify(backend.world);
    for (const url of text.match(/https?:\/\/[^"\s)]+/g) ?? []) expect(new URL(url).hostname).toBe("example.com");
    expect(text).not.toMatch(/\/Users\/|\/home\/|C:\\\\Users/i);
  });

  it("binds the first project to the open repository", async () => {
    const { backend } = demo({ repoPath: "D:\\Code\\my-app\\" });
    const s = await backend.call("state", {});
    expect(s.sessions.filter((x) => x.project === "atlas" && x.links.repoPath).every((x) => x.links.repoPath === "D:/Code/my-app")).toBe(true);
  });

  it("hides quiet sessions older than the period and counts them", async () => {
    const { backend } = demo();
    const week = await backend.call("state", { range: "7d" }), all = await backend.call("state", { range: "all" });
    // as the core: only archived sessions older than the period are hidden
    expect(week.hiddenBefore).toBe(1);
    expect(all.hiddenBefore).toBe(0);
    expect(all.sessions.length - week.sessions.length).toBe(1);
    expect(week.sessions.some((x) => x.verdict === "shelved")).toBe(true);
    expect(week.sessions.some((x) => x.verdict === "needs_human")).toBe(true);
    const graph = await backend.call("graph", { project: "atlas", range: "7d" });
    expect(graph.from).toBeLessThanOrEqual(START - 7 * DAY);
    expect(new Set(graph.edges.map((e) => e.kind))).toEqual(new Set(["trunk", "branch", "merge", "handoff"]));
    expect(graph.nodes.filter((n) => n.lane === 0).every((n) => n.kind === "baseline" || n.kind === "release")).toBe(true);
    const ids = new Set(graph.nodes.map((n) => n.id));
    expect(graph.edges.every((e) => ids.has(e.from) && ids.has(e.to))).toBe(true);
  });

  it("reports unknown sessions, projects and methods as Ledger errors", async () => {
    const { backend } = demo();
    await expect(backend.call("session", { id: "nope" })).rejects.toMatchObject({ code: "NOT_FOUND" });
    await expect(backend.call("graph", { project: "nope" })).rejects.toBeInstanceOf(LedgerError);
    await expect(backend.call("nope" as LedgerMethod, {} as never)).rejects.toMatchObject({ code: "UNKNOWN_METHOD" });
  });
});

describe("Ledger demo backend: a person's operations", () => {
  const find = async (backend: LedgerBackend, title: string) => (await backend.call("state", { range: "all" })).sessions.find((x) => x.title === title)!;

  it("bumps rev and changes the verdict", async () => {
    const { backend } = demo();
    const { rev } = await backend.call("rev", {});
    const api = await find(backend, "Export the API reference");
    expect(api.verdict).toBe("confirm");
    expect((await backend.call("human", { action: "ack", sessionId: api.id })).rev).toBe(rev + 1);
    expect((await find(backend, "Export the API reference")).verdict).toBe("expirable");
    await backend.call("human", { action: "archive", sessionId: api.id });
    expect((await find(backend, "Export the API reference")).verdict).toBe("archived");
    await backend.call("human", { action: "unarchive", sessionId: api.id });
    await backend.call("human", { action: "unack", sessionId: api.id });
    expect((await find(backend, "Export the API reference")).verdict).toBe("confirm");
    const detail = await backend.call("session", { id: api.id });
    expect(detail.events.filter((e) => e.actor === "human").map((e) => e.type)).toEqual(["ack", "archive", "unarchive", "unack"]);
  });

  it("treats a status a person chooses as confirmed, and active as a fresh start", async () => {
    const { backend } = demo();
    const spike = await find(backend, "Spike: warm the cache on deploy");
    expect(spike.verdict).toBe("pending_merge");
    await backend.call("human", { action: "set_status", sessionId: spike.id, status: "merged" });
    const merged = await find(backend, spike.title);
    expect([merged.verdict, merged.mergedInto]).toEqual(["expirable", "1.4.2"]);
    await backend.call("human", { action: "set_status", sessionId: spike.id, status: "active" });
    const active = await find(backend, spike.title);
    expect([active.verdict, active.ackAt, active.mergedInto]).toEqual(["active", undefined, undefined]);
    await expect(backend.call("human", { action: "set_status", sessionId: spike.id, status: "bogus" as never })).rejects.toMatchObject({ code: "INVALID_ARGUMENT" });
    await backend.call("human", { action: "set_status", sessionId: spike.id, status: "merged", into: "1.4.1" });
    expect((await find(backend, spike.title)).mergedInto).toBe("1.4.1");
  });

  it("answers and dismisses questions once, and snoozes stale sessions", async () => {
    const { backend } = demo();
    const s = await backend.call("state", {});
    const [first, second] = s.questions.filter((q) => q.state === "open" && q.sessionId === s.sessions.find((x) => x.title.startsWith("Retry"))!.id);
    await backend.call("human", { action: "answer", sessionId: first.sessionId, questionId: first.id, answer: "  Three times.  " });
    await expect(backend.call("human", { action: "answer", sessionId: first.sessionId, questionId: first.id, answer: "again" })).rejects.toMatchObject({ code: "CONFLICT" });
    expect((await find(backend, "Retry policy for the sign-in service")).verdict).toBe("needs_human");
    await backend.call("human", { action: "dismiss", sessionId: second.sessionId, questionId: second.id });
    expect((await find(backend, "Retry policy for the sign-in service")).verdict).toBe("active");
    const detail = await backend.call("session", { id: first.sessionId });
    expect(detail.questions.find((q) => q.id === first.id)).toMatchObject({ state: "answered", answer: "Three times.", answeredBy: "human" });
    const flags = await find(backend, "Clean up old feature flags");
    expect(flags.verdict).toBe("stale");
    await backend.call("human", { action: "snooze", sessionId: flags.id, until: START + 72 * HOUR });
    expect((await find(backend, flags.title)).verdict).toBe("active");
    await backend.call("human", { action: "snooze", sessionId: flags.id, until: 0 });
    expect((await find(backend, flags.title)).verdict).toBe("stale");
  });

  it("reviews automatic answers with prompt_review, one or all, and takes messages for the session", async () => {
    const { backend } = demo();
    const s = await backend.call("state", {});
    const [first, second] = s.autoReview!;
    await backend.call("human", { action: "message", sessionId: first.sessionId!, text: "Run the full suite next time." });
    expect(await backend.call("prompt_review", { id: first.id })).toMatchObject({ ok: true, reviewed: 1 });
    expect((await backend.call("state", {})).attention.autoReview).toBe(1);
    expect(await backend.call("prompt_review", { all: true })).toMatchObject({ ok: true, reviewed: 1 });
    const after = await backend.call("state", {});
    expect([after.attention.autoReview, after.autoReview!.length]).toEqual([0, 0]);
    expect(second.state).toBe("auto");
    const detail = await backend.call("session", { id: first.sessionId! });
    expect(detail.events.at(-1)).toMatchObject({ type: "message", actor: "human", body: "Run the full suite next time." });
    await expect(backend.call("prompt_review", { id: 999 })).rejects.toMatchObject({ code: "NOT_FOUND" });
  });
});

describe("Ledger demo backend: waiting prompts", () => {
  it("answers a prompt automatically once its deadline passes, never a plan", async () => {
    const { backend, advance } = demo();
    const before = await backend.call("state", {});
    advance(46_000);
    const { rev } = await backend.call("rev", {});
    expect(rev).toBe(before.rev + 1);
    const after = await backend.call("state", {});
    const question = after.autoReview!.find((p) => p.kind === "stop_question")!;
    expect(question).toMatchObject({ state: "auto", answeredBy: "auto", answer: { type: "reply", text: "Yes, go ahead with the safest option." } });
    expect(after.attention.autoReview).toBe(before.attention.autoReview + 1);
    advance(10 * MIN);
    const late = await backend.call("state", {});
    expect(late.pendingPrompts).toEqual([]);
    expect(late.autoReview!.some((p) => p.kind === "exit_plan_mode")).toBe(false);
    const ask = late.autoReview!.find((p) => p.kind === "ask_user_question" && p.id === before.pendingPrompts.find((x) => x.kind === "ask_user_question")!.id)!;
    expect(ask.answer).toMatchObject({ type: "answers", answers: { "Which cache keys should the migration rebuild first?": "Session keys" } });
    const detail = await backend.call("session", { id: ask.sessionId! });
    expect(detail.events.filter((e) => e.type === "auto_reply").at(-1)).toMatchObject({ actor: "auto", data: { promptId: ask.id, kind: "ask_user_question" } });
  });

  it("takes a person's answer, a hold or a release while the prompt waits, and says when it no longer does", async () => {
    const { backend, advance } = demo();
    const waiting = (await backend.call("state", {})).pendingPrompts;
    const byKind = (kind: string) => waiting.find((p) => p.kind === kind)!;
    expect(await backend.call("prompt_answer", { id: byKind("stop_question").id, answer: { text: "Yes" } })).toMatchObject({ ok: true, state: "answered" });
    expect(await backend.call("prompt_answer", { id: byKind("permission").id, answer: { hold: true } })).toMatchObject({ ok: true });
    expect(await backend.call("prompt_answer", { id: byKind("exit_plan_mode").id, answer: { release: true } })).toMatchObject({ ok: true });
    expect(await backend.call("prompt_answer", { id: byKind("stop_question").id, answer: { decision: "deny" } })).toMatchObject({ ok: false, state: "answered" });
    await expect(backend.call("prompt_answer", { id: byKind("ask_user_question").id, answer: "yes" as never })).rejects.toMatchObject({ code: "INVALID_ARGUMENT" });
    advance(DAY);
    const s = await backend.call("state", {});
    expect(s.pendingPrompts.map((p) => p.kind)).toEqual([]);
    // the unanswered question was answered automatically; the two older automatic answers still wait for review
    expect(s.autoReview!.map((p) => p.id)).toEqual([byKind("ask_user_question").id, 5, 6]);
    expect(backend.world.prompts.find((p) => p.id === byKind("permission").id)).toMatchObject({ state: "answered", answer: { hold: true }, answeredBy: "human" });
  });
});

describe("Ledger demo backend: import and search", () => {
  it("imports each pasted report on its own and recognises duplicates", async () => {
    const { backend } = demo();
    const block = (json: string) => "```ledger\n" + json + "\n```";
    const text = [block("{\"event\":\"start\",\"session\":\"S1101-01\",\"project\":\"harbor\",\"title\":\"Import check\",\"kind\":\"research\"}"), block("{\"event\":\"question\",\"session\":\"S1101-01\",\"question\":\"Ship it?\"}"), block("not json"), block("{\"event\":\"teleport\"}"), block("{\"event\":\"start\",\"title\":\"No project\"}"), block("{\"event\":\"sync\",\"session\":\"S1101-01\"}")].join("\n\ntext between\n\n");
    const { rev } = await backend.call("rev", {});
    const { results } = await backend.call("import", { text });
    expect(results.map((r) => [r.index, r.ok, r.duplicate, r.error ?? null])).toEqual([[0, true, false, null], [1, true, false, null], [2, false, false, "Not a JSON report"], [3, false, false, "Unknown event \"teleport\""], [4, false, false, "A new session needs a project"], [5, false, false, "\"sync\" needs a version"]]);
    expect((await backend.call("rev", {})).rev).toBe(rev + 1);
    const again = await backend.call("import", { text: block("{\"question\":\"Ship it?\",\"session\":\"S1101-01\",\"event\":\"question\"}") });
    expect(again.results).toEqual([{ index: 0, ok: true, duplicate: true, sessionId: "S1101-01" }]);
    const s = (await backend.call("state", {})).sessions.find((x) => x.id === "S1101-01")!;
    expect([s.project, s.role, s.verdict, s.openQuestions]).toEqual(["harbor", "research", "needs_human", 1]);
    const lines = await backend.call("import", { text: "{\"event\":\"note\",\"session\":\"S1101-01\"}\nnoise\n{\"event\":\"done\",\"session\":\"S1101-01\"}", project: "harbor" });
    expect(lines.results.map((r) => r.ok)).toEqual([true, true]);
  });

  it("finds sessions, questions, report bodies and baselines, within a project and a limit", async () => {
    const { backend } = demo();
    const kinds = async (query: string, project?: string) => (await backend.call("search", { query, ...(project ? { project } : {}) })).hits.map((h) => h.kind);
    expect(await kinds("Retry policy")).toContain("session");
    expect(await kinds("503")).toContain("question");
    expect(await kinds("1,204 keys")).toEqual(["event"]);
    expect(await kinds("1.4.2")).toContain("baseline");
    expect(await kinds("Retry policy", "harbor")).toEqual([]);
    expect((await backend.call("search", { query: "e", limit: 5 })).hits).toHaveLength(5);
    expect((await backend.call("search", { query: "   " })).hits).toEqual([]);
    const body = (await backend.call("search", { query: "1,204 keys" })).hits[0];
    expect(body.snippet).toContain("1,204 keys");
    expect(body.snippet.length).toBeLessThanOrEqual(92);
    // snippets are one line of text, without Markdown marks
    const table = (await backend.call("search", { query: "Retry-After" })).hits.find((h) => h.kind === "event")!;
    expect(table.snippet).toContain("Retry-After");
    expect(table.snippet).not.toMatch(/[|#*`]|---|\n/);
  });
});

describe("Ledger demo backend: large data", () => {
  it("holds 1,000 sessions and 50,000 events and answers every view quickly", async () => {
    const t0 = performance.now();
    const { backend } = demo({ large: true });
    const built = performance.now() - t0;
    expect(backend.world.sessions).toHaveLength(1000);
    expect(backend.world.events).toHaveLength(50_000);
    let t = performance.now();
    const all = await backend.call("state", { range: "all" });
    const stateMs = performance.now() - t;
    expect(all.sessions).toHaveLength(1000);
    t = performance.now();
    const graph = await backend.call("graph", { project: "atlas", range: "all" });
    const plot = plotLedgerGraph(graph);
    const graphMs = performance.now() - t;
    t = performance.now();
    const hits = await backend.call("search", { query: "scheduler", limit: 40 });
    const searchMs = performance.now() - t;
    expect(hits.hits.length).toBeGreaterThan(0);
    expect(plot.nodes.length).toBe(graph.nodes.length);
    expect(new Set(graph.nodes.map((n) => n.id)).size).toBe(graph.nodes.length);
    // generous bounds for CI machines; the point is that nothing is quadratic in the events
    expect({ built: built < 3000, stateMs: stateMs < 1000, graphMs: graphMs < 2000, searchMs: searchMs < 1000 }).toEqual({ built: true, stateMs: true, graphMs: true, searchMs: true });
    const week = await backend.call("state", { range: "7d" });
    expect(week.hiddenBefore).toBeGreaterThan(0);
    expect(week.sessions.length + week.hiddenBefore).toBe(1000);
  });
});

describe("Ledger backend errors", () => {
  afterEach(() => vi.restoreAllMocks());
  it("turns {error} answers and rejected calls into LedgerError", async () => {
    expect(() => ledgerResult({ error: { code: "SCHEMA_MISMATCH", message: "newer database" } })).toThrow(LedgerError);
    expect(ledgerResult({ rev: 3 })).toEqual({ rev: 3 });
    expect(ledgerFailure("{\"error\":{\"code\":\"BUSY\",\"message\":\"locked\"}}")).toMatchObject({ code: "BUSY", message: "locked" });
    expect(ledgerFailure(new Error("plain"))).toMatchObject({ code: "BACKEND", message: "plain" });
    const spy = vi.spyOn(ipc, "ledgerCall").mockResolvedValueOnce({ rev: 9 }).mockResolvedValueOnce({ error: { code: "NOT_ALLOWED", message: "agent" } }).mockRejectedValueOnce("command ledger_call not found");
    expect(await nativeLedgerBackend.call("rev", {})).toEqual({ rev: 9 });
    await expect(nativeLedgerBackend.call("rev", {})).rejects.toMatchObject({ code: "NOT_ALLOWED" });
    await expect(nativeLedgerBackend.call("rev", {})).rejects.toMatchObject({ code: "BACKEND", message: "command ledger_call not found" });
    expect(spy).toHaveBeenCalledWith("rev", {});
  });
});

describe("Ledger store", () => {
  afterEach(() => vi.useRealTimers());
  /** The demo, counting the calls the store makes */
  function counted() {
    const d = demo();
    const calls: string[] = [];
    const backend: LedgerBackend = { kind: "demo", call: <M extends LedgerMethod>(method: M, args: LedgerMethods[M]["args"]) => { calls.push(method); return d.backend.call(method, args); } };
    return { ...d, calls, store: new LedgerStore(backend) };
  }

  it("reads the state only when rev moved", async () => {
    const { store, calls } = counted();
    await store.refresh(true);
    expect(calls).toEqual(["rev", "state"]);
    await store.refresh();
    expect(calls).toEqual(["rev", "state", "rev"]);
    await store.human({ action: "ack", sessionId: store.state!.sessions.find((s) => s.verdict === "confirm")!.id });
    expect(calls.slice(3)).toEqual(["human", "rev", "state"]);
    store.dispose();
  });

  it("polls every two seconds while a page shows it", async () => {
    vi.useFakeTimers({ toFake: ["setInterval", "clearInterval", "setTimeout", "clearTimeout"] });
    const { store, calls } = counted();
    const stop = store.start();
    await vi.advanceTimersByTimeAsync(10);
    expect(calls).toEqual(["rev", "state"]);
    await vi.advanceTimersByTimeAsync(4000);
    expect(calls.filter((c) => c === "rev")).toHaveLength(3);
    stop();
    await vi.advanceTimersByTimeAsync(6000);
    expect(calls.filter((c) => c === "rev")).toHaveLength(3);
    store.dispose();
  });

  it("undoes confirm, archive and status changes from the toast, several as one", async () => {
    const { store } = counted();
    await store.refresh(true);
    const confirm = store.state!.sessions.filter((s) => s.verdict === "confirm").map((s) => s.id);
    await store.bulk("ack", confirm);
    expect(confirm.map((id) => store.session(id)!.verdict)).toEqual(confirm.map(() => "expirable"));
    expect(store.toast).toMatchObject({ message: `${confirm.length} sessions updated`, error: false });
    await store.undo();
    expect(confirm.map((id) => store.session(id)!.verdict)).toEqual(confirm.map(() => "confirm"));
    const spike = store.state!.sessions.find((s) => s.verdict === "pending_merge" && s.project === "atlas")!;
    await store.human({ action: "set_status", sessionId: spike.id, status: "dropped" });
    expect(store.session(spike.id)!.verdict).toBe("expirable");
    await store.undo();
    expect(store.session(spike.id)!.verdict).toBe("pending_merge");
    expect(store.session(spike.id)!.ackAt).toBeUndefined();
    store.dispose();
  });

  it("reviews automatic answers and says when auto-continue answered a prompt first", async () => {
    const { store, advance } = counted();
    await store.refresh(true);
    const [auto] = store.state!.autoReview!;
    expect(await store.reviewAuto(auto, "Use the full suite.")).toBe(true);
    expect(store.toast?.message).toBe(`Correction sent to ${auto.sessionId}`);
    expect(store.state!.autoReview!.some((p) => p.id === auto.id)).toBe(false);
    const waiting = store.state!.pendingPrompts.find((p) => p.kind === "stop_question")!;
    advance(60_000);
    expect(await store.answerPrompt(waiting, { text: "No" })).toBe(false);
    expect(store.toast).toMatchObject({ message: "The prompt was already answered.", error: false });
    const permission = store.state!.pendingPrompts.find((p) => p.kind === "permission")!;
    expect(await store.answerPrompt(permission, { decision: "allow" })).toBe(true);
    expect(store.toast?.message).toBe("Allowed");
    store.dispose();
  });

  it("shows a failed operation as an error toast without undo", async () => {
    const { store } = counted();
    await store.refresh(true);
    expect(await store.human({ action: "unack", sessionId: "missing" })).toBe(false);
    expect(store.toast).toMatchObject({ error: true, undo: null });
    store.dispose();
  });

  it("follows the open repository's project, and says when it has none", async () => {
    const { store } = counted();
    await store.refresh(true);
    store.setRepository("C:/Projects/atlas");
    store.setProjectChoice("repository");
    expect([store.project, store.repositoryWithoutSessions]).toEqual(["atlas", false]);
    store.setRepository("C:/Projects/elsewhere");
    expect([store.project, store.repositoryWithoutSessions, store.graphProject]).toEqual([null, true, "atlas"]);
    store.setProjectChoice("harbor");
    expect(store.project).toBe("harbor");
    store.setProjectChoice("all");
    expect(store.project).toBeNull();
    store.dispose();
  });

  it("loads the selected session and the graph, and imports and searches in the chosen project", async () => {
    const { store } = counted();
    await store.refresh(true);
    store.setProjectChoice("harbor");
    const id = store.state!.sessions.find((s) => s.project === "harbor" && s.verdict === "needs_human")!.id;
    store.select(id);
    await store.loadDetail();
    expect(store.detail?.session.id).toBe(id);
    store.setView("graph");
    await store.loadGraph();
    expect(store.graph?.nodes.every((n) => !n.sessionId || store.session(n.sessionId)?.project !== "atlas")).toBe(true);
    const summary = await store.importReports("{\"event\":\"start\",\"session\":\"S1102-01\",\"title\":\"Pasted\"}");
    expect(summary).toMatchObject({ imported: 1, sessions: ["S1102-01"] });
    expect(store.session("S1102-01")?.project).toBe("harbor");
    expect((await store.search("Retry policy")).length).toBe(0);
    store.setProjectChoice("all");
    expect((await store.search("Retry policy")).length).toBeGreaterThan(0);
    store.setView("inbox");
    store.dispose();
  });
});
