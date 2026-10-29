import {
  CircleStop,
  CirclePlay,
  Copy,
  Globe,
  Hand,
  Link,
  RefreshCw,
  RotateCw,
  TriangleAlert,
  X,
} from "lucide-react";
import {
  type MouseEvent,
  type ReactNode,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
} from "react";
import {
  canPlay,
  type CIDeployment,
  type CIJob,
  type CIPipeline,
  CIStatusIcon,
  eventTitle,
  isActiveCI,
  isFinishedCI,
  statusInfo,
} from "@/entities/ci";
import type { Provider } from "@/entities/git";
import { accounts, workspaceJobLog } from "@/entities/hosting";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { longDate, useObserve } from "@/shared/lib";
import { Button, IconButton, showContextMenu, Spinner } from "@/shared/ui";

/**
 * The run picked on the Actions page: its summary and commands on top, the jobs by stage on the left and the
 * picked job's log on the right, as on GitHub's run page. (macOS: CIRunDetailView.swift)
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
  const failed = p.status === "failed" || p.status === "canceled";
  const deployments = ci.deployments.get(p.id) ?? [];
  const trigger = [eventTitle(p.event), p.actor ? `@${p.actor}` : ""]
    .filter(Boolean)
    .join(" · ");
  return (
    <div className="ci-run-detail col">
      <header className="ci-run-head row">
        <CIStatusIcon status={p.status} />
        <strong>
          {provider === "gitlab"
            ? t("Pipeline #{0}", p.number)
            : t("Run #{0}", p.number)}
        </strong>
        <span className="ci-status-pill" style={{ color: statusInfo[p.status].color }}>{statusInfo[p.status].title}</span>
        <span className="spacer" />
        {busy && <Spinner size={12} />}
        <IconButton
          small
          icon={<RefreshCw size={12} />}
          tip={t("Refresh")}
          aria-label={t("Refresh")}
          onClick={() => void ci.loadJobs(p)}
        />
      </header>
      <section className="ci-run-summary col">
        <h2 className="selectable">{runTitle(store, p)}</h2>
        {jobs && <div className="ci-job-summary" aria-label={t("Loaded jobs")}>
          <span>{t("Loaded jobs")} <strong>{jobs.length}</strong></span>
          {[...new Set(jobs.map(item => item.status))].map(status => <span key={status}><CIStatusIcon status={status} size={12}/>{statusInfo[status].title} <strong>{jobs.filter(item => item.status === status).length}</strong></span>)}
        </div>}
        <dl className="ci-run-facts">
          {provider === "github" && p.name && (
            <>
              <dt className="muted">{t("Workflow")}</dt>
              <dd>{p.name}</dd>
            </>
          )}
          <dt className="muted">{t("Branch")}</dt>
          <dd className="mono selectable">{p.ref}</dd>
          <dt className="muted">{t("Commit")}</dt>
          <dd>
            <button
              className="link mono"
              data-tip={t("View commit")}
              onClick={() => store.reveal(p.sha)}
            >
              {p.sha.slice(0, 8)}
            </button>
          </dd>
          <dt className="muted">{t("Trigger")}</dt>
          <dd>{trigger}</dd>
          {p.created != null && (
            <>
              <dt className="muted">{t("Created")}</dt>
              <dd>{longDate(p.created)}</dd>
            </>
          )}
        </dl>
        <div className="row ci-run-actions">
          {isActiveCI(p.status) ? (
            <Button disabled={busy} onClick={() => ci.cancelPipeline(p)}>
              <CircleStop size={13} /> {t("Cancel run")}
            </Button>
          ) : provider === "github" ? (
            <>
              <Button
                disabled={busy || !failed}
                onClick={() => void ci.retryPipeline(p, true)}
              >
                <RotateCw size={13} /> {t("Rerun failed jobs only")}
              </Button>
              <Button
                disabled={busy}
                onClick={() => void ci.retryPipeline(p, false)}
              >
                <RotateCw size={13} /> {t("Rerun all jobs")}
              </Button>
            </>
          ) : (
            <Button
              disabled={busy || !failed}
              onClick={() => void ci.retryPipeline(p, true)}
            >
              <RotateCw size={13} /> {t("Rerun failed and canceled jobs")}
            </Button>
          )}
          <Button onClick={() => store.openUrl(p.url)}>
            <Globe size={13} /> {t("Browser")}
          </Button>
          <Button onClick={() => store.copy(p.url)}>
            <Link size={13} /> {t("Copy link")}
          </Button>
        </div>
        {deployments.length > 0 && (
          <DeploymentApproval
            store={store}
            pipeline={p}
            deployments={deployments}
          />
        )}
      </section>
      <div className="ci-run-body">
        <div className="ci-run-jobs">
          <div className="ci-jobs-head row">
            <span>{t("Jobs")}</span>
            {!!jobs?.length && <span className="muted">{jobs.length}</span>}
          </div>
          {!jobs ? (
            <Spinner size={12} />
          ) : !jobs.length ? (
            <span className="muted">{t("No jobs")}</span>
          ) : (
            stages(jobs).map(([stage, list]) => (
              <section key={stage || "-"} className="ci-stage-group">
                <div className="ci-stage"><span>{stage || t("Jobs")}</span><span className="ci-stage-count">{list.length}</span></div>
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
        </div>
        <div className="ci-run-log col">
          {selected ? (
            <JobLog store={store} job={selected} close={() => setJob(null)} />
          ) : (
            <div className="ci-log-empty muted">
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

/** The run's commands, for the list's context menu */
export function runMenu(
  e: MouseEvent,
  store: RepoStore,
  p: CIPipeline,
  provider: Provider,
) {
  const ci = store.ci;
  const failed = p.status === "failed" || p.status === "canceled";
  showContextMenu(e, [
    { label: t("Open in browser"), onClick: () => store.openUrl(p.url) },
    { label: t("View commit"), onClick: () => store.reveal(p.sha) },
    "divider",
    ...(isActiveCI(p.status)
      ? [{ label: t("Cancel run"), onClick: () => ci.cancelPipeline(p) }]
      : provider === "github"
        ? [
            {
              label: t("Rerun all jobs"),
              onClick: () => void ci.retryPipeline(p, false),
            },
            {
              label: t("Rerun failed jobs only"),
              disabled: !failed,
              onClick: () => void ci.retryPipeline(p, true),
            },
          ]
        : [
            {
              label: t("Rerun failed and canceled jobs"),
              disabled: !failed,
              onClick: () => void ci.retryPipeline(p, true),
            },
          ]),
    "divider",
    { label: t("Copy link"), onClick: () => store.copy(p.url) },
  ]);
}

/** GitLab orders jobs by stage; GitHub jobs have none and stay in one group */
function stages(jobs: CIJob[]): [string, CIJob[]][] {
  const order: string[] = [];
  const by = new Map<string, CIJob[]>();
  for (const j of jobs) {
    if (!by.has(j.stage)) order.push(j.stage);
    by.set(j.stage, [...(by.get(j.stage) ?? []), j]);
  }
  return order.map((stage) => [stage, by.get(stage)!]);
}

/**
 * The picked job's log, read with the account and masked for secrets; it stays on this computer.
 * A running job's log is read again every ten seconds, and the view keeps following the end while it is there.
 */
function JobLog({
  store,
  job,
  close,
}: {
  store: RepoStore;
  job: CIJob;
  close: () => void;
}) {
  useObserve(accounts);
  const [text, setText] = useState(""),
    [error, setError] = useState(""),
    [busy, setBusy] = useState(false),
    [truncated, setTruncated] = useState(false),
    [reload, setReload] = useState(0);
  const generation = useRef(0),
    loaded = useRef<number | null>(null),
    following = useRef(true),
    pre = useRef<HTMLPreElement>(null);
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
  // it opens at the end, where a failure usually is
  useLayoutEffect(() => {
    const el = pre.current;
    if (el && following.current) el.scrollTop = el.scrollHeight;
  }, [text]);
  return (
    <>
      <div className="ci-log-head row">
        <CIStatusIcon status={job.status} size={12} />
        <strong className="ellipsis">{job.name}</strong>
        {job.duration != null && job.duration > 0 && (
          <span className="muted">{duration(job.duration)}</span>
        )}
        {busy && <Spinner size={11} />}
        <span className="spacer" />
        <IconButton
          small
          icon={<RefreshCw size={12} />}
          tip={t("Reload log")}
          aria-label={t("Reload log")}
          disabled={busy}
          onClick={() => setReload((n) => n + 1)}
        />
        <IconButton
          small
          icon={<Copy size={12} />}
          tip={t("Copy redacted log")}
          aria-label={t("Copy redacted log")}
          disabled={!text}
          onClick={() => store.copy(text)}
        />
        <IconButton
          small
          icon={<Globe size={12} />}
          tip={t("Open in browser")}
          aria-label={t("Open in browser")}
          onClick={() => store.openUrl(job.url)}
        />
        <IconButton
          small
          icon={<X size={13} />}
          tip={t("Close log")}
          aria-label={t("Close log")}
          onClick={close}
        />
      </div>
      {error ? (
        <p className="error-text selectable ci-log-message" role="alert">
          {error}
        </p>
      ) : !text ? (
        <div className="ci-log-empty muted">{busy ? <Spinner size={14} /> : t("No log output yet.")}</div>
      ) : (
        <>
          {truncated && (
            <p className="muted ci-log-message">
              {t(
                "Log preview is limited to 2 MB. Open the browser for the complete log.",
              )}
            </p>
          )}
          <pre
            ref={pre}
            className="selectable mono ci-log-text"
            aria-label={t("Job log")}
            onScroll={(e) => {
              const el = e.currentTarget;
              following.current =
                el.scrollTop + el.clientHeight >= el.scrollHeight - 8;
            }}
          >
            {text}
          </pre>
        </>
      )}
    </>
  );
}

/** One job: status, name and duration, with its run, cancel or rerun button; a click shows its log */
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
  const stop = (e: React.MouseEvent) => e.stopPropagation();
  let action: ReactNode = null;
  if (ci.busy.has(`job:${job.id}`)) action = <Spinner size={11} />;
  else if (playable)
    action = (
      <IconButton
        small
        icon={<CirclePlay size={15} />}
        style={{ color: "var(--accent)" }}
        tip={
          job.status === "scheduled"
            ? t("Run now (don't wait for the schedule)")
            : t("Run manual job")
        }
        onClick={(e) => {
          stop(e);
          ci.playJob(job, pipeline);
        }}
      />
    );
  else if (cancellable)
    action = (
      <IconButton
        small
        icon={<CircleStop size={13} />}
        tip={t("Cancel job")}
        onClick={(e) => {
          stop(e);
          void ci.cancelJob(job, pipeline);
        }}
      />
    );
  else if (canRetry && job.status !== "success")
    action = (
      <IconButton
        small
        icon={<RotateCw size={12} />}
        tip={t("Rerun job")}
        onClick={(e) => {
          stop(e);
          void ci.retryJob(job, pipeline);
        }}
      />
    );
  return (
    <div
      className={`side-row ci-job ${selected ? "selected" : ""}`}
      data-job={job.id}
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
        <CIStatusIcon status={job.status} size={14}/>
        <span className="ci-job-label"><strong>{job.name}</strong><span>{statusInfo[job.status].title}</span></span>
      {job.allowFailure && job.status === "failed" && (
        <span
          data-tip={t("Allowed to fail")}
          style={{ color: "var(--orange)", display: "inline-flex" }}
        >
          <TriangleAlert size={11} />
        </span>
      )}
      {job.duration != null && job.duration > 0 && (
        <span className="side-sub" style={{ flex: "none" }}>
          {duration(job.duration)}
        </span>
      )}
      </button>
      {action}
    </div>
  );
}

function duration(s: number) {
  const secs = Math.round(s);
  return secs >= 60
    ? t("{0}m {1}s", Math.floor(secs / 60), secs % 60)
    : t("{0}s", secs);
}

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
    <div
      className="col"
      style={{
        gap: 6,
        padding: 8,
        margin: "2px 0 4px",
        borderRadius: 6,
        background: "color-mix(in srgb, var(--orange) 10%, transparent)",
      }}
    >
      <span
        className="row"
        style={{ gap: 4, color: "var(--orange)", fontWeight: 600, fontSize: 11.5 }}
      >
        <Hand size={12} />{" "}
        {t(
          "Waiting for deployment approval: {0}",
          deployments.map((d) => d.environment).join(", "),
        )}
      </span>
      {mine.length ? (
        <div className="row" style={{ gap: 6 }}>
          <Button
            kind="primary"
            size="small"
            onClick={() => store.ci.reviewDeployment(pipeline, mine, true)}
          >
            {t("Approve")}
          </Button>
          <Button
            size="small"
            onClick={() => store.ci.reviewDeployment(pipeline, mine, false)}
          >
            {t("Reject")}
          </Button>
        </div>
      ) : (
        <span className="muted" style={{ fontSize: 11.5 }}>
          {t("This account can't approve.")}
        </span>
      )}
    </div>
  );
}
