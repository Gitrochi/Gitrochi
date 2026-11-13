import { describe, expect, it } from "vitest";
import { type FlowPlanNode, type FlowRunRow, type RunNode, type RunView, flowBanner, flowEdgeLook, flowLogTail, flowSkipCause, flowStepCommand, flowStepSummary, flowStepViews, flowTone, newRunView } from "@/entities/flow";

const step = (id: string, needs: string[] = [], extra: Partial<FlowPlanNode> = {}): FlowPlanNode => ({ id, block: "cmd", needs, decision: "run", ...extra });
const ran = (id: string, state: RunNode["state"], durationMs: number | null = null): RunNode => ({ id, title: id, block: "cmd", needs: [], branchOf: null, state, code: null, durationMs, testsPassed: null, testsExecuted: null, reason: null, log: null, tail: [] });
const view = (nodes: RunNode[], extra: Partial<RunView> = {}): RunView => ({ ...newRunView("r24"), flow: "verify", state: "FAILED", done: true, nodes, ...extra });
const row = (extra: Partial<FlowRunRow> = {}): FlowRunRow => ({ runId: "r24", flow: "verify", state: "FAILED", running: false, durationMs: 152_000, ...extra });

const plan = [step("install"), step("lint", ["install"]), step("ui-tests", ["install"]), step("package", ["lint", "ui-tests"])];
const failedRun = view([ran("install", "PASSED", 22_000), ran("lint", "PASSED", 14_000), ran("ui-tests", "FAILED", 130_000), ran("package", "SKIPPED")]);

describe("flow workspace banner", () => {
  it("names the failed step and what was skipped because of it", () => {
    expect(flowBanner({ trusted: true, latest: row(), view: failedRun })).toEqual({ kind: "finished", runId: "r24", state: "FAILED", tone: "failed", failedStep: "ui-tests", skipped: ["package"], durationMs: 152_000 });
  });

  it("asks for a review before anything else once the flow file changed", () => {
    expect(flowBanner({ trusted: false, latest: row(), view: failedRun })).toEqual({ kind: "review" });
    expect(flowBanner({ trusted: false })).toEqual({ kind: "review" });
  });

  it("follows a running flow even when the file changed under it", () => {
    const live = view([ran("install", "PASSED"), ran("lint", "RUNNING")], { state: "RUNNING", done: false });
    expect(flowBanner({ trusted: false, latest: row({ state: "RUNNING", running: true, startedAt: "2026-10-30T00:00:00Z" }), view: live }))
      .toEqual({ kind: "running", runId: "r24", step: "lint", startedAt: "2026-10-30T00:00:00Z" });
  });

  it("says nothing ran yet instead of inventing a state", () => {
    expect(flowBanner({ trusted: true })).toEqual({ kind: "ready" });
  });

  it("reports a passed run and never reads steps from another run's view", () => {
    expect(flowBanner({ trusted: true, latest: row({ runId: "r25", state: "SUCCEEDED" }), view: failedRun }))
      .toEqual({ kind: "finished", runId: "r25", state: "SUCCEEDED", tone: "passed", failedStep: null, skipped: [], durationMs: 152_000 });
  });

  it("presents a run whose engine stopped as interrupted, not as running", () => {
    const banner = flowBanner({ trusted: true, latest: row({ state: "RUNNING", running: false }) });
    expect(banner).toMatchObject({ kind: "finished", state: "INTERRUPTED", tone: "waiting" });
  });
});

describe("flow steps with the latest run laid over the plan", () => {
  it("shows each step's recorded state and duration", () => {
    expect(flowStepViews(plan, failedRun).map((entry) => [entry.id, entry.state, entry.durationMs]))
      .toEqual([["install", "PASSED", 22_000], ["lint", "PASSED", 14_000], ["ui-tests", "FAILED", 130_000], ["package", "SKIPPED", null]]);
  });

  it("gives a step the run never saw no state, and keeps what the plan already decided", () => {
    const steps = flowStepViews([...plan, step("docs"), step("deploy", [], { decision: "skip" })], failedRun);
    expect(steps.find((entry) => entry.id === "docs")?.state).toBeNull();
    expect(steps.find((entry) => entry.id === "deploy")?.state).toBe("SKIPPED");
    expect(flowStepViews(plan).every((entry) => entry.state === null)).toBe(true);
  });

  it("drops running and waiting marks once the run has ended without them finishing", () => {
    const stopped = view([ran("install", "PASSED"), ran("lint", "RUNNING"), ran("ui-tests", "PENDING")], { state: "RUNNING", done: true });
    expect(flowStepViews(plan, stopped).map((entry) => entry.state)).toEqual(["PASSED", null, null, null]);
    const live = view([ran("install", "PASSED"), ran("lint", "RUNNING"), ran("ui-tests", "PENDING")], { state: "RUNNING", done: false });
    expect(flowStepViews(plan, live).map((entry) => entry.state)).toEqual(["PASSED", "RUNNING", "PENDING", null]);
  });

  it("names the step a skipped one was waiting for", () => {
    const steps = flowStepViews(plan, failedRun);
    expect(flowSkipCause(steps[3], steps)).toBe("ui-tests");
    expect(flowSkipCause(steps[2], steps)).toBeNull();
    const plannedSkip = flowStepViews([step("deploy", [], { decision: "skip" })]);
    expect(flowSkipCause(plannedSkip[0], plannedSkip)).toBeNull();
  });
});

describe("flow graph and step text", () => {
  it("colours only the failed path and dashes connectors into skipped steps", () => {
    expect(flowEdgeLook("PASSED", "FAILED")).toEqual({ tone: "failed", dashed: false });
    expect(flowEdgeLook("FAILED", "SKIPPED")).toEqual({ tone: "failed", dashed: true });
    expect(flowEdgeLook("PASSED", "PASSED")).toEqual({ tone: "neutral", dashed: false });
    expect(flowEdgeLook(null, null)).toEqual({ tone: "neutral", dashed: false });
    expect(flowEdgeLook("PASSED", "SKIPPED")).toEqual({ tone: "neutral", dashed: true });
  });

  it("maps engine states to the shared status tones", () => {
    expect(["SUCCEEDED", "PASSED", "CACHED"].map(flowTone)).toEqual(["passed", "passed", "passed"]);
    expect(["FAILED", "INDETERMINATE", "ROLLBACK_FAILED"].map(flowTone)).toEqual(["failed", "failed", "failed"]);
    expect(["RUNNING", "ROLLED_BACK", "REJECTED", "INTERRUPTED"].map(flowTone)).toEqual(["waiting", "waiting", "waiting", "waiting"]);
    expect([null, undefined, "SKIPPED", "CANCELLED", "PENDING"].map(flowTone)).toEqual(["neutral", "neutral", "neutral", "neutral", "neutral"]);
  });

  it("uses a step's own words only when the flow file gives any", () => {
    expect(flowStepSummary({ id: "install", title: "Install dependencies" })).toBe("Install dependencies");
    expect(flowStepSummary({ id: "install", title: "install" })).toBeNull();
    expect(flowStepSummary({ id: "install", title: "Command" })).toBeNull();
    expect(flowStepSummary({ id: "install", title: "명령" })).toBeNull();
    expect(flowStepSummary({ id: "install" })).toBeNull();
  });

  it("shows the first real line of a script as the command", () => {
    expect(flowStepCommand({ run: "\n# set up\n  npm ci\nnpm test" })).toBe("npm ci");
    expect(flowStepCommand({ run: null })).toBeNull();
  });

  it("folds earlier output lines and counts them", () => {
    const lines = Array.from({ length: 20 }, (_, index) => `line ${index + 1}`);
    expect(flowLogTail(lines, 8)).toEqual({ hidden: 12, lines: lines.slice(12) });
    expect(flowLogTail(lines.slice(0, 3), 8)).toEqual({ hidden: 0, lines: lines.slice(0, 3) });
  });
});
