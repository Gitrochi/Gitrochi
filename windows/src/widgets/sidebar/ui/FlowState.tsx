import { Bell, Circle, CircleCheck, CircleSlash, CircleX, Cloud, Container, Database, FlaskConical, MinusCircle, Rocket, RotateCcw, ShieldCheck, Terminal, Wrench } from "lucide-react";
import type { ReactNode } from "react";
import { t } from "@/shared/i18n";
import { Spinner } from "@/shared/ui";

export function stateTitle(s: string | null | undefined): string {
  switch (s) {
    case "SUCCEEDED":
      return t("Succeeded");
    case "PASSED":
      return t("Passed");
    case "CACHED":
      return t("Passed before with the same inputs");
    case "FAILED":
      return t("Failed");
    case "INDETERMINATE":
      return t("Couldn't judge (counts as a failure)");
    case "REJECTED":
      return t("Rejected before running");
    case "ROLLING_BACK":
      return t("Rolling back");
    case "ROLLED_BACK":
      return t("Failed and rolled back");
    case "ROLLBACK_FAILED":
      return t("Rollback failed — environment on hold");
    case "CANCELLED":
      return t("Canceled");
    case "RUNNING":
    case "PREFLIGHT":
      return t("Running");
    case "SKIPPED":
      return t("Skipped");
    case "PENDING":
      return t("Waiting");
    case "INTERRUPTED":
      return t("Interrupted");
    default:
      return t("Not run yet");
  }
}

/** Semantic colors are shared by cards, connectors and history badges. */
export function flowStateTone(state: string | null | undefined): string {
  if (["SUCCEEDED", "PASSED", "CACHED"].includes(state ?? "")) return "success";
  if (["FAILED", "INDETERMINATE", "ROLLBACK_FAILED"].includes(state ?? "")) return "failure";
  if (["RUNNING", "PREFLIGHT"].includes(state ?? "")) return "active";
  if (["ROLLED_BACK", "ROLLING_BACK", "REJECTED", "INTERRUPTED"].includes(state ?? "")) return "warning";
  return "neutral";
}

/** Compact status text retains the full verdict on hover. */
export function FlowStatePill({ state, compact = false }: { state: string | null; compact?: boolean }) {
  const label = compact && state === "CACHED" ? stateTitle("PASSED") : compact && state === "INDETERMINATE" ? stateTitle("FAILED") : stateTitle(state);
  return <span className={`flow-state-pill ${flowStateTone(state)}`} data-tip={stateTitle(state)}><FlowStateIcon state={state} size={11} /><span>{label}</span></span>;
}

export function flowBlockKind(block: string): string {
  if (block.startsWith("test.") || block.startsWith("check.")) return "test";
  if (block.startsWith("ci.")) return "ci";
  if (block.startsWith("docker.") || block.startsWith("compose.")) return "container";
  if (block.startsWith("deploy.")) return "deploy";
  if (block.startsWith("gate.")) return "gate";
  if (block.startsWith("notify.")) return "notify";
  if (block.startsWith("setup.")) return "setup";
  if (block.startsWith("fixture.") || block.startsWith("mock.")) return "fixture";
  return "script";
}

/** The engine's block identifier determines its icon without inferring a verdict. */
export function FlowBlockIcon({ block, size = 16 }: { block: string; size?: number }) {
  switch (flowBlockKind(block)) {
    case "test": return <FlaskConical size={size} />;
    case "ci": return <Cloud size={size} />;
    case "container": return <Container size={size} />;
    case "deploy": return <Rocket size={size} />;
    case "gate": return <ShieldCheck size={size} />;
    case "notify": return <Bell size={size} />;
    case "setup": return <Wrench size={size} />;
    case "fixture": return <Database size={size} />;
    default: return <Terminal size={size} />;
  }
}

/** Run and node state icon (spinning while running) */
export function FlowStateIcon({ state, size = 14 }: { state: string | null; size?: number }) {
  const title = stateTitle(state);
  if (state === "RUNNING" || state === "PREFLIGHT") {
    return (
      <span data-tip={title} aria-label={title} style={{ display: "inline-flex", width: size, justifyContent: "center", flex: "none" }}>
        <Spinner size={size - 2} />
      </span>
    );
  }
  let icon: ReactNode = <Circle size={size} />;
  let color = "var(--text-3)";
  if (state === "SUCCEEDED" || state === "PASSED" || state === "CACHED") {
    icon = <CircleCheck size={size} />;
    color = "var(--green)";
  } else if (state === "FAILED" || state === "INDETERMINATE" || state === "ROLLBACK_FAILED") {
    icon = <CircleX size={size} />;
    color = "var(--red)";
  } else if (state === "ROLLED_BACK" || state === "ROLLING_BACK") {
    icon = <RotateCcw size={size} />;
    color = "var(--orange)";
  } else if (state === "REJECTED" || state === "INTERRUPTED") {
    icon = <CircleSlash size={size} />;
    color = "var(--orange)";
  } else if (state === "SKIPPED" || state === "CANCELLED") {
    icon = <MinusCircle size={size} />;
  }
  return (
    <span data-tip={title} aria-label={title} style={{ color, display: "inline-flex", flex: "none" }}>
      {icon}
    </span>
  );
}
