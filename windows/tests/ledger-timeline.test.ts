import { describe, expect, it } from "vitest";
import { DemoLedgerBackend, timelineEvents, type LedgerEvent } from "@/entities/ledger";

const event = (id: number, actor: LedgerEvent["actor"], type: string, ts = id): LedgerEvent => ({ id, actor, type, ts, sessionId: "review" });

describe("Ledger report-focused timeline", () => {
  it("keeps demo report timestamps consistent with their agent events", () => {
    for (const large of [false, true]) {
      const demo = new DemoLedgerBackend({ now: () => Date.UTC(2026, 9, 31), large });
      const latest = new Map<string, number>();
      for (const item of demo.world.events) if (item.actor === "agent") latest.set(item.sessionId, Math.max(latest.get(item.sessionId) ?? 0, item.ts));
      for (const session of demo.world.sessions) expect(session.lastAgentAt, session.id).toBe(latest.get(session.id));
    }
  });

  it("keeps a report visible among hundreds of passive observations", () => {
    const hooks = Array.from({ length: 300 }, (_, index) => event(index + 10, "hook", "hook"));
    const report = event(1, "agent", "done");
    expect(timelineEvents([report, ...hooks, event(400, "agent", "heartbeat")])).toEqual({ events: [report], hiddenActivity: 301 });
  });

  it("retains human decisions and automatic answers, regardless of event names", () => {
    const decisions = [event(1, "human", "answer"), event(2, "human", "heartbeat"), event(3, "auto", "auto_reply"), event(4, "agent", "question")];
    expect(timelineEvents(decisions).events).toEqual([...decisions].reverse());
  });

  it("reveals all activity on request and orders ties by event ID without changing the input", () => {
    const input = [event(3, "hook", "hook", 10), event(1, "agent", "start", 20), event(2, "agent", "heartbeat", 10)];
    expect(timelineEvents(input, true)).toEqual({ events: [input[1], input[0], input[2]], hiddenActivity: 0 });
    expect(input.map((item) => item.id)).toEqual([3, 1, 2]);
  });

  it("reveals a focused search result while leaving other passive observations hidden", () => {
    const hook = event(1, "hook", "hook");
    const heartbeat = event(2, "agent", "heartbeat");
    const report = event(3, "agent", "note");
    expect(timelineEvents([hook, heartbeat, report], false, hook.id)).toEqual({ events: [report, hook], hiddenActivity: 1 });
    expect(timelineEvents([hook, heartbeat, report], false, heartbeat.id)).toEqual({ events: [report, heartbeat], hiddenActivity: 1 });
    expect(timelineEvents([hook], false, 999)).toEqual({ events: [], hiddenActivity: 1 });
  });
});
