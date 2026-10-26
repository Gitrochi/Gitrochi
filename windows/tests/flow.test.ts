import { describe, expect, it } from "vitest";
import { consumeEvents, needsConfirmation, newRunView, parseEngineError, runCounts, type FlowPlan } from "@/entities/flow";

// The event shape the engine writes (tools/gitch-flow/schema/flow-event-v1.schema.json), as is
const ev = (seq: number, type: string, data: Record<string, unknown>, node?: string) =>
  JSON.stringify({ schemaVersion: 1, runId: "r1", seq, at: "2026-10-26T00:00:00.000Z", type, ...(node ? { node } : {}), data }) + "\n";

const events = [
  ev(1, "run.planned", { flow: "bad", nodes: [{ id: "deploy", title: "Command", block: "cmd", needs: [] }, { id: "unit", title: "Tests", block: "test.junit", needs: ["deploy"] }, { id: "unit/on-failure/dump", block: "cmd", needs: ["unit"], branchOf: "unit" }] }),
  ev(2, "run.state", { state: "RUNNING" }),
  ev(3, "node.state", { state: "RUNNING", block: "cmd", log: "logs/deploy.log" }, "deploy"),
  ev(4, "log", { stream: "engine", lines: ["undo registered: echo undone"] }, "deploy"),
  ev(5, "log", { lines: [{ s: "out", t: "deployed" }] }, "deploy"),
  ev(6, "node.state", { state: "PASSED", durationMs: 12 }, "deploy"),
  ev(7, "node.state", { state: "FAILED", code: "TEST-01", tests: { executed: 3, passed: 2 } }, "unit"),
  ev(8, "node.state", { state: "SKIPPED", reason: { code: "condition", message: "condition is false" } }, "unit/on-failure/dump"),
  ev(9, "run.state", { state: "ROLLING_BACK" }),
  ev(10, "rollback.step", { state: "UNDONE", title: "echo undone" }, "deploy"),
  ev(11, "run.done", { state: "ROLLED_BACK", code: "TEST-01", exitCode: 1 }),
].join("");

describe("flow run screen state", () => {
  it("builds node states, log tails and rollback steps from events in order", () => {
    const v = newRunView("r1");
    expect(consumeEvents(v, events)).toBe("");
    expect(v.flow).toBe("bad");
    expect(v.done).toBe(true);
    expect(v.state).toBe("ROLLED_BACK");
    expect(v.code).toBe("TEST-01");
    expect(v.exitCode).toBe(1);
    const [deploy, unit, dump] = v.nodes;
    expect(deploy.state).toBe("PASSED");
    expect(deploy.log).toBe("logs/deploy.log");
    expect(deploy.tail).toEqual(["undo registered: echo undone", "deployed"]);
    expect(unit.code).toBe("TEST-01");
    expect([unit.testsPassed, unit.testsExecuted]).toEqual([2, 3]);
    expect(dump.reason).toBe("condition is false");
    expect(v.steps).toEqual([{ id: 10, node: "deploy", text: "echo undone", state: "UNDONE" }]);
    // failure branches are not counted
    expect(runCounts(v)).toEqual({ passed: 1, failed: 1, running: 0, total: 2 });
  });

  it("gives the same result when fed mid-line chunks, and drops seqs already seen", () => {
    const v = newRunView("r1");
    let rest = "";
    for (let i = 0; i < events.length; i += 37) rest = consumeEvents(v, rest + events.slice(i, i + 37));
    expect(rest).toBe("");
    expect(v.state).toBe("ROLLED_BACK");
    const tail = v.nodes[0].tail.length;
    consumeEvents(v, events);
    expect(v.nodes[0].tail.length).toBe(tail);
  });

  it("reads the engine error envelope (the last JSON line on stderr)", () => {
    const stderr = 'warning: something\n{"schemaVersion":1,"error":{"code":"GITCH_CONFIRMATION_REQUIRED","flowCode":"TRUST-01","message":"the flow file is not trusted","exitCode":2,"action":"Approve it"}}\n';
    expect(parseEngineError(stderr)).toEqual({ message: "the flow file is not trusted", code: "TRUST-01", action: "Approve it" });
    expect(parseEngineError("plain failure")).toBeNull();
  });

  it("asks once more for outward actions, blocks that are hard to undo and manual approvals", () => {
    const base: FlowPlan = { flow: "x", env: "local", trust: { trusted: true }, outward: [], gates: [], services: [], warnings: [], nodes: [{ id: "a", block: "cmd", needs: [], decision: "run" }] };
    expect(needsConfirmation(base)).toBe(false);
    expect(needsConfirmation({ ...base, outward: ["deploy (ci.gitlab.pipeline)"] })).toBe(true);
    expect(needsConfirmation({ ...base, gates: ["approve"] })).toBe(true);
    expect(needsConfirmation({ ...base, nodes: [{ id: "web", block: "deploy.compose", needs: [], decision: "run", destructive: true }] })).toBe(true);
    expect(needsConfirmation({ ...base, nodes: [{ id: "web", block: "deploy.compose", needs: [], decision: "skip", destructive: true }] })).toBe(false);
  });
});
