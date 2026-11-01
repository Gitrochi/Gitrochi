import { Archive, CircleCheck, CircleDot, ClockAlert, GitMerge, Library, type LucideIcon, MessageCircleQuestion, PackageCheck } from "lucide-react";
import type { CSSProperties, ReactNode } from "react";
import { type AnswerKind, type LedgerSession, type LedgerVerdict, type VerdictIcon, verdictLook } from "@/entities/ledger";
import { t } from "@/shared/i18n";
import { laneColor, longDate, shortDate } from "@/shared/lib";
import { tip } from "@/shared/ui";

const verdictIcons: Record<VerdictIcon, LucideIcon> = { question: MessageCircleQuestion, merge: GitMerge, confirm: CircleCheck, archive: Archive, stale: ClockAlert, active: CircleDot, shelved: Library, archived: PackageCheck };

export const verdictIcon = (verdict: LedgerVerdict) => verdictIcons[verdictLook(verdict).icon];

/** A verdict as a pill with its symbol, label and the contract's colour; "To confirm" is an outline. (macOS: LedgerVerdictBadge) */
export function VerdictBadge({ verdict, count, iconOnly }: { verdict: LedgerVerdict; count?: number; iconOnly?: boolean }) {
  const look = verdictLook(verdict), Icon = verdictIcons[look.icon], label = t(look.label);
  return (
    <span className={`ledger-verdict${look.outline ? " outline" : ""}`} style={{ "--verdict": `var(${look.color})` } as CSSProperties} data-tip={tip(label, t(look.hint))} aria-label={iconOnly ? label : undefined}>
      <Icon size={12} strokeWidth={2.2} />
      {!iconOnly && <span>{label}</span>}
      {count !== undefined && <span className="ledger-verdict-count">{count}</span>}
    </span>
  );
}

/** A session's ID next to its lane colour, as every row shows it */
export function SessionId({ session }: { session: Pick<LedgerSession, "id" | "color"> }) {
  return (
    <span className="ledger-id mono">
      <span className="ledger-id-dot" style={{ background: laneColor(session.color) }} />
      {session.id}
    </span>
  );
}

/** "3 hours ago" with the full date on hover */
export function When({ at }: { at: number }) {
  return <span className="ledger-when" data-tip={longDate(at / 1000)}>{shortDate(at / 1000)}</span>;
}

/** Base → current, and how far behind the newest baseline the session is */
export function BaseLine({ session, behind }: { session: LedgerSession; behind?: number }) {
  if (!session.baseVersion && !session.baseCurrent) return null;
  const current = session.baseCurrent ?? session.baseVersion;
  return (
    <span className="ledger-base mono" data-tip={t("Baseline it started from → the one it is on now")}>
      {session.baseVersion && session.baseVersion !== current ? `${session.baseVersion} → ${current}` : current}
      {!!behind && <span className="ledger-behind">{t("{0} behind", behind)}</span>}
    </span>
  );
}

const answerKinds: Record<AnswerKind, string> = { text: "", allow: "Allow", deny: "Deny", approve: "Approve the plan", release: "Left to the terminal", hold: "No automatic answer", unknown: "Continue" };

/** An answer in the person's words: the reply text, or what the decision was */
export const answerText = (answer: { kind: AnswerKind; text: string }) => (answer.kind === "text" ? answer.text : answer.text ? `${t(answerKinds[answer.kind])}: ${answer.text}` : t(answerKinds[answer.kind]));

/** A small titled block in a column */
export function Section({ title, count, actions, children, className = "" }: { title: string; count?: number; actions?: ReactNode; children: ReactNode; className?: string }) {
  return (
    <section className={`ledger-section ${className}`}>
      <header className="ledger-section-head">
        <span className="ellipsis">{title}</span>
        {count !== undefined && <span className="counter">{count}</span>}
        <span className="spacer" />
        {actions}
      </header>
      {children}
    </section>
  );
}

/** Whether a page is on screen; a hidden tab keeps its page mounted, and only the visible one takes keys */
export const onScreen = (el: Element | null) => !!el && el.getClientRects().length > 0;

/** Keys that never act while a person types, or when a sheet is open */
export function typing(e: KeyboardEvent) {
  const el = e.target as HTMLElement | null;
  if (document.querySelector(".modal-backdrop")) return true;
  return !!el && (el.tagName === "INPUT" || el.tagName === "TEXTAREA" || el.tagName === "SELECT" || el.isContentEditable || !!el.closest?.(".xterm"));
}
