import { type FlowNodeState, type RunNode, type RunView } from "./run-view";
import type { FlowRunRow } from "./types";

const activeStates = new Set(["RUNNING", "PENDING", "PREFLIGHT", "ROLLING_BACK"]);
const terminalStates = new Set(["SUCCEEDED", "FAILED", "REJECTED", "CANCELLED", "ROLLED_BACK", "ROLLBACK_FAILED"]);
const object = (value: unknown): Record<string, unknown> => value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
const text = (value: unknown) => typeof value === "string" ? value : null;
const number = (value: unknown) => typeof value === "number" ? value : null;
const nodes = (value: unknown) => Array.isArray(value) ? value.map(object).filter(node => text(node.id)) : [];
const needs = (value: unknown) => Array.isArray(value) ? value.filter((id): id is string => typeof id === "string") : [];

/** Single-run status only checks the PID for RUNNING; other active states need the all-runs status. */
export function recordIsRunning(record: Record<string, unknown>, observedRunning?: boolean): boolean {
  const state = text(record.state) ?? "";
  if (terminalStates.has(state) || text(record.finishedAt)) return false;
  if (observedRunning !== undefined) return observedRunning;
  return activeStates.has(state) && (state !== "RUNNING" || record.running !== false);
}

/** A stopped process is presentation information, never a replacement for an engine verdict. */
export function runPresentationState(view: RunView): string {
  return view.done && activeStates.has(view.state) ? "INTERRUPTED" : view.state;
}

export function runRowPresentationState(run: FlowRunRow): string {
  return run.running === false && activeStates.has(run.state) ? "INTERRUPTED" : run.state;
}

/** Recover final metadata from run.json while retaining event output and the original saved plan's edges. */
export function recoverRunHistory(view: RunView, record: Record<string, unknown>, savedPlan?: unknown, observedRunning?: boolean): RunView {
  const finalRecord = terminalStates.has(text(record.state) ?? "") || !!text(record.finishedAt);
  const planned = nodes(object(savedPlan).nodes);
  const recorded = nodes(record.nodes);
  const eventNodes = new Map(view.nodes.map(node => [node.id, node]));
  const plans = new Map(planned.map(node => [String(node.id), node]));
  const records = new Map(recorded.map(node => [String(node.id), node]));
  const ids = [...new Set([...planned.map(node => String(node.id)), ...recorded.map(node => String(node.id)), ...view.nodes.map(node => node.id)])];
  const recovered: RunNode[] = ids.map(id => {
    const event = eventNodes.get(id);
    const plan = plans.get(id) ?? {};
    const rec = records.get(id) ?? {};
    const tests = object(rec.tests);
    return {
      id,
      title: text(rec.title) ?? event?.title ?? text(plan.title) ?? id,
      block: text(rec.block) ?? event?.block ?? text(plan.block) ?? "",
      needs: plans.has(id) ? needs(plan.needs) : event?.needs ?? [],
      branchOf: text(rec.branchOf) ?? event?.branchOf ?? text(plan.branchOf),
      state: (text(rec.state) ?? event?.state ?? "PENDING") as FlowNodeState,
      code: text(rec.code) ?? event?.code ?? null,
      durationMs: number(rec.durationMs) ?? event?.durationMs ?? null,
      testsPassed: number(tests.passed) ?? event?.testsPassed ?? null,
      testsExecuted: number(tests.executed) ?? event?.testsExecuted ?? null,
      reason: text(object(rec.reason).message) ?? text(rec.reason) ?? event?.reason ?? null,
      log: text(rec.log) ?? event?.log ?? null,
      tail: event?.tail.slice() ?? [],
    };
  });
  return {
    ...view,
    flow: text(record.flow) ?? view.flow,
    state: finalRecord || view.state === "PENDING" ? text(record.state) ?? view.state : view.state,
    code: finalRecord ? text(record.code) : view.code,
    exitCode: number(record.exitCode) ?? view.exitCode,
    nodes: recovered,
    done: view.done || !recordIsRunning(record, observedRunning),
  };
}
