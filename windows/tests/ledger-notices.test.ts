import { afterEach, describe, expect, it, vi } from "vitest";
import { badgeLabel, DemoLedgerBackend, type LedgerNotice, LedgerNotifier, ledgerNotices, type LedgerState, type LedgerStreamCycle } from "@/entities/ledger";
import { initEnv, settings } from "@/shared/config";
import { prompt, question, session } from "./ledger-fixtures";

// The Ledger's notifications (docs/ledger/DESIGN.md §10.11): what is new between two states, and the notifier's polling.

const NOW = Date.UTC(2026, 10, 1, 9);
const state = (over: Partial<LedgerState> = {}): LedgerState => ({
  schemaVersion: 1, rev: 1, now: NOW, projects: [], baselines: [], sessions: [], questions: [], streams: [], overlaps: [], pendingPrompts: [], autoReview: [],
  attention: { questions: 0, tidy: 0, decide: 0, autoReview: 0, total: 0 }, hiddenBefore: 0, ...over,
});
const cycle = (over: Partial<LedgerStreamCycle> = {}): LedgerStreamCycle => ({ sessionId: "S1031-04", line: "core", version: "1.4.2", state: "active", eventIds: [], ...over });

afterEach(() => vi.restoreAllMocks());

describe("Ledger notices", () => {
  it("announces nothing for what existed when the app started", () => {
    expect(ledgerNotices(null, state({ questions: [question()], pendingPrompts: [prompt({ deadline: NOW + 30_000 })] }))).toEqual([]);
  });

  it("tells about a new question, a session to clean up and an applied report one at a time", () => {
    const before = state({ sessions: [session({ id: "S1031-02", title: "Export docs", verdict: "active" })] });
    expect(ledgerNotices(before, state({ ...before, questions: [question({ id: 7, sessionId: "S1031-01", text: "Retry 3 or 5 times?" })] }))).toEqual([
      { title: "Question from S1031-01", body: "Retry 3 or 5 times?", target: { sessionId: "S1031-01", questionId: 7 } },
    ]);
    expect(ledgerNotices(before, state({ sessions: [session({ id: "S1031-02", title: "Export docs", status: "merged", verdict: "confirm" })] }))).toEqual([
      { title: "To confirm: S1031-02", body: "Export docs", target: { sessionId: "S1031-02" } },
    ]);
    const stream = session({ id: "S1031-04", title: "Core implementation" });
    expect(ledgerNotices(state({ sessions: [stream], streams: [cycle()] }), state({ sessions: [stream], streams: [cycle({ state: "applied" })] }))).toEqual([
      { title: "S1031-04 applied 1.4.2", body: "Core implementation", target: { sessionId: "S1031-04" } },
    ]);
    // nothing again for what was already there
    const after = state({ ...before, questions: [question()] });
    expect(ledgerNotices(after, after)).toEqual([]);
  });

  it("groups several new questions, clean-ups and applied reports into one", () => {
    const after = state({
      sessions: [session({ id: "S1031-02", title: "Export docs", verdict: "expirable" })],
      questions: [question({ id: 1, text: "One?" }), question({ id: 2, text: "Two?" })],
    });
    const [grouped, ...rest] = ledgerNotices(state(), after);
    expect(rest).toEqual([]);
    expect(grouped.title).toBe("3 new items in the Ledger");
    expect(grouped.body.split("\n")).toEqual(["Question from S1031-01 · One?", "Question from S1031-01 · Two?", "Ready to clean up: S1031-02 · Export docs"]);
    expect(grouped.target).toEqual({});
  });

  it("tells about every new waiting prompt with the time left, and every automatic answer", () => {
    const waiting = prompt({ id: 4, sessionId: "S1031-03", kind: "permission", payload: { tool: { name: "Bash", summary: "npm test" } }, deadline: NOW + 45_000 });
    const quiet = prompt({ id: 5, agentId: "agent-9", payload: { question: "Deploy now?" }, deadline: 0 });
    // a wait auto-continue left to the person: only the agent's terminal can answer it
    const held = prompt({ id: 7, sessionId: "S1031-06", kind: "permission", payload: { tool: { name: "Bash", summary: "git push --force" }, hold: { code: "held", rule: "push", detail: "git push --force", message: "held by push" } }, deadline: 0 });
    const notices = ledgerNotices(state(), state({ pendingPrompts: [waiting, quiet, held], questions: [question()] }));
    expect(notices).toEqual([
      { title: "Question from S1031-01", body: "Which one?", target: { sessionId: "S1031-01", questionId: 1 } },
      { title: "S1031-03 is waiting for you", body: "npm test\nAuto-answer in 0:45", target: { sessionId: "S1031-03", promptId: 4 } },
      { title: "agent-9 is waiting for you", body: "Deploy now?\nNo automatic answer", target: { sessionId: undefined, promptId: 5 } },
      { title: "S1031-06 is waiting for you", body: "git push --force\nAuto-continue never answers this kind of request. Answer it in the agent's terminal.", target: { sessionId: "S1031-06", promptId: 7 } },
    ]);
    const answered = prompt({ id: 4, sessionId: "S1031-03", kind: "permission", payload: { tool: { name: "Bash", summary: "npm test" } }, state: "auto", answer: { type: "allow" } });
    const chosen = prompt({ id: 6, sessionId: "S1031-05", kind: "ask_user_question", payload: { question: "Which format?" }, state: "auto", answer: { answers: { "Which format?": "Short summary" } } });
    expect(ledgerNotices(state({ pendingPrompts: [waiting] }), state({ autoReview: [answered, chosen] }))).toEqual([
      { title: "Answered automatically for S1031-03", body: "npm test\nAllow", target: { sessionId: "S1031-03", promptId: 4 } },
      { title: "Answered automatically for S1031-05", body: "Which format?\nShort summary", target: { sessionId: "S1031-05", promptId: 6 } },
    ]);
  });

  it("keeps the overlay's count short", () => {
    expect([0, 1, 12, 99, 100, 4321].map(badgeLabel)).toEqual(["", "1", "12", "99", "99+", "99+"]);
  });
});

describe("Ledger notifier", () => {
  async function demoNotifier(on: { notifications?: boolean; badge?: boolean } = {}) {
    await initEnv({ os: "windows", home: "", dataDir: "", exe: "", temp: "", shell: "", version: "", selftest: null, selftestOpen: null, appData: "", localAppData: "", resourceDir: "" });
    settings.set("ledgerNotifications", on.notifications === false ? undefined : true);
    settings.set("ledgerBadge", on.badge === false ? undefined : true);
    let now = NOW;
    const demo = new DemoLedgerBackend({ now: () => now, repoPath: "C:/fixture/atlas" });
    const sent: LedgerNotice[] = [], badges: (number | null)[] = [];
    const notifier = new LedgerNotifier(() => demo, { notify: async (n) => void sent.push(n), badge: async (rgba) => void badges.push(rgba ? rgba.length : null) });
    const target = demo.world.sessions.find((s) => s.project === "atlas" && !s.archivedAt && s.status === "active")!;
    const ask = () => {
      demo.world.questions.push({ id: demo.world.nextQuestion++, sessionId: target.id, text: "Ship the beta today?", state: "open", createdAt: now });
      demo.world.prompts.push({ id: demo.world.nextPrompt++, sessionId: target.id, kind: "stop_question", payload: { question: "Shall I go on?", proposed: { type: "reply", text: "Yes, go on." } }, createdAt: now, deadline: now + 30_000, state: "waiting" });
      demo.world.rev++;
    };
    return { demo, notifier, sent, badges, target, ask, pass: (ms: number) => { now += ms; } };
  }

  it("reads nothing while both switches are off, and starts from what exists once one is on", async () => {
    const { demo, notifier, sent, badges, target, ask } = await demoNotifier({ notifications: false, badge: false });
    expect([notifier.notifications, notifier.badge]).toEqual([false, false]);
    const reads = vi.spyOn(demo, "call");
    await notifier.poll();
    expect(reads).not.toHaveBeenCalled();
    expect(badges).toEqual([]);
    // what was asked while they were off is not announced afterwards
    ask();
    notifier.setNotifications(true);
    await notifier.poll();
    expect(sent).toEqual([]);
    ask();
    await notifier.poll();
    expect(sent.map((n) => n.title)).toEqual([`Question from ${target.id}`, `${target.id} is waiting for you`]);
    notifier.setNotifications(false);
    expect(settings.get("ledgerNotifications", "unset")).toBe("unset");
  });

  it("learns what exists first, then tells what is new once, and follows the switches", async () => {
    const { notifier, sent, badges, target, ask, pass } = await demoNotifier();
    await notifier.poll();
    expect(sent).toEqual([]);
    // the overlay is a 32 × 32 image of the count; the test has no canvas, so it is removed instead
    expect(badges).toEqual([null]);
    ask();
    await notifier.poll();
    expect(sent.map((n) => n.title)).toEqual([`Question from ${target.id}`, `${target.id} is waiting for you`]);
    expect(sent[1].body).toBe("Shall I go on?\nAuto-answer in 0:30");
    await notifier.poll();
    expect(sent).toHaveLength(2);
    pass(31_000);
    await notifier.poll();
    expect(sent.map((n) => n.title).at(-1)).toBe(`Answered automatically for ${target.id}`);
    notifier.setNotifications(false);
    ask();
    await notifier.poll();
    expect(sent).toHaveLength(3);
  });

  it("removes the overlay when the badge is turned off, and reaches the item a click opens", async () => {
    const { notifier, badges } = await demoNotifier({ badge: false });
    await notifier.poll();
    expect(badges).toEqual([null]);
    const opened: unknown[] = [];
    const off = notifier.onOpen((target) => opened.push(target));
    notifier.open({ sessionId: "S1031-01", promptId: 3 });
    off();
    notifier.open({ sessionId: "S1031-02" });
    expect(opened).toEqual([{ sessionId: "S1031-01", promptId: 3 }]);
  });

  it("refreshes quiet time-based attention without replaying notifications", async () => {
    const clock = vi.spyOn(Date, "now").mockReturnValue(NOW + 86_400_000);
    const { notifier, demo, pass, sent } = await demoNotifier();
    demo.world.prompts = [];
    const calls = vi.spyOn(demo, "call");
    await notifier.poll();
    const rev = demo.world.rev;
    pass(59_999);
    clock.mockReturnValue(NOW + 86_400_000 + 59_999);
    await notifier.poll();
    expect(calls.mock.calls.filter(([method]) => method === "state")).toHaveLength(1);
    pass(1);
    clock.mockReturnValue(NOW + 86_400_000 + 60_000);
    await notifier.poll();
    expect(calls.mock.calls.filter(([method]) => method === "state")).toHaveLength(2);
    expect(demo.world.rev).toBe(rev);
    expect(sent).toEqual([]);
  });
});
