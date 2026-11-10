import { cloneElement, type ButtonHTMLAttributes, type ReactElement, type ReactNode, useId } from "react";
import { CircleX } from "@/shared/icons";
import { t } from "@/shared/i18n";
import type { StatusTone } from "./StatusPill";
import { Button, Spinner } from "./ui";
import "./status-pill.css";
import "./notice-block.css";

/**
 * One form each for what failed, for what needs the user, and for why a button can't be used (docs/design.md,
 * Controls). (macOS: Views/Shared/NoticeBlock.swift)
 */

/** A notice's button: plain, unless it is the region's one main action */
export type NoticeAction = {
  label: string;
  onClick: () => void;
  filled?: boolean;
  /** Why it can't be used now: the button is disabled and says so beside it */
  disabledReason?: string | null;
};

/**
 * A white strip with a 1 px border (a tint means selection): a 14 px icon, a 13 px semibold line in its tone, a 12 px
 * caption and the actions. One action sits on the right; two go on a row below the words.
 */
export function NoticeBlock({ icon, tone = "waiting", title, caption, detail, actions = [], busy = false, alert = false, className = "" }: {
  icon: ReactNode;
  tone?: StatusTone;
  title: string;
  caption?: string | null;
  /** The server's own words, on hover */
  detail?: string | null;
  actions?: NoticeAction[];
  /** Something is under way (an approval, a retry): a spinner beside the actions, which wait for it */
  busy?: boolean;
  /** A failure is announced at once; a notice waits its turn */
  alert?: boolean;
  className?: string;
}) {
  const buttons = (actions.length > 0 || busy) && (
    <span className="notice-block-actions">
      {busy && <Spinner size={12} />}
      {actions.map((action) => (
        <DisabledReason key={action.label} reason={action.disabledReason}>
          <Button kind={action.filled ? "primary" : "default"} disabled={busy} onClick={action.onClick}>{action.label}</Button>
        </DisabledReason>
      ))}
    </span>
  );
  return (
    <div className={`notice-block status-tone ${className}`} data-tone={tone} role={alert ? "alert" : "status"} title={detail ?? undefined}>
      <span className="notice-block-icon" aria-hidden>{icon}</span>
      {/* one action sits on the right while the words keep 160px, and drops below them in a narrow column */}
      <span className="notice-block-body">
        <span className="notice-block-text">
          <span className="notice-block-title selectable">{title}</span>
          {caption && <span className="notice-block-caption selectable">{caption}</span>}
          {actions.length > 1 && buttons}
        </span>
        {(actions.length === 1 || (!actions.length && busy)) && buttons}
      </span>
    </div>
  );
}

/**
 * What failed, placed next to it: the failed icon, "Couldn't reach github.com", a caption (how old the data on screen
 * is, or what went wrong) and a plain Retry
 */
export function FailureBlock({ title, caption, detail, retrying = false, retry, className }: {
  title: string;
  caption?: string | null;
  /** The server's own words, on hover */
  detail?: string | null;
  /** A retry is under way */
  retrying?: boolean;
  retry: () => void;
  className?: string;
}) {
  return (
    <NoticeBlock icon={<CircleX size={14} />} tone="failed" alert title={title} caption={caption} detail={detail}
      actions={[{ label: t("Retry"), onClick: retry }]} busy={retrying} className={`failure-block ${className ?? ""}`} />
  );
}

/** The reason a primary action gives while a failure above it blocks it */
export const retryAbove = () => t("Retry above");

/** A disabled button says why, in 12 px grey 8 px before it; without a reason it is the button alone */
export function DisabledReason({ reason, children }: { reason?: string | null; children: ReactElement<ButtonHTMLAttributes<HTMLButtonElement>> }) {
  const id = useId();
  if (!reason) return children;
  return (
    <span className="disabled-reason">
      <span id={id} className="disabled-reason-text">{reason}</span>
      {cloneElement(children, { disabled: true, "aria-describedby": id })}
    </span>
  );
}
