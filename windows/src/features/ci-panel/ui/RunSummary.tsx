import { useEffect } from "react";
import { type CIPipeline, CIStatusIcon, isActiveCI, isFinishedCI, runBaseRef, runHistory, runStreak, type RunStreak, runSummaryCard, runTook } from "@/entities/ci";
import { branchShort } from "@/entities/git";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { listWhen, useObserve } from "@/shared/lib";
import { Button, HostedListSummary, HostedListSummaryBar, HostedListSummaryBars, HostedListSummaryLoadingLine, HostedListSummaryMessage, Spinner, type StatusTone } from "@/shared/ui";
import { duration, runName } from "./CIRunDetail";

/** How this branch's latest runs went, oldest to newest, and what the newest one needs (macOS: RunSummaryCard) */
export function RunSummary({ store }: { store: RepoStore }) {
  useObserve(store);
  const ci = useObserve(store.ci);
  const provider = store.target?.provider ?? "github";
  const ref = ci.currentRef;
  const history = runHistory(ci.pipelines, ref), streak = runStreak(history), latest = history[history.length - 1];
  const name = ref ?? store.headBranch ?? t("Detached HEAD");
  const card = runSummaryCard(history.length, ci.pipelines.length, ci.state.kind === "loading" || ci.state.kind === "idle", ci.state.kind === "loaded");
  // the newest finished run of the branch runs are compared with, unless this is that branch
  const baseName = runBaseRef([...store.localBranches.map((branch) => branch.name), ...store.remoteBranches.map(branchShort)]);
  const base = baseName && baseName !== ref ? ci.pipelines.find((run) => run.ref === baseName && (run.status === "success" || run.status === "failed")) : undefined;
  const label = streakLabel(store, streak);
  const showRun = (run: CIPipeline) => <Button onClick={() => store.selectRun(run)}>{t("Show run")}</Button>;
  // "Latest run · 6 of 6 jobs · 6m 12s", with the jobs and the time only when they are known
  const latestFacts = () => {
    const facts = [t("Latest run")], jobs = latest ? ci.jobs.get(latest.id) : undefined, took = latest ? runTook(latest) : null;
    if (jobs?.length) facts.push(t("{0} of {1} jobs", jobs.filter((job) => job.status === "success").length, jobs.length));
    if (took != null) facts.push(duration(took));
    return facts.join(" · ");
  };
  const start = streak.kind === "running" ? streak.run.started ?? streak.run.created : null;
  // the summary counts the latest run's jobs, which the list alone does not load
  const latestID = latest?.id;
  useEffect(() => { if (latest && !ci.jobs.has(latest.id)) void ci.loadJobs(latest); }, [latestID]);
  return (
    <HostedListSummary
      label={t("This branch's runs")}
      lead={
        <>
          <span className="hosted-summary-key">{t("This branch")}</span>
          {/* a branch name is cut from the front, where it says least */}
          <span className="hosted-summary-value ci-summary-branch"><bdi>{name}</bdi></span>
          {card === "loading" ? <HostedListSummaryLoadingLine caption={t("Loading runs…")} />
            : base ? <span className="hosted-caption ci-summary-base"><CIStatusIcon status={base.status} size={12} /><span className="ellipsis">{t(base.status === "success" ? "{0} passes on {1}" : "{0} fails on {1}", base.ref, runName(provider, base))}</span></span> : null}
        </>
      }
      middle={card === "loading" ? <HostedListSummaryBars />
        : card === "empty" ? <HostedListSummaryMessage title={t("No runs on this branch yet")} />
        : card === "unknown" ? null : (
        <div className="ci-track" role="img" aria-label={label?.text ?? ""}>
          {label && <div className="ci-track-label status-tone" data-tone={label.tone}>{label.text}</div>}
          {/* the runs as nodes on a line, each with its status icon and its number; the newest is the dark one */}
          <div className="ci-track-runs">
            {history.map((run, index) => (
              <div key={run.id} className={`ci-track-node${index === history.length - 1 ? " latest" : ""}${index > 0 ? (isActiveCI(run.status) ? " joined dashed" : " joined") : ""}`}>
                <span className="ci-track-icon"><CIStatusIcon status={run.status} size={14} /></span>
                <span className="mono">{runName(provider, run)}</span>
              </div>
            ))}
          </div>
        </div>
      )}
      trail={
        card === "loading" ? <HostedListSummaryBar />
          : streak.kind === "failed" ? <>{showRun(streak.run)}{runTook(streak.run) != null && <span className="hosted-caption">{t("Failed after {0}", duration(runTook(streak.run)!))}</span>}</>
          : streak.kind === "waiting" ? showRun(streak.run)
          : streak.kind === "running" ? (start != null ? <span className="hosted-caption">{t("Started {0}", listWhen(start))}</span> : null)
          : latest ? <span className="hosted-caption">{latestFacts()}</span> : null
      }
      strip={
        <>
          {card === "loading" ? <Spinner size={14} /> : latest && <CIStatusIcon status={latest.status} size={14} />}
          <span className="hosted-strip-text ci-summary-branch"><bdi>{name}</bdi></span>
          {label ? <span className="ci-strip-label status-tone" data-tone={label.tone}>{label.text}</span>
            : card === "loading" ? <span className="hosted-caption ellipsis">{t("Loading runs…")}</span>
            : card === "empty" ? <span className="hosted-caption ellipsis">{t("No runs on this branch yet")}</span> : null}
          <span className="spacer" />
          {streak.kind === "failed" ? showRun(streak.run) : latest ? <span className="hosted-caption" style={{ flex: "none" }}>{runName(provider, latest)}</span> : null}
        </>
      }
    />
  );
}

/** What the newest run says, in its tone; the icon beside each run says it too */
function streakLabel(store: RepoStore, streak: RunStreak): { text: string; tone: StatusTone } | null {
  const provider = store.target?.provider ?? "github";
  switch (streak.kind) {
    case "none": return null;
    case "passing": return { text: streak.count === 1 ? t("Passing for 1 run") : t("Passing for {0} runs", streak.count), tone: "passed" };
    case "failed": {
      const job = store.ci.jobs.get(streak.run.id)?.find((value) => value.status === "failed" && !value.allowFailure)?.name;
      return { text: t("Failed on {0}", runName(provider, streak.run)) + (job ? ` · ${job}` : ""), tone: "failed" };
    }
    case "running": {
      const jobs = store.ci.jobs.get(streak.run.id);
      return { text: jobs?.length ? t("Running · {0} of {1} jobs done", jobs.filter((job) => isFinishedCI(job.status)).length, jobs.length) : t("Running"), tone: "waiting" };
    }
    case "waiting": return { text: t("Waiting"), tone: "waiting" };
  }
}
