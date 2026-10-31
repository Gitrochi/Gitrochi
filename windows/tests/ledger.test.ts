import { describe, expect, it } from "vitest";
import {
  compareSessions, compareVersions, computeVerdict, countdown, countReports, emptyFilter, filterSessions, GRAPH_LANE_W, GRAPH_LEFT_PAD, GRAPH_ROW_H, inboxGroups, inboxItems, inboxKeyAction,
  inverseOperation, type LedgerGraph, ledgerLayout, type LedgerVerdict, ledgerVerdicts, matchesText, pathsInBand, plotLedgerGraph, projectForRepository, promptActions, promptOptions,
  describeAnswer, promptChoice, promptSummary, serverNow, stepIndex, streamCount, summarizeImport, verdictCounts, verdictDisplayOrder, verdictLook, visibleRows, waitingPrompts,
} from "@/entities/ledger";
import { edgePath as edgePathForTest } from "@/entities/ledger/lib/graph";
import { destinationEnabled, isWorkspaceDestination, previewDestinations, restoredDestination, workspaceDestinations } from "@/entities/git";
import { env } from "@/shared/config";
import { prompt, question, session } from "./ledger-fixtures";

const HOUR = 3_600_000;
const NOW = Date.UTC(2026, 9, 31, 12);

describe("Ledger verdicts", () => {
  const verdict = (over: Partial<Parameters<typeof computeVerdict>[0]>) => computeVerdict({ status: "active", openQuestions: 0, lastAt: NOW, ...over }, NOW);
  it("follows the contract's priority: archived, needs you, finished, shelved, done, stale, active", () => {
    expect(verdict({ archivedAt: NOW, openQuestions: 2, status: "merged" })).toBe("archived");
    expect(verdict({ openQuestions: 1, status: "merged", ackAt: NOW })).toBe("needs_human");
    for (const status of ["merged", "closed", "dropped"] as const) {
      expect(verdict({ status })).toBe("confirm");
      expect(verdict({ status, ackAt: NOW })).toBe("expirable");
    }
    expect(verdict({ status: "shelved", lastAt: NOW - 400 * HOUR })).toBe("shelved");
    expect(verdict({ status: "done", lastAt: NOW - 400 * HOUR })).toBe("pending_merge");
    expect(verdict({ lastAt: NOW - 73 * HOUR })).toBe("stale");
    expect(verdict({ lastAt: NOW - 71 * HOUR })).toBe("active");
  });
  it("holds off stale while a session is marked still active", () => {
    expect(verdict({ lastAt: NOW - 100 * HOUR, snoozeUntil: NOW + HOUR })).toBe("active");
    expect(verdict({ lastAt: NOW - 100 * HOUR, snoozeUntil: NOW - HOUR })).toBe("stale");
  });
  it("shows every verdict once, in the Inbox's order, with the contract's colours", () => {
    expect([...verdictDisplayOrder].sort()).toEqual([...ledgerVerdicts].sort());
    expect(verdictDisplayOrder.slice(0, 5)).toEqual(["needs_human", "confirm", "expirable", "pending_merge", "stale"]);
    const colours: Record<LedgerVerdict, string> = { needs_human: "--orange", pending_merge: "--accent", confirm: "--accent", expirable: "--green", stale: "--red", shelved: "--text-3", archived: "--text-3", active: "--text-2" };
    for (const v of ledgerVerdicts) expect(verdictLook(v).color, v).toBe(colours[v]);
    expect(ledgerVerdicts.filter((v) => verdictLook(v).outline)).toEqual(["confirm"]);
  });
  it("sorts the Board by verdict, then the latest activity", () => {
    const rows = [session({ id: "A", verdict: "active", lastAt: NOW }), session({ id: "B", verdict: "needs_human", lastAt: NOW - HOUR }), session({ id: "C", verdict: "needs_human", lastAt: NOW }), session({ id: "D", verdict: "archived", lastAt: NOW })];
    expect(rows.sort(compareSessions).map((s) => s.id)).toEqual(["C", "B", "A", "D"]);
  });
});

describe("Ledger countdowns and prompts", () => {
  it("rounds seconds up and colours the last 30 and 10 seconds", () => {
    expect(countdown(NOW + 45_000, NOW)).toEqual({ text: "0:45", left: 45_000, tone: "calm" });
    expect(countdown(NOW + 30_000, NOW).tone).toBe("soon");
    expect(countdown(NOW + 9_100, NOW)).toMatchObject({ text: "0:10", tone: "urgent" });
    expect(countdown(NOW + 1, NOW).text).toBe("0:01");
    expect(countdown(NOW - 5_000, NOW)).toEqual({ text: "0:00", left: 0, tone: "due" });
    expect(countdown(NOW + 3_723_000, NOW).text).toBe("1:02:03");
    expect(countdown(NOW + 600_000, NOW).text).toBe("10:00");
    expect(countdown(0, NOW)).toMatchObject({ text: "", tone: "none" });
  });
  it("runs on the backend's clock", () => {
    expect(serverNow(1_000, 50_000, 53_000)).toBe(4_000);
    expect(serverNow(1_000, 50_000, 49_000)).toBe(1_000);
  });
  it("lists waiting prompts soonest first, held ones last", () => {
    const list = [prompt({ id: 1, deadline: 0 }), prompt({ id: 2, deadline: NOW + 9_000 }), prompt({ id: 3, deadline: NOW + 1_000 }), prompt({ id: 4, state: "auto" })];
    expect(waitingPrompts(list).map((p) => p.id)).toEqual([3, 2, 1]);
  });
  it("offers allow and deny for permissions and plans, an answer for questions", () => {
    expect(promptActions("permission")).toEqual({ reply: false, allow: true });
    expect(promptActions("exit_plan_mode")).toEqual({ reply: false, allow: true });
    expect(promptActions("stop_question")).toEqual({ reply: true, allow: false });
    expect(promptActions("ask_user_question")).toEqual({ reply: true, allow: false });
  });
  it("reads auto-continue's prompt payload: one line, options recommended first, per-question answers", () => {
    expect(promptSummary(prompt({ payload: { question: " Continue? ", text: "Long text" } }))).toBe("Continue?");
    expect(promptSummary(prompt({ kind: "permission", payload: { tool: { name: "Bash", summary: "npm test" } } }))).toBe("npm test");
    expect(promptSummary(prompt({ kind: "exit_plan_mode", payload: { text: "Plan title\n1. Step" } }))).toBe("Plan title");
    expect(promptSummary(prompt({ kind: "permission", payload: { tool: "Bash", command: "npm run lint" } }))).toBe("npm run lint");
    const ask = prompt({ kind: "ask_user_question", payload: { question: "Which?", questions: [{ question: "Which one?", multiSelect: false, options: [{ label: "B" }, { label: "A", recommended: true }, { label: " " }] }] } });
    expect(promptOptions(ask)).toEqual([{ label: "A", recommended: true }, { label: "B", recommended: false }]);
    expect(promptOptions(prompt({ payload: { options: ["Yes", { label: "No", recommended: true }] } }))).toEqual([{ label: "No", recommended: true }, { label: "Yes", recommended: false }]);
    expect(promptChoice(ask, "A")).toEqual({ answers: { "Which one?": "A" } });
    expect(promptChoice(prompt({ payload: { options: ["Yes"] } }), "Yes")).toEqual({ text: "Yes" });
  });
  it("puts automatic and personal answers into words", () => {
    expect(describeAnswer({ type: "reply", text: "Go on" })).toEqual({ kind: "text", text: "Go on" });
    expect(describeAnswer({ type: "answers", answers: { a: "One", b: "Two" }, note: "x" })).toEqual({ kind: "text", text: "One, Two" });
    expect(describeAnswer({ type: "allow" }).kind).toBe("allow");
    expect(describeAnswer({ type: "approve_plan" }).kind).toBe("approve");
    expect(describeAnswer({ decision: "deny", message: "Not now" })).toEqual({ kind: "deny", text: "Not now" });
    expect([describeAnswer({ release: true }).kind, describeAnswer({ hold: true }).kind, describeAnswer(undefined).kind]).toEqual(["release", "hold", "unknown"]);
  });
});

describe("Ledger filters", () => {
  const rows = [
    session({ id: "S1031-01", project: "atlas", verdict: "needs_human", title: "Retry policy", touches: ["src/auth/retry.ts"], links: { branch: "fix/retry" } }),
    session({ id: "S1031-02", project: "atlas", verdict: "archived", title: "Old notes" }),
    session({ id: "S1031-03", project: "harbor", verdict: "stale", title: "Navigation" }),
    session({ id: "S1031-04", project: "atlas", verdict: "active", title: "Core", stream: { line: "Implementation" } }),
  ];
  it("keeps streams and archived sessions out unless asked, then applies chips and text", () => {
    expect(filterSessions(rows, emptyFilter()).map((s) => s.id)).toEqual(["S1031-01", "S1031-03"]);
    expect(filterSessions(rows, { ...emptyFilter("atlas"), showArchived: true }).map((s) => s.id)).toEqual(["S1031-01", "S1031-02"]);
    expect(filterSessions(rows, { ...emptyFilter(), verdicts: new Set<LedgerVerdict>(["archived"]) }).map((s) => s.id)).toEqual(["S1031-02"]);
    expect(filterSessions(rows, { ...emptyFilter(), text: "RETRY fix/" }).map((s) => s.id)).toEqual(["S1031-01"]);
    expect(matchesText(rows[0], "auth/retry")).toBe(true);
    expect(matchesText(rows[0], "retry harbor")).toBe(false);
  });
  it("counts verdicts per project without streams, in display order", () => {
    const counts = verdictCounts(rows, "atlas");
    expect(counts.map((c) => c.verdict)).toEqual([...verdictDisplayOrder]);
    expect(Object.fromEntries(counts.filter((c) => c.count).map((c) => [c.verdict, c.count]))).toEqual({ needs_human: 1, archived: 1 });
    expect(streamCount(rows, "atlas")).toBe(1);
    expect(streamCount(rows, "harbor")).toBe(0);
  });
  it("finds the open repository's project from its sessions, else from the folder name", () => {
    const state = { projects: [{ key: "atlas", name: "atlas", open: 1 }, { key: "harbor", name: "Harbor", open: 1 }], sessions: [session({ project: "harbor", links: { repoPath: "C:\\Work\\Site\\" } }), session({ project: "atlas", links: { worktree: "C:/Work/Site" } }), session({ project: "harbor", links: { cwd: "c:/work/site" } })] };
    expect(projectForRepository(state, "C:/Work/Site")).toBe("harbor");
    expect(projectForRepository({ ...state, sessions: [] }, "D:/code/HARBOR")).toBe("harbor");
    expect(projectForRepository({ ...state, sessions: [] }, "D:/code/other")).toBeNull();
    expect(projectForRepository(state, null)).toBeNull();
  });
});

describe("Ledger Inbox", () => {
  const sessions = [
    session({ id: "S-old", verdict: "needs_human", project: "atlas" }),
    session({ id: "S-new", verdict: "needs_human", project: "atlas" }),
    session({ id: "S-arch", verdict: "archived", project: "atlas" }),
    session({ id: "S-conf", verdict: "confirm", project: "atlas", lastAt: NOW - HOUR }),
    session({ id: "S-exp", verdict: "expirable", project: "atlas", lastAt: NOW }),
    session({ id: "S-done", verdict: "pending_merge", project: "harbor" }),
    session({ id: "S-stale", verdict: "stale", project: "atlas" }),
    session({ id: "S-stream", verdict: "stale", project: "atlas", stream: { line: "Implementation" } }),
  ];
  const questions = [
    question({ id: 1, sessionId: "S-old", createdAt: NOW - 5 * HOUR }),
    question({ id: 2, sessionId: "S-new", createdAt: NOW - HOUR }),
    question({ id: 3, sessionId: "S-old", createdAt: NOW - 4 * HOUR }),
    question({ id: 4, sessionId: "S-arch", createdAt: NOW }),
    question({ id: 6, sessionId: "S-new", state: "answered", answeredBy: "human" }),
  ];
  const prompts = [prompt({ id: 7, sessionId: "S-old", state: "auto", deadline: NOW - HOUR }), prompt({ id: 9, sessionId: "S-old" })];
  // the core lists automatic answers to review apart from the waiting prompts
  const autoReview = [prompt({ id: 8, state: "auto", deadline: NOW - 3 * HOUR }), prompt({ id: 7, sessionId: "S-old", state: "auto", deadline: NOW - HOUR }), prompt({ id: 10, sessionId: "S-arch", state: "auto", deadline: NOW })];
  const state = { sessions, questions, pendingPrompts: prompts, autoReview };
  it("groups only what needs a person, newest question session first", () => {
    const groups = inboxGroups(state, null);
    expect(groups.map((g) => g.id)).toEqual(["questions", "auto", "tidy", "decide"]);
    expect(groups[0].items.map((i) => i.key)).toEqual(["q:2", "q:1", "q:3"]);
    expect(groups[1].items.map((i) => i.key)).toEqual(["ap:7", "ap:8"]);
    expect(groups[2].items.map((i) => i.key)).toEqual(["s:S-conf", "s:S-exp"]);
    expect(groups[3].items.map((i) => i.key)).toEqual(["s:S-done", "s:S-stale"]);
    expect(inboxItems(groups)).toHaveLength(9);
  });
  it("filters to one project and drops empty groups", () => {
    const groups = inboxGroups(state, "harbor");
    expect(groups.map((g) => [g.id, g.items.length])).toEqual([["decide", 1]]);
  });
  it("maps triage keys to what each item takes", () => {
    const [questionsGroup, auto, tidy, decide] = inboxGroups(state, null);
    const q = questionsGroup.items[0], a = auto.items[0], conf = tidy.items[0], exp = tidy.items[1], done = decide.items[0], stale = decide.items[1];
    expect(["Enter", "a", "c", "e", "s"].map((k) => inboxKeyAction(q, k))).toEqual(["open", "answer", null, null, null]);
    expect(["Enter", "A", "C", "E", "S"].map((k) => inboxKeyAction(a, k))).toEqual(["open", "answer", "confirm", null, null]);
    expect(inboxKeyAction(conf, "c")).toBe("confirm");
    expect(inboxKeyAction(conf, "e")).toBeNull();
    expect(inboxKeyAction(exp, "e")).toBe("archive");
    expect(inboxKeyAction(exp, "c")).toBeNull();
    expect(inboxKeyAction(stale, "s")).toBe("snooze");
    expect(inboxKeyAction(done, "s")).toBeNull();
    expect(inboxKeyAction(auto.items[1], "Enter")).toBeNull();
  });
  it("moves with the arrow keys inside the list", () => {
    expect(stepIndex(-1, 1, 3)).toBe(0);
    expect(stepIndex(-1, -1, 3)).toBe(2);
    expect(stepIndex(2, 1, 3)).toBe(2);
    expect(stepIndex(0, -1, 3)).toBe(0);
    expect(stepIndex(0, 1, 0)).toBe(-1);
  });
});

describe("Ledger graph coordinates", () => {
  const graph: LedgerGraph = {
    lanes: 3, from: 0, to: 100,
    nodes: [
      { id: "b:1.0", lane: 0, ts: 10, color: 0, kind: "baseline", version: "1.0" },
      { id: "b:1.1", lane: 0, ts: 60, color: 0, kind: "release", version: "1.1" },
      { id: "s1", lane: 1, ts: 20, color: 3, kind: "start", sessionId: "A" },
      { id: "e1", lane: 1, ts: 30, color: 3, kind: "event", sessionId: "A" },
      { id: "m1", lane: 1, ts: 35, color: 3, kind: "merge", sessionId: "A" },
      { id: "s2", lane: 2, ts: 40, color: 5, kind: "start", sessionId: "B" },
      { id: "e2", lane: 2, ts: 70, color: 5, kind: "event", sessionId: "B" },
    ],
    edges: [
      { from: "b:1.0", to: "b:1.1", kind: "trunk", color: 0 },
      { from: "b:1.0", to: "s1", kind: "branch", color: 3 },
      { from: "s1", to: "e1", kind: "branch", color: 3 },
      { from: "e1", to: "m1", kind: "branch", color: 3 },
      { from: "m1", to: "b:1.1", kind: "merge", color: 3 },
      { from: "b:1.0", to: "s2", kind: "branch", color: 5 },
      { from: "s2", to: "e2", kind: "branch", color: 5 },
      { from: "b:1.1", to: "e2", kind: "handoff", color: 5 },
      { from: "missing", to: "e2", kind: "branch", color: 5 },
    ],
  };
  const plot = plotLedgerGraph(graph);
  const at = (id: string) => plot.byId.get(id)!;
  it("puts the newest node on top, one row each, lanes at the commit graph's spacing", () => {
    expect(plot.nodes.map((p) => p.node.id)).toEqual(["e2", "b:1.1", "s2", "m1", "e1", "s1", "b:1.0"]);
    expect(at("e2")).toMatchObject({ row: 0, x: GRAPH_LEFT_PAD + GRAPH_LANE_W * 2.5, y: GRAPH_ROW_H / 2 });
    expect(at("b:1.0")).toMatchObject({ row: 6, x: GRAPH_LEFT_PAD + GRAPH_LANE_W / 2, y: GRAPH_ROW_H * 6.5 });
    expect(plot.height).toBe(7 * GRAPH_ROW_H);
    expect(plot.width).toBe(3 * GRAPH_LANE_W + GRAPH_LEFT_PAD + 16);
  });
  it("draws straight lanes, branches that curve out first and merges that curve in last", () => {
    const d = (from: string, to: string, kind: Parameters<typeof edgePathForTest>[2]) => edgePathForTest(at(from), at(to), kind);
    expect(d("b:1.0", "b:1.1", "trunk")).toBe(`M${at("b:1.0").x},${at("b:1.0").y}L${at("b:1.1").x},${at("b:1.1").y}`);
    const branch = d("b:1.0", "s2", "branch"), s2 = at("s2"), base = at("b:1.0");
    expect(branch.startsWith(`M${base.x},${base.y}C`)).toBe(true);
    expect(branch.endsWith(`${s2.x},${base.y - GRAPH_ROW_H}L${s2.x},${s2.y}`)).toBe(true);
    const merge = d("m1", "b:1.1", "merge"), m1 = at("m1"), top = at("b:1.1");
    expect(merge.startsWith(`M${m1.x},${m1.y}L${m1.x},${top.y + GRAPH_ROW_H}C`)).toBe(true);
    expect(merge.endsWith(`${top.x},${top.y}`)).toBe(true);
    // neighbouring rows, and joins that point back in time, are one direct curve
    const near = d("s2", "b:1.1", "merge"), s2b = at("s2");
    expect(near).toBe(`M${s2b.x},${s2b.y}C${s2b.x},${(s2b.y + top.y) / 2} ${top.x},${(s2b.y + top.y) / 2} ${top.x},${top.y}`);
    expect(d("b:1.1", "e1", "branch").startsWith(`M${top.x},${top.y}C`)).toBe(true);
  });
  it("dashes hand-offs and open lanes, skips unknown nodes and ends lanes that merged", () => {
    expect(plot.paths.filter((p) => p.kind === "handoff").map((p) => p.dashed)).toEqual([true]);
    expect(plot.paths).toHaveLength(8);
    expect(plot.paths.filter((p) => p.kind === "tail")).toHaveLength(0);
    const open = plotLedgerGraph({ ...graph, nodes: [...graph.nodes, { id: "s3", lane: 2, ts: 5, color: 6, kind: "start", sessionId: "C" }] });
    const tail = open.paths.find((p) => p.kind === "tail")!;
    expect(tail).toMatchObject({ dashed: true, top: 0, color: 6 });
    expect(tail.d).toBe(`M${open.byId.get("s3")!.x},${open.byId.get("s3")!.y}L${open.byId.get("s3")!.x},0`);
  });
  it("draws only the rows and paths near the visible band", () => {
    expect(visibleRows(0, 300, 1000)).toEqual({ first: 0, last: 20 });
    expect(visibleRows(3000, 300, 1000)).toEqual({ first: 90, last: 120 });
    expect(visibleRows(29_900, 300, 1000)).toEqual({ first: 986, last: 1000 });
    expect(pathsInBand(plot.paths, 0, GRAPH_ROW_H).map((p) => p.kind).sort()).toEqual(["branch", "handoff"]);
  });
});

describe("Ledger imports, undo, layout and versions", () => {
  it("reports every pasted report in order, failures with their reason", () => {
    const summary = summarizeImport([{ index: 2, ok: false, duplicate: false, error: " Unknown event " }, { index: 0, ok: true, duplicate: false, sessionId: "S1" }, { index: 1, ok: false, duplicate: true, sessionId: "S1" }, { index: 3, ok: false, duplicate: false }]);
    expect(summary.lines).toEqual([{ number: 1, outcome: "imported", sessionId: "S1" }, { number: 2, outcome: "duplicate", sessionId: "S1" }, { number: 3, outcome: "failed", error: "Unknown event" }, { number: 4, outcome: "failed", error: "Unknown error" }]);
    expect([summary.imported, summary.duplicates, summary.failed, summary.sessions]).toEqual([1, 1, 2, ["S1"]]);
  });
  it("counts the reports in a paste", () => {
    expect(countReports("```ledger\n{\"event\":\"start\"}\n```\ntext\n```ledger\n{}\n```")).toBe(2);
    expect(countReports("{\"event\":\"start\"}\n{\"event\":\"done\"}\nnoise")).toBe(2);
    expect(countReports("{\"x\": 1}")).toBe(1);
    expect(countReports("  ")).toBe(0);
  });
  it("undoes with the inverse operations", () => {
    const done = session({ id: "S", status: "done" });
    expect(inverseOperation(done, { action: "ack", sessionId: "S" })).toEqual([{ action: "unack", sessionId: "S" }]);
    expect(inverseOperation({ ...done, ackAt: 1 }, { action: "ack", sessionId: "S" })).toBeNull();
    expect(inverseOperation(done, { action: "archive", sessionId: "S" })).toEqual([{ action: "unarchive", sessionId: "S" }]);
    expect(inverseOperation(done, { action: "set_status", sessionId: "S", status: "merged", into: "1.0" })).toEqual([{ action: "set_status", sessionId: "S", status: "done" }, { action: "unack", sessionId: "S" }]);
    expect(inverseOperation({ ...done, status: "merged", mergedInto: "1.0", ackAt: 1, archivedAt: 2 }, { action: "set_status", sessionId: "S", status: "active" })).toEqual([{ action: "set_status", sessionId: "S", status: "merged", into: "1.0" }, { action: "archive", sessionId: "S" }]);
    expect(inverseOperation({ ...done, snoozeUntil: 5 }, { action: "snooze", sessionId: "S", until: 9 })).toEqual([{ action: "snooze", sessionId: "S", until: 5 }]);
    expect(inverseOperation(done, { action: "snooze", sessionId: "S", until: 9 })).toEqual([{ action: "snooze", sessionId: "S", until: 0 }]);
    expect(inverseOperation(done, { action: "answer", sessionId: "S", questionId: 1, text: "x" })).toBeNull();
  });
  it("lays the page out by width", () => {
    expect([1400, 1080, 1079, 700, 699, 320].map(ledgerLayout)).toEqual(["wide", "wide", "medium", "medium", "narrow", "narrow"]);
  });
  it("orders versions as numbers", () => {
    expect(["1.10.0", "1.9.2", "v1.9.10", "2.0", "1.9.2-rc"].sort(compareVersions)).toEqual(["1.9.2", "1.9.2-rc", "v1.9.10", "1.10.0", "2.0"]);
  });
});

describe("Ledger destination", () => {
  it("stays hidden until GITROCHI_LEDGER_PREVIEW turns it on, then opens without a repository", () => {
    const before = env.ledgerPreview;
    try {
      env.ledgerPreview = null;
      expect([isWorkspaceDestination("ledger"), destinationEnabled("ledger"), restoredDestination("ledger", false)]).toEqual([false, false, "home"]);
      expect(workspaceDestinations).not.toContain("ledger");
      expect(previewDestinations).toEqual(["ledger"]);
      env.ledgerPreview = "1";
      expect([isWorkspaceDestination("ledger"), destinationEnabled("ledger"), restoredDestination("ledger", false), restoredDestination("ledger", true)]).toEqual([true, true, "ledger", "ledger"]);
      expect(workspaceDestinations.every(destinationEnabled)).toBe(true);
    } finally {
      env.ledgerPreview = before;
    }
  });
});
