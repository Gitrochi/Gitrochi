import { CircleStop, Hand, TriangleAlert } from "lucide-react";
import { CirclePlay } from "@/shared/icons";
import { Ellipsis, ExternalLink, RotateCw } from "@/shared/icons";
import { type MouseEvent, type ReactNode, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import {
  canPlay,
  type CIDeployment,
  type CIJob,
  type CIPipeline,
  type CIStatus,
  CIStatusIcon,
  eventTitle,
  firstLogLine,
  isActiveCI,
  isFinishedCI,
  isLogError,
  type JobGroup,
  jobGroups,
  runTook,
  statusInfo,
} from "@/entities/ci";
import type { Provider } from "@/entities/git";
import { accounts, workspaceJobLog } from "@/entities/hosting";
import type { RepoStore } from "@/entities/repo";
import { settings } from "@/shared/config";
import { t } from "@/shared/i18n";
import { listWhen, useObserve } from "@/shared/lib";
import { Button, HostedListChip, HostedListIconButton, HostedListTextButton, IconButton, type MenuItem, showContextMenu, showMenuBelow, Spinner, StatusPill, type StatusTone } from "@/shared/ui";

/**
 * The run picked on the Actions page, as the Actions board draws it: which run and its state, the title with its
 * actions, the branch, commit and how long it took; then the jobs by result on the left and the picked job's log on
 * the right. (macOS: CIRunDetailView.swift)
 */
export function CIRunDetail({
  store,
  pipeline: p,
}: {
  store: RepoStore;
  pipeline: CIPipeline;
}) {
  useObserve(store);
  const ci = useObserve(store.ci);
  const provider = store.target?.provider ?? "gitlab";
  const jobs = ci.jobs.get(p.id);
  const [job, setJob] = useState<number | null>(null);
  // the run whose failed job was already opened once; closing that log keeps it closed
  const autoOpened = useRef<number | null>(null);
  useEffect(() => setJob(null), [p.id]);
  useEffect(() => {
    if (!jobs || autoOpened.current === p.id) return;
    autoOpened.current = p.id;
    // a failed run opens on its first failed job, where the reason usually is
    const failed = jobs.find((j) => j.status === "failed" && !j.allowFailure);
    if (failed) setJob((cur) => cur ?? failed.id);
  }, [jobs, p.id]);
  const selected = jobs?.find((j) => j.id === job) ?? null;
  const busy = ci.busy.has(`pipeline:${p.id}`);
  const deployments = ci.deployments.get(p.id) ?? [];
  const trigger = [eventTitle(p.event), p.actor ? `@${p.actor}` : ""]
    .filter(Boolean)
    .join(" · ");
  const took = runTook(p), start = p.started ?? p.created;
  const more = t("More run actions");
  return (
    <div className="ci-run-detail col">
      <header className="ci-run-head">
        <div className="ci-run-head-top">
          <span className="ci-run-which">{p.name && `${p.name} · `}<span className="mono">{runName(provider, p)}</span></span>
          <StatusPill tone={statusTone(p.status)} icon={<CIStatusIcon status={p.status} size={12} plain />}>{statusInfo[p.status].title}</StatusPill>
          {busy && <Spinner size={12} />}
        </div>
        <div className="ci-run-head-title">
          <h2 className="selectable">{runTitle(store, p)}</h2>
          {/* Open in browser stays in sight; rerunning, cancelling and the rest are in the More menu */}
          <div className="ci-run-head-actions">
            <Button onClick={() => store.openUrl(p.url)}>
              <ExternalLink size={14} />
              {t("Open in browser")}
            </Button>
            <HostedListIconButton label={more} aria-haspopup="menu" onClick={(event) => showMenuBelow(event.currentTarget, [
              ...runCommands(store, p, provider, busy),
              "divider",
              { label: t("View commit"), onClick: () => store.reveal(p.sha) },
              { label: t("Copy link"), onClick: () => store.copy(p.url) },
              { label: t("Refresh"), onClick: () => void ci.loadJobs(p) },
            ])}>
              <Ellipsis size={14} />
            </HostedListIconButton>
          </div>
        </div>
        <div className="ci-run-head-meta">
          {/* a branch name is set in the UI font, a commit in the monospaced one */}
          <HostedListChip square>{p.ref}</HostedListChip>
          <button className="ci-link mono" data-tip={t("View commit")} onClick={() => store.reveal(p.sha)}>{p.sha.slice(0, 7)}</button>
          {p.request != null && (
            <button className="ci-link" onClick={() => { store.navigate("pullRequests"); store.select({ kind: "pullRequest", number: p.request! }); }}>
              {t("Pull request #{0}", String(p.request))}
            </button>
          )}
          {/* the list row owns the date; the detail says how long the run took */}
          {took != null ? <span>{t("Took {0}", duration(took))}</span> : isActiveCI(p.status) && start != null ? <span>{t("Started {0}", listWhen(start))}</span> : null}
          {trigger && <span>{trigger}</span>}
        </div>
      </header>
      {deployments.length > 0 && <DeploymentApproval store={store} pipeline={p} deployments={deployments} />}
      <div className="ci-run-body">
        <nav className="ci-run-jobs" aria-label={t("Jobs")}>
          {!jobs ? (
            <Spinner size={12} />
          ) : !jobs.length ? (
            <span className="hosted-caption">{t("No jobs")}</span>
          ) : (
            // the jobs by result, what failed first; each group says how many it holds
            jobGroups(jobs).map(({ group, jobs: list }) => (
              <section key={group} className="ci-job-group">
                <span className="ci-job-group-title">{jobGroupTitle(group)} {list.length}</span>
                {list.map((j) => (
                  <JobRow
                    key={j.id}
                    store={store}
                    job={j}
                    pipeline={p}
                    selected={j.id === job}
                    select={() => setJob(j.id)}
                  />
                ))}
              </section>
            ))
          )}
        </nav>
        <div className="ci-run-log col">
          {selected ? (
            <JobLog store={store} job={selected} pipeline={p} close={() => setJob(null)} />
          ) : (
            <div className="ci-log-empty hosted-caption">
              {jobs?.length ? t("Choose a job to read its log here.") : null}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

/** GitLab runs have no title; the local commit's subject stands in */
export function runTitle(store: RepoStore, p: CIPipeline) {
  return p.title || store.ci.subject(p.sha) || p.name || p.sha.slice(0, 8);
}

/** Runs are written "run #318", never a bare number (docs/design.md, Text); GitLab calls them pipelines */
export function runName(provider: Provider, p: CIPipeline) {
  return provider === "gitlab" ? t("pipeline #{0}", String(p.number)) : t("run #{0}", String(p.number));
}

/** The tone a status badge takes; a status never uses the accent */
export function statusTone(status: CIStatus): StatusTone {
  if (status === "success") return "passed";
  if (status === "failed") return "failed";
  return status === "canceled" || status === "skipped" || status === "neutral" || status === "unknown" ? "neutral" : "waiting";
}

/** "5m 48s" */
export function duration(s: number) {
  const secs = Math.round(s);
  return secs >= 60
    ? t("{0}m {1}s", Math.floor(secs / 60), secs % 60)
    : t("{0}s", secs);
}

const jobGroupTitle = (group: JobGroup) =>
  t(({ failed: "Failed", running: "Running", waiting: "Waiting", passed: "Passed", other: "Other" } as const)[group]);

/** Cancelling a run that is going, or rerunning one that ended */
function runCommands(store: RepoStore, p: CIPipeline, provider: Provider, busy = false): MenuItem[] {
  const ci = store.ci;
  const failed = p.status === "failed" || p.status === "canceled";
  if (isActiveCI(p.status)) return [{ label: t("Cancel run"), disabled: busy, onClick: () => ci.cancelPipeline(p) }];
  if (provider === "github")
    return [
      { label: t("Rerun failed jobs only"), disabled: busy || !failed, onClick: () => void ci.retryPipeline(p, true) },
      { label: t("Rerun all jobs"), disabled: busy, onClick: () => void ci.retryPipeline(p, false) },
    ];
  return [{ label: t("Rerun failed and canceled jobs"), disabled: busy || !failed, onClick: () => void ci.retryPipeline(p, true) }];
}

/** The run's commands, for the list's context menu */
export function runMenu(
  e: MouseEvent,
  store: RepoStore,
  p: CIPipeline,
  provider: Provider,
) {
  showContextMenu(e, [
    { label: t("Open in browser"), onClick: () => store.openUrl(p.url) },
    { label: t("View commit"), onClick: () => store.reveal(p.sha) },
    "divider",
    ...runCommands(store, p, provider),
    "divider",
    { label: t("Copy link"), onClick: () => store.copy(p.url) },
  ]);
}

/**
 * The picked job's log, read with the account and masked for secrets; it stays on this computer.
 * A running job's log is read again every ten seconds. Lines that name an error are marked in the failed tone; a log
 * without one opens at its end and keeps following the end while it is there, one with an error opens on it.
 */
function JobLog({
  store,
  job,
  pipeline,
  close,
}: {
  store: RepoStore;
  job: CIJob;
  pipeline: CIPipeline;
  close: () => void;
}) {
  useObserve(accounts);
  useObserve(settings);
  const wrap = settings.get<boolean>("ciLogWrap", true);
  const [text, setText] = useState(""),
    [error, setError] = useState(""),
    [busy, setBusy] = useState(false),
    [truncated, setTruncated] = useState(false),
    [reload, setReload] = useState(0),
    // the lines before the part the log opens on are shown on request
    [showAll, setShowAll] = useState(false);
  const generation = useRef(0),
    loaded = useRef<number | null>(null),
    following = useRef(true),
    box = useRef<HTMLDivElement>(null);
  const identity = `${job.id}|${job.status}|${store.path}|${store.collaborationRevision}|${store.hostingAccount?.id}|${accounts.revision}`;
  useEffect(() => {
    let stop = false;
    let timer: ReturnType<typeof setTimeout> | null = null;
    const id = ++generation.current;
    if (loaded.current !== job.id) {
      loaded.current = job.id;
      following.current = true;
      setText("");
      setTruncated(false);
      setShowAll(false);
    }
    const run = async () => {
      setBusy(true);
      setError("");
      try {
        const c = await store.workspaceAccess();
        if (!c) throw new Error(t("Connect an account to load this workspace."));
        const result = await workspaceJobLog(c, job.id);
        if (generation.current === id && !stop && c.stillCurrent?.()) {
          setText(result.body);
          setTruncated(result.truncated);
        }
      } catch (e) {
        if (generation.current === id && !stop)
          setError(e instanceof Error ? e.message : String(e));
      } finally {
        if (generation.current === id && !stop) setBusy(false);
      }
      if (!stop && isActiveCI(job.status))
        timer = setTimeout(() => void run(), 10_000);
    };
    void run();
    return () => {
      stop = true;
      if (timer) clearTimeout(timer);
    };
    // the job, its status and the account decide what to read; `reload` is the button
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [identity, reload]);
  const lines = useMemo(() => text.split("\n"), [text]);
  const errors = useMemo(() => lines.map(isLogError), [lines]);
  const hasError = errors.includes(true);
  const first = showAll ? 0 : firstLogLine(lines);
  useLayoutEffect(() => {
    const el = box.current;
    if (el && following.current && !hasError) el.scrollTop = el.scrollHeight;
  }, [text, hasError]);
  const provider = store.target?.provider ?? "gitlab";
  const canRetry =
    provider === "gitlab"
      ? job.status === "failed" || job.status === "canceled" || job.status === "success"
      : isFinishedCI(job.status) && !isActiveCI(pipeline.status);
  // "Failed after 3m 12s" for a failed job, how long any other finished one took, else its state
  const outcome =
    job.duration != null && job.duration > 0
      ? t(job.status === "failed" ? "Failed after {0}" : "Took {0}", duration(job.duration))
      : statusInfo[job.status].title;
  const more = t("More job actions");
  return (
    <>
      <div className="ci-log-head">
        <div className="ci-log-head-row">
          <CIStatusIcon status={job.status} size={14} />
          <strong className="mono ellipsis">{job.name}</strong>
          {/* the failed tone on words that say it failed; the icon says it too */}
          <span className={`ci-log-outcome${job.status === "failed" ? " status-tone" : ""}`} data-tone="failed">{outcome}</span>
          {busy && <Spinner size={11} />}
          <span className="spacer" />
          <span className="ci-log-buttons">
            {hasError && (
              <Button onClick={() => { setShowAll(false); requestAnimationFrame(() => box.current?.querySelector(".ci-log-line.error")?.scrollIntoView({ block: "center" })); }}>
                {t("Jump to first error")}
              </Button>
            )}
            {canRetry && (
              <Button disabled={store.ci.busy.has(`job:${job.id}`)} onClick={() => void store.ci.retryJob(job, pipeline)}>
                <RotateCw size={14} />
                {t("Rerun job")}
              </Button>
            )}
            <HostedListIconButton label={t("Open in browser")} onClick={() => store.openUrl(job.url)}>
              <ExternalLink size={13} />
            </HostedListIconButton>
            <HostedListIconButton label={more} aria-haspopup="menu" onClick={(event) => showMenuBelow(event.currentTarget, [
              { label: t("Wrap long lines"), checked: wrap, onClick: () => settings.set("ciLogWrap", !wrap) },
              { label: t("Copy redacted log"), disabled: !text, onClick: () => store.copy(text) },
              { label: t("Reload log"), disabled: busy, onClick: () => setReload((n) => n + 1) },
              "divider",
              { label: t("Close log"), onClick: close },
            ])}>
              <Ellipsis size={14} />
            </HostedListIconButton>
          </span>
        </div>
        {truncated && <span className="hosted-caption ci-log-note">{t("Log preview is limited to 2 MB. Open the browser for the complete log.")}</span>}
      </div>
      {error ? (
        <p className="error-text selectable ci-log-message" role="alert">
          {error}
        </p>
      ) : !text ? (
        <div className="ci-log-empty hosted-caption">{busy ? <Spinner size={14} /> : t("No log output yet.")}</div>
      ) : (
        <div
          ref={box}
          className={`ci-log-text selectable mono${wrap ? " wrap" : ""}`}
          role="region"
          aria-label={t("Job log")}
          tabIndex={0}
          onScroll={(e) => {
            const el = e.currentTarget;
            following.current = el.scrollTop + el.clientHeight >= el.scrollHeight - 8;
          }}
        >
          {first > 0 && <HostedListTextButton className="ci-log-earlier" onClick={() => setShowAll(true)}>{t("Show {0} earlier lines", first)}</HostedListTextButton>}
          {lines.slice(first).map((line, index) => (
            <div key={first + index} className={`ci-log-line${errors[first + index] ? " error status-tone" : ""}`} data-tone="failed">
              <span className="ci-log-number">{first + index + 1}</span>
              <span className="ci-log-words">{line}</span>
            </div>
          ))}
        </div>
      )}
    </>
  );
}

/**
 * One job: status, name and duration; a click shows its log. A job that waits to be run, or one that can be stopped,
 * carries that one button.
 */
function JobRow({
  store,
  job,
  pipeline,
  selected,
  select,
}: {
  store: RepoStore;
  job: CIJob;
  pipeline: CIPipeline;
  selected: boolean;
  select: () => void;
}) {
  const ci = store.ci;
  const provider = store.target?.provider ?? "gitlab";
  const canRetry =
    provider === "gitlab"
      ? job.status === "failed" ||
        job.status === "canceled" ||
        job.status === "success"
      : isFinishedCI(job.status) && !isActiveCI(pipeline.status);
  const playable = canPlay(job) && provider === "gitlab";
  const cancellable = isActiveCI(job.status) && provider === "gitlab";
  let action: ReactNode = null;
  if (ci.busy.has(`job:${job.id}`)) action = <Spinner size={11} />;
  else if (playable)
    action = (
      <IconButton
        icon={<CirclePlay size={15} />}
        tip={
          job.status === "scheduled"
            ? t("Run now (don't wait for the schedule)")
            : t("Run manual job")
        }
        onClick={() => ci.playJob(job, pipeline)}
      />
    );
  else if (cancellable)
    action = (
      <IconButton
        icon={<CircleStop size={13} />}
        tip={t("Cancel job")}
        onClick={() => void ci.cancelJob(job, pipeline)}
      />
    );
  return (
    <div
      className={`ci-job ${selected ? "selected" : ""}`}
      data-job={job.id}
      data-tip={job.stage ? `${job.stage} · ${statusInfo[job.status].title}` : statusInfo[job.status].title}
      onContextMenu={(e) =>
        showContextMenu(e, [
          {
            label: t("View log (browser)"),
            onClick: () => store.openUrl(job.url),
          },
          ...(playable
            ? [{ label: t("Run"), onClick: () => ci.playJob(job, pipeline) }]
            : []),
          ...(canRetry
            ? [
                {
                  label: t("Run again"),
                  onClick: () => void ci.retryJob(job, pipeline),
                },
              ]
            : []),
          ...(cancellable
            ? [
                {
                  label: t("Cancel"),
                  onClick: () => void ci.cancelJob(job, pipeline),
                },
              ]
            : []),
          "divider",
          { label: t("Copy link"), onClick: () => store.copy(job.url) },
        ])
      }
    >
      <button className="ci-job-select" aria-pressed={selected} onClick={select}>
        <CIStatusIcon status={job.status} size={14} />
        <span className="ci-job-name mono ellipsis">{job.name}</span>
        {job.allowFailure && job.status === "failed" && (
          <span className="status-tone ci-job-allowed" data-tone="waiting" data-tip={t("Allowed to fail")}>
            <TriangleAlert size={11} />
          </span>
        )}
        {job.duration != null && job.duration > 0 && <span className="ci-job-time mono">{duration(job.duration)}</span>}
      </button>
      {action}
    </div>
  );
}

/**
 * A deployment that waits for approval (GitHub environment protection rules): white with a hairline, the waiting icon
 * and words in its tone, and the two answers
 */
function DeploymentApproval({
  store,
  pipeline,
  deployments,
}: {
  store: RepoStore;
  pipeline: CIPipeline;
  deployments: CIDeployment[];
}) {
  const mine = deployments.filter((d) => d.canApprove);
  return (
    <div className="ci-approval status-tone" data-tone="waiting">
      <Hand size={14} />
      <span className="ci-approval-title">
        {t(
          "Waiting for deployment approval: {0}",
          deployments.map((d) => d.environment).join(", "),
        )}
      </span>
      {mine.length ? (
        <>
          <Button kind="primary" onClick={() => store.ci.reviewDeployment(pipeline, mine, true)}>
            {t("Approve")}
          </Button>
          <Button onClick={() => store.ci.reviewDeployment(pipeline, mine, false)}>
            {t("Reject")}
          </Button>
        </>
      ) : (
        <span className="hosted-caption">{t("This account can't approve.")}</span>
      )}
    </div>
  );
}
