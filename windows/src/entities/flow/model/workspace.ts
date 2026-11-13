import { runRowPresentationState } from "./history";
import type { RunView } from "./run-view";
import type { FlowPlanNode, FlowRunRow } from "./types";

/**
 * What the Flows workspace says about a flow before anyone opens a run: the one banner above the graph, the latest
 * run's state on each step, and which connectors belong to the failed path. Pure, so both platforms can test the
 * same answers. (macOS: Core/FlowWorkspaceSummary.swift)
 */

const passedStates = new Set(["SUCCEEDED", "PASSED", "CACHED"]);
const failedStates = new Set(["FAILED", "INDETERMINATE", "ROLLBACK_FAILED"]);
const runningStates = new Set(["RUNNING", "PREFLIGHT", "ROLLING_BACK"]);

/** The status tone a run or step state is drawn in (docs/design.md, Badges) */
export type FlowTone = "passed" | "failed" | "waiting" | "neutral";

export function flowTone(state: string | null | undefined): FlowTone {
  if (!state) return "neutral";
  if (passedStates.has(state)) return "passed";
  if (failedStates.has(state)) return "failed";
  if (runningStates.has(state) || ["ROLLED_BACK", "REJECTED", "INTERRUPTED"].includes(state)) return "waiting";
  return "neutral";
}

/** The single strip above the graph. Exactly one applies, in this order. */
export type FlowBanner =
  /** A run is going: say which step, and offer the run. */
  | { kind: "running"; runId: string; step: string | null; startedAt: string | null }
  /** The flow file is new or changed: its commands must be read before anything runs. */
  | { kind: "review" }
  /** The latest run ended: how, where it failed and what it skipped because of that. */
  | { kind: "finished"; runId: string; state: string; tone: FlowTone; failedStep: string | null; skipped: string[]; durationMs: number | null }
  /** Nothing ran yet: say what Run flow will do. */
  | { kind: "ready" };

export function flowBanner(input: { trusted: boolean; latest?: FlowRunRow | null; view?: RunView | null }): FlowBanner {
  const { trusted, latest, view } = input;
  const nodes = view && view.runId === latest?.runId ? view.nodes : [];
  if (latest?.running) {
    return { kind: "running", runId: latest.runId, step: nodes.find((node) => node.state === "RUNNING")?.id ?? null, startedAt: latest.startedAt ?? null };
  }
  if (!trusted) return { kind: "review" };
  if (!latest) return { kind: "ready" };
  const state = runRowPresentationState(latest);
  return {
    kind: "finished",
    runId: latest.runId,
    state,
    tone: flowTone(state),
    failedStep: nodes.find((node) => failedStates.has(node.state))?.id ?? null,
    skipped: nodes.filter((node) => node.state === "SKIPPED").map((node) => node.id),
    durationMs: latest.durationMs ?? null,
  };
}

/** One step as the graph and the step details show it: the plan's step with the latest run's outcome laid over it. */
export interface FlowStepView extends FlowPlanNode {
  /** The engine's state in the latest run, or what the plan already decided (skip, rejected); null before any run */
  state: string | null;
  durationMs: number | null;
}

/**
 * Lays the latest run over the plan. A step the run never saw (added since) keeps no state, so the graph never
 * claims a result the engine did not record.
 */
export function flowStepViews(plan: readonly FlowPlanNode[], view?: RunView | null): FlowStepView[] {
  const ran = new Map((view?.nodes ?? []).map((node) => [node.id, node]));
  return plan.map((node) => {
    const run = ran.get(node.id);
    const planned = node.decision === "skip" ? "SKIPPED" : node.decision === "rejected" ? "REJECTED" : null;
    // Once the run has ended, a step still marked waiting or running never finished: it has no result to show.
    const unfinished = !!view?.done && (run?.state === "RUNNING" || run?.state === "PENDING");
    return { ...node, state: run && !unfinished ? run.state : run ? null : planned, durationMs: run?.durationMs ?? null };
  });
}

/** A connector is red only on the failed path, and dashed into a step that was skipped. */
export function flowEdgeLook(from: string | null | undefined, to: string | null | undefined): { tone: "failed" | "neutral"; dashed: boolean } {
  const failed = failedStates.has(to ?? "") || failedStates.has(from ?? "");
  return { tone: failed ? "failed" : "neutral", dashed: to === "SKIPPED" };
}

/** Why a step was skipped, when the reason is on the graph: the first step it needs that did not pass. */
export function flowSkipCause(step: FlowStepView, steps: readonly FlowStepView[]): string | null {
  if (step.state !== "SKIPPED") return null;
  const byID = new Map(steps.map((entry) => [entry.id, entry]));
  return step.needs.find((id) => { const state = byID.get(id)?.state; return !!state && !passedStates.has(state); }) ?? null;
}

/** A step's own words, when the flow file gives it any beyond its name */
export function flowStepSummary(step: { id: string; title?: string | null }): string | null {
  const title = step.title?.trim();
  return title && title !== step.id && title !== "Command" ? title : null;
}

/** The first line a person would recognise from the step's script */
export function flowStepCommand(step: { run?: string | null }): string | null {
  return step.run?.split("\n").map((line) => line.trim()).find((line) => line && !line.startsWith("#")) ?? null;
}

/** The end of a step's output, with how many earlier lines are folded away */
export function flowLogTail(lines: readonly string[], shown: number): { hidden: number; lines: string[] } {
  const start = Math.max(0, lines.length - shown);
  return { hidden: start, lines: lines.slice(start) };
}
