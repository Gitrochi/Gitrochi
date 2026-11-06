import { CircleCheck, CircleX, GitMerge, GitPullRequestClosed, GitPullRequestDraft, type LucideIcon } from "lucide-react";
import { Clock, GitPullRequest } from "@/shared/icons";
import { useEffect } from "react";
import { workStateTitle } from "@/entities/hosting";
import type { LedgerSession, LedgerStore } from "@/entities/ledger";
import { ipc } from "@/shared/api";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, StatusPill, type StatusTone } from "@/shared/ui";
import { type LedgerRequestChecks, ledgerRequestLink, type LedgerRequestState, type LedgerRequestStatus, requestPollMs } from "../lib/request-status";
import { type LedgerRequestHost, ledgerRequestStatus } from "../model/request-status";

/**
 * The session's linked request in the open repository and what is known of it. With `follow` it is read again while
 * on screen (requestPollMs); without, once per freshness period. No host, another repository or no account: no link,
 * no read, and the chip stays as it was.
 */
export function useLedgerRequest(session: LedgerSession | undefined, store: LedgerStore, host: LedgerRequestHost | undefined, follow: boolean) {
  useObserve(ledgerRequestStatus);
  const link = session && host ? ledgerRequestLink(session, { path: host.path, project: store.repositoryProject, target: host.hostingAccount ? host.target : null }) : null;
  const key = link?.key ?? null;
  useEffect(() => {
    if (!link || !host) return;
    let stopped = false, timer: ReturnType<typeof setTimeout> | undefined;
    const read = async (maxAge?: number) => {
      await ledgerRequestStatus.refresh(link, host, maxAge);
      const wait = follow ? requestPollMs(ledgerRequestStatus.status(link)) : null;
      if (!stopped && wait != null) timer = setTimeout(() => void read(wait), wait);
    };
    void read();
    return () => { stopped = true; if (timer) clearTimeout(timer); };
    // the link is rebuilt on every render; its key says when it changed
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key, host, follow]);
  return { link, status: ledgerRequestStatus.status(link) };
}

const stateLooks: Record<LedgerRequestState, { tone: StatusTone; icon: LucideIcon; label: () => string }> = {
  open: { tone: "passed", icon: GitPullRequest, label: () => workStateTitle("open") },
  draft: { tone: "waiting", icon: GitPullRequestDraft, label: () => t("Draft") },
  merged: { tone: "neutral", icon: GitMerge, label: () => workStateTitle("merged") },
  closed: { tone: "neutral", icon: GitPullRequestClosed, label: () => workStateTitle("closed") },
};

const checkLooks: Record<LedgerRequestChecks["state"], { tone: StatusTone; icon: LucideIcon; label: string }> = {
  passing: { tone: "passed", icon: CircleCheck, label: "{0} passing" },
  failing: { tone: "failed", icon: CircleX, label: "{0} failing" },
  pending: { tone: "waiting", icon: Clock, label: "{0} pending" },
};

/**
 * The "#142" chip, with the request's state and checks as status pills once they have been read (docs/design.md,
 * Badges); until then the chip alone, exactly as before. (macOS: LedgerRequestChip)
 */
export function RequestChip({ pr, status }: { pr: NonNullable<LedgerSession["links"]["pr"]>; status: LedgerRequestStatus | null }) {
  const chip = <button type="button" className="ledger-link" data-tip={pr.url} onClick={() => void ipc.openUrl(pr.url)}><GitPullRequest size={12} /><span>#{pr.number}</span></button>;
  if (!status) return chip;
  const state = stateLooks[status.state], checks = status.checks ? checkLooks[status.checks.state] : null;
  return (
    <span className="ledger-request" data-request-state={status.state}>
      {chip}
      <StatusPill tone={state.tone} icon={<state.icon size={12} strokeWidth={2.2} />} data-tip={`#${pr.number} · ${state.label()}`}>{state.label()}</StatusPill>
      {checks && status.checks && (
        <StatusPill tone={checks.tone} icon={<checks.icon size={12} strokeWidth={2.2} />} data-tip={t("Checks on the request's latest commit")} data-request-checks={status.checks.state}>
          {t(checks.label, status.checks.count)}
        </StatusPill>
      )}
    </span>
  );
}

/**
 * "Request merged — mark merged?" as a strip (1px border, 14px icon): `onChoose` opens the existing Mark merged… picker
 * under the button. It only suggests; the Ledger changes when a person picks a version. (macOS: LedgerRequestMergedSuggestion)
 */
export function RequestMergedSuggestion({ disabled, onChoose }: { disabled: boolean; onChoose: (anchor: HTMLElement) => void }) {
  return (
    <div className="ledger-request-merged" data-tip={t("The request was merged on the server. Choose the version this work went into; the Ledger changes only when you do.")}>
      <GitMerge size={14} aria-hidden />
      <Button size="small" disabled={disabled} data-request-merged onClick={(e) => onChoose(e.currentTarget)}>{t("Request merged — mark merged?")}</Button>
    </div>
  );
}
