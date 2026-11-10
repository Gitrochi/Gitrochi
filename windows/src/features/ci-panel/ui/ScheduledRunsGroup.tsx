import { useEffect, useState } from "react";
import { type ScheduledRun, scheduledRunRelative, scheduledRuns, scheduledRunTime } from "@/entities/ci";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { CircleAlert, CircleX, Clock } from "@/shared/icons";
import { useObserve } from "@/shared/lib";
import { HostedListChip, HostedListTextButton, Spinner } from "@/shared/ui";

/**
 * The repository's runs scheduled for later, above the run list: which workflow (or pipeline) runs on which branch and
 * when, with Cancel, or Run now and Remove once it was missed or failed. Nothing is drawn without any.
 * (macOS: Views/Sidebar/ScheduledRunsGroup.swift)
 */
export function ScheduledRunsGroup({ store }: { store: RepoStore }) {
  const schedule = useObserve(scheduledRuns);
  const runs = schedule.forRepo(store.path);
  // the relative times move on while the page is open
  const [, tick] = useState(0);
  useEffect(() => {
    if (!runs.length) return;
    const timer = setInterval(() => tick((n) => n + 1), 30_000);
    return () => clearInterval(timer);
  }, [runs.length]);
  if (!runs.length) return null;
  const now = schedule.now();
  const title = (run: ScheduledRun) => run.workflowName ?? t("Pipeline");
  // starting a run that did not start on time asks once: it may be a deployment, and its moment has passed
  const runNow = (run: ScheduledRun) => store.ask({
    title: t("Start this run now?"),
    message: `${title(run)} · ${run.ref}`,
    actionTitle: t("Run"),
    destructive: false,
    action: () => schedule.runNow(run.id),
  });
  return (
    <section className="ci-scheduled" aria-label={t("Scheduled runs")}>
      <div className="ci-scheduled-head"><Clock size={12} />{t("Scheduled")}</div>
      {runs.map((run) => (
        <div key={run.id} className="ci-scheduled-run" data-scheduled={run.id} data-state={run.state}>
          <div className="ci-scheduled-top">
            <span className="ci-scheduled-title ellipsis">{title(run)}</span>
            {/* the branch gives way first, from the front */}
            <span className="ci-scheduled-ref">{run.ref}</span>
            <span className="spacer" />
            {schedule.starting.has(run.id) ? (
              <Spinner size={11} />
            ) : run.state === "scheduled" ? (
              <HostedListTextButton onClick={() => schedule.remove(run.id)}>{t("Cancel")}</HostedListTextButton>
            ) : (
              <>
                <HostedListTextButton onClick={() => runNow(run)}>{t("Run now")}</HostedListTextButton>
                <HostedListTextButton destructive onClick={() => schedule.remove(run.id)}>{t("Remove")}</HostedListTextButton>
              </>
            )}
          </div>
          <div className="ci-scheduled-meta">
            {run.state === "missed" && <HostedListChip tone="waiting" icon={<CircleAlert size={11} />}>{t("Missed")}</HostedListChip>}
            {run.state === "failed" && <HostedListChip tone="failed" icon={<CircleX size={11} />}>{t("Failed")}</HostedListChip>}
            <span className="ci-scheduled-when">{scheduledRunTime(run.runAt, now)} · {scheduledRunRelative(run.runAt, now)}</span>
          </div>
          {run.state === "failed" && run.message && <span className="ci-scheduled-error status-tone selectable" data-tone="failed" title={run.message}>{run.message}</span>}
        </div>
      ))}
    </section>
  );
}
