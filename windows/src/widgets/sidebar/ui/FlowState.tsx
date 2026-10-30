import { Circle, CircleCheck, CircleSlash, CircleX, MinusCircle, RotateCcw } from "lucide-react";
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
