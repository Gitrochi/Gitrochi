import { CircleCheck, CircleStop, CircleX, GitBranch, type LucideIcon, PauseCircle } from "lucide-react";
import { useEffect } from "react";
import type { LedgerSession, LedgerStore } from "@/entities/ledger";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { StatusPill, type StatusTone } from "@/shared/ui";
import { flowEvidenceFolders, type LedgerFlowOutcome, sessionInRepository } from "../lib/flow-evidence";
import { type LedgerFlowHost, ledgerFlowEvidence } from "../model/flow-evidence";
import { Section, When } from "./parts";

/** How often the row reads again while it is on screen: the Flows panel's pace when nothing runs */
const FLOW_EVIDENCE_POLL_MS = 30_000;

const looks: Record<LedgerFlowOutcome, { tone: StatusTone; icon: LucideIcon; label: string }> = {
  passed: { tone: "passed", icon: CircleCheck, label: "Passed" },
  failed: { tone: "failed", icon: CircleX, label: "Failed" },
  held: { tone: "waiting", icon: PauseCircle, label: "Held" },
  canceled: { tone: "neutral", icon: CircleStop, label: "Canceled" },
};

/** The engine's run state in words, as the Flows workspace says it */
const stateTitles: Record<string, string> = { SUCCEEDED: "Succeeded", FAILED: "Failed", REJECTED: "Rejected before running", ROLLED_BACK: "Failed and rolled back", ROLLBACK_FAILED: "Rollback failed — environment on hold", CANCELLED: "Canceled" };

/**
 * Checks: the latest Flow result of each flow recorded for the session's branch head commit, read-only, with Open in
 * Flows. Hidden without a repository, a branch, or a run for that commit. (macOS: Views/Ledger/LedgerFlowChecks.swift)
 */
export function FlowChecks({ store, session, host }: { store: LedgerStore; session: LedgerSession; host: LedgerFlowHost | undefined }) {
  useObserve(ledgerFlowEvidence);
  const repo = host?.path ?? null, branch = session.links.branch ?? null;
  const inRepository = !!host && !!repo && !!branch && sessionInRepository(session, { path: repo, worktrees: host.worktrees, project: store.repositoryProject });
  const folders = inRepository ? flowEvidenceFolders(repo!, host!.worktrees, branch!, session.links.worktree) : [];
  const key = inRepository ? [repo, branch, ...folders].join("\0") : null;
  useEffect(() => {
    if (!key || !repo || !branch) return;
    let stopped = false, timer: ReturnType<typeof setTimeout> | undefined;
    const read = async () => {
      await ledgerFlowEvidence.refresh(repo, branch, folders);
      if (!stopped) timer = setTimeout(() => void read(), FLOW_EVIDENCE_POLL_MS);
    };
    void read();
    return () => { stopped = true; if (timer) clearTimeout(timer); };
    // the folders are rebuilt on every render; the key says when they changed
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key]);
  const evidence = inRepository ? ledgerFlowEvidence.get(repo!, branch!) : null;
  if (!evidence?.results.length) return null;
  return (
    <Section title={t("Checks")} count={evidence.results.length} className="ledger-flow-checks" actions={<button type="button" className="link" data-open-flows onClick={() => host!.navigate("flows")}>{t("Open in Flows")}</button>}>
      <span className="hint ledger-flow-head" data-tip={t("Latest Flow runs recorded for this branch's head commit")}>
        <GitBranch size={12} /><span className="ellipsis">{branch}</span><span className="mono">{evidence.head.slice(0, 8)}</span>
      </span>
      {evidence.results.map(({ run, outcome }) => {
        const look = looks[outcome];
        return (
          <div key={run.runId} className="ledger-flow-result" data-flow-outcome={outcome}>
            <StatusPill tone={look.tone} icon={<look.icon size={12} strokeWidth={2.2} />} data-tip={t(stateTitles[run.state] ?? look.label)}>{t(look.label)}</StatusPill>
            <span className="ledger-row-text grow ellipsis" data-tip={run.runId}>{run.flow}</span>
            {run.finishedAt != null && <When at={run.finishedAt} />}
          </div>
        );
      })}
    </Section>
  );
}
