import { describe, expect, it } from "vitest";
import { consumeEvents, newRunView, recordIsRunning, recoverRunHistory, runCounts, runPresentationState, runRowPresentationState } from "@/entities/flow";

const record = {
  flow: "checks",
  state: "FAILED",
  running: false,
  finishedAt: "2026-10-30T00:00:01Z",
  code: "TEST-01",
  exitCode: 1,
  nodes: [
    { id: "build", title: "Build", block: "cmd", state: "PASSED", durationMs: 15, log: "logs/build.log" },
    { id: "test", title: "Unit tests", block: "test.junit", state: "FAILED", code: "TEST-01", tests: { executed: 3, passed: 2 }, reason: { message: "One assertion failed" } },
  ],
};
const savedPlan = { nodes: [{ id: "build", needs: [] }, { id: "test", needs: ["build"] }] };
const event = (seq: number, type: string, data: Record<string, unknown>, node?: string) => `${JSON.stringify({ seq, type, data, node, at: "2026-10-30T00:00:00Z" })}\n`;

describe("flow history recovery", () => {
  it("recovers completed metadata, tests and historical edges without events", () => {
    const view = recoverRunHistory(newRunView("r1"), record, savedPlan);
    expect([view.flow, view.state, view.done, view.code, view.exitCode]).toEqual(["checks", "FAILED", true, "TEST-01", 1]);
    expect(view.nodes.map(node => [node.id, node.state, node.needs])).toEqual([["build", "PASSED", []], ["test", "FAILED", ["build"]]]);
    expect(view.nodes[0].log).toBe("logs/build.log");
    expect(view.nodes[1].reason).toBe("One assertion failed");
    expect(runCounts(view)).toEqual({ passed: 1, failed: 1, running: 0, total: 2 });
    expect([view.nodes[1].testsPassed, view.nodes[1].testsExecuted]).toEqual([2, 3]);
  });

  it("finishes a partial stream while retaining its log tail and original dependencies", () => {
    const source = newRunView("r1");
    consumeEvents(source, event(1, "run.planned", { flow: "checks", nodes: [{ id: "build", block: "cmd", needs: [] }, { id: "test", block: "test.junit", needs: ["build"] }] })
      + event(2, "node.state", { state: "RUNNING" }, "build") + event(3, "log", { lines: ["Compiling sources"] }, "build"));
    const view = recoverRunHistory(source, record);
    expect(view.done).toBe(true);
    expect(view.nodes[0].state).toBe("PASSED");
    expect(view.nodes[0].tail).toEqual(["Compiling sources"]);
    expect(view.nodes[1].needs).toEqual(["build"]);
    expect(source.nodes[0].state).toBe("RUNNING");
  });

  it("does not invent historical edges when neither events nor saved plan survive", () => {
    const view = recoverRunHistory(newRunView("r1"), record);
    expect(view.nodes.every(node => node.needs.length === 0)).toBe(true);
  });

  it("presents stopped processes separately without inventing an engine verdict", () => {
    const view = recoverRunHistory(newRunView("r1"), { flow: "checks", state: "RUNNING", running: false }, savedPlan);
    expect(view.state).toBe("RUNNING");
    expect(view.done).toBe(true);
    expect(runPresentationState(view)).toBe("INTERRUPTED");
    expect(runRowPresentationState({ runId: "r1", flow: "checks", state: "RUNNING", running: false })).toBe("INTERRUPTED");
    expect(recordIsRunning({ state: "PREFLIGHT", running: false })).toBe(true);
    expect(recordIsRunning({ state: "PREFLIGHT", running: false }, false)).toBe(false);
    expect(recordIsRunning(record, true)).toBe(false);
  });

  it("does not regress a completed event stream to an earlier status snapshot", () => {
    const source = newRunView("r1");
    consumeEvents(source, event(1, "run.done", { state: "SUCCEEDED", exitCode: 0 }));
    const view = recoverRunHistory(source, { state: "RUNNING", running: true });
    expect([view.state, view.done, runPresentationState(view)]).toEqual(["SUCCEEDED", true, "SUCCEEDED"]);
  });
});
