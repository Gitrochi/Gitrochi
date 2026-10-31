import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import { inboxGroups, type LedgerState, LedgerStore, nativeCanRun, nativeLedgerBackend, plotLedgerGraph } from "@/entities/ledger";
import { ipc } from "@/shared/api";
import { session, shapeErrors, specs } from "./ledger-fixtures";

const HOUR = 3_600_000;
const NOW = Date.UTC(2026, 9, 31, 9);

describe("Ledger native backend: mapping", () => {
  afterEach(() => vi.restoreAllMocks());

  it("sends each method with its arguments to ledger_call as they are", async () => {
    const spy = vi.spyOn(ipc, "ledgerCall").mockResolvedValue({ ok: true, rev: 2 });
    await nativeLedgerBackend.call("human", { action: "set_status", sessionId: "S1031-01", status: "merged", into: "1.4.2" });
    await nativeLedgerBackend.call("prompt_answer", { id: 7, answer: { answers: { "Which one?": "The first" } } });
    expect(spy.mock.calls).toEqual([
      ["human", { action: "set_status", sessionId: "S1031-01", status: "merged", into: "1.4.2" }],
      ["prompt_answer", { id: 7, answer: { answers: { "Which one?": "The first" } } }],
    ]);
  });

  it("answers what the core answered, and an {error} or a failed command as a LedgerError", async () => {
    const answer = { hits: [{ kind: "event", id: "12", sessionId: "S1031-01", title: "Retry policy", snippet: "Three attempts, then stop.", ts: NOW }] };
    vi.spyOn(ipc, "ledgerCall")
      .mockResolvedValueOnce(answer)
      .mockResolvedValueOnce({ error: { code: "SCHEMA_MISMATCH", message: "The ledger was written by a newer Gitrochi" } })
      .mockRejectedValueOnce(JSON.stringify({ error: { code: "DATABASE", message: "Ledger call failed" } }))
      .mockRejectedValueOnce(new Error("command ledger_call not found"));
    expect(await nativeLedgerBackend.call("search", { query: "retry" })).toEqual(answer);
    await expect(nativeLedgerBackend.call("state", {})).rejects.toMatchObject({ name: "LedgerError", code: "SCHEMA_MISMATCH", message: "The ledger was written by a newer Gitrochi" });
    await expect(nativeLedgerBackend.call("rev", {})).rejects.toMatchObject({ code: "DATABASE" });
    await expect(nativeLedgerBackend.call("rev", {})).rejects.toMatchObject({ code: "BACKEND", message: "command ledger_call not found" });
  });

  it("knows the core takes a snooze only when it ends in the future", () => {
    expect(nativeCanRun({ action: "snooze", sessionId: "S", until: NOW + HOUR }, NOW)).toBe(true);
    expect(nativeCanRun({ action: "snooze", sessionId: "S" }, NOW)).toBe(true);
    expect(nativeCanRun({ action: "snooze", sessionId: "S", until: 0 }, NOW)).toBe(false);
    expect(nativeCanRun({ action: "snooze", sessionId: "S", until: NOW }, NOW)).toBe(false);
    expect(nativeCanRun({ action: "unack", sessionId: "S" }, NOW)).toBe(true);
  });

  it("offers Undo only for what the core can take back", async () => {
    const stale = session({ id: "S1030-01", lastAt: NOW - 100 * HOUR, verdict: "stale" });
    const snoozed = session({ id: "S1030-02", lastAt: NOW - 100 * HOUR, snoozeUntil: NOW + HOUR, verdict: "active" });
    const state = { schemaVersion: 1, rev: 1, now: NOW, projects: [{ key: "atlas", name: "atlas", open: 2 }], baselines: [], sessions: [stale, snoozed], questions: [], streams: [], overlaps: [], pendingPrompts: [], autoReview: [], attention: { questions: 0, tidy: 0, decide: 1, autoReview: 0, total: 1 }, hiddenBefore: 0 } as LedgerState;
    const calls: unknown[] = [];
    vi.spyOn(ipc, "ledgerCall").mockImplementation(async (method, args) => {
      if (method === "human") calls.push(args);
      return method === "rev" ? { rev: 1 } : method === "state" ? state : { ok: true, rev: 1 };
    });
    const store = new LedgerStore(nativeLedgerBackend);
    try {
      await store.refresh(true);
      // Still active on a stale session: undoing it would end a snooze, which the core has no call for
      expect(await store.human({ action: "snooze", sessionId: stale.id, until: NOW + 72 * HOUR })).toBe(true);
      expect(store.toast).toMatchObject({ error: false, undo: null });
      // a running snooze can be put back; a confirmation can always be taken back
      await store.human({ action: "snooze", sessionId: snoozed.id, until: NOW + 72 * HOUR });
      expect(store.toast?.undo).toEqual([{ action: "snooze", sessionId: snoozed.id, until: NOW + HOUR }]);
      await store.human({ action: "ack", sessionId: stale.id });
      expect(store.toast?.undo).toEqual([{ action: "unack", sessionId: stale.id }]);
      expect(calls).toHaveLength(3);
    } finally {
      store.dispose();
    }
  });
});

// The bundled CLI (npm run core puts it next to gitch-core.exe) reaches the same core as `ledger_call`, as the agent
// caller: what it reads must fit the screens, and a person's operations must come back as NOT_ALLOWED.
const cli = join(process.cwd(), "src-tauri/generated/gitrochi-ledger.exe");
const built = existsSync(cli);

describe("Ledger native backend: the real core", () => {
  let dir = "";
  let db = "";
  /** One method through the CLI's `call`, answered as the Tauri command would: the result or {error} */
  const call = (method: string, args: Record<string, unknown>) => {
    try {
      return JSON.parse(execFileSync(cli, ["call", method, JSON.stringify(args)], { encoding: "utf8", stdio: "pipe", env: { ...process.env, GITROCHI_LEDGER_DB: db, GITROCHI_LEDGER: "1" } }));
    } catch (e) {
      return JSON.parse(String((e as { stdout?: string }).stdout ?? "{}"));
    }
  };
  beforeAll(() => {
    if (!built) return;
    dir = mkdtempSync(join(tmpdir(), "gitrochi-ledger-native-"));
    db = join(dir, "ledger.sqlite3");
    execFileSync(cli, ["demo", db], { env: { ...process.env, GITROCHI_LEDGER: "1" } });
  });
  afterAll(() => {
    if (dir) rmSync(dir, { recursive: true, force: true });
  });
  afterEach(() => vi.restoreAllMocks());

  it("is bundled for the app (required on CI)", () => {
    if (process.env.CI) expect(built).toBe(true);
  });

  it.skipIf(!built)("reads the state, sessions, graphs and search in the shapes the screens read", async () => {
    vi.spyOn(ipc, "ledgerCall").mockImplementation(async (method, args) => call(method, args));
    const store = new LedgerStore(nativeLedgerBackend);
    try {
      await store.refresh(true);
      expect(store.error).toBeNull();
      const state = store.state!;
      expect(shapeErrors(state, specs.state, false)).toEqual([]);
      expect(new Set(state.sessions.map((s) => s.verdict))).toEqual(new Set(["archived", "needs_human", "expirable", "confirm", "shelved", "pending_merge", "stale", "active"]));
      // the Inbox groups the same items the core counts for its badge
      const groups = inboxGroups(state, null);
      const size = (id: string) => groups.find((g) => g.id === id)?.items.length ?? 0;
      expect({ questions: size("questions"), tidy: size("tidy"), decide: size("decide"), autoReview: size("auto") }).toEqual({ questions: state.attention.questions, tidy: state.attention.tidy, decide: state.attention.decide, autoReview: state.attention.autoReview });
      for (const s of state.sessions) expect(shapeErrors(await nativeLedgerBackend.call("session", { id: s.id }), specs.detail, false)).toEqual([]);
      for (const p of state.projects) {
        const graph = await nativeLedgerBackend.call("graph", { project: p.key, range: "all" });
        expect(shapeErrors(graph, specs.graph, false)).toEqual([]);
        const plot = plotLedgerGraph(graph);
        expect(plot.nodes.length).toBe(graph.nodes.length);
        // the core's open sessions, and only they, continue upward from their newest node (plot nodes are newest first)
        const tailFrom = new Set(plot.paths.filter((path) => path.kind === "tail").map((path) => path.bottom));
        const open = (graph.tails ?? []).map((tail) => plot.nodes.find((n) => n.node.sessionId === tail.sessionId)!).filter((n) => n.row > 0);
        expect([...tailFrom].sort()).toEqual(open.map((n) => n.y).sort());
      }
      expect(shapeErrors(await nativeLedgerBackend.call("search", { query: "retry" }), specs.search, false)).toEqual([]);
      expect(shapeErrors(await store.info(), specs.info, false)).toEqual([]);
      expect(shapeErrors(await nativeLedgerBackend.call("backup", {}), specs.backup, false)).toEqual([]);
    } finally {
      store.dispose();
    }
  });

  it.skipIf(!built)("imports pasted reports one by one and recognises them the second time", async () => {
    vi.spyOn(ipc, "ledgerCall").mockImplementation(async (method, args) => call(method, args));
    const store = new LedgerStore(nativeLedgerBackend);
    try {
      const summary = await store.importReports("```ledger\n{\"event\":\"start\",\"session\":\"S1101-07\",\"project\":\"Example App\",\"title\":\"Pasted in a test\",\"kind\":\"research\"}\n```\n```ledger\n{\"event\":\"teleport\"}\n```");
      expect([summary.imported, summary.failed, summary.sessions]).toEqual([1, 1, ["S1101-07"]]);
      expect(store.session("S1101-07")).toMatchObject({ title: "Pasted in a test", role: "research" });
      expect((await store.importReports("```ledger\n{\"event\":\"start\",\"session\":\"S1101-07\",\"project\":\"Example App\",\"title\":\"Pasted in a test\",\"kind\":\"research\"}\n```")).duplicates).toBe(1);
    } finally {
      store.dispose();
    }
  });

  it.skipIf(!built)("keeps a person's operations from agents: the CLI is not the app", async () => {
    vi.spyOn(ipc, "ledgerCall").mockImplementation(async (method, args) => call(method, args));
    const { sessions } = await nativeLedgerBackend.call("state", {});
    await expect(nativeLedgerBackend.call("human", { action: "ack", sessionId: sessions[0].id })).rejects.toMatchObject({ code: "NOT_ALLOWED" });
  });

});
