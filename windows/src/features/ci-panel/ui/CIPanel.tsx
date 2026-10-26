import {
  ChevronRight,
  CirclePlay,
  CircleStop,
  GitBranch,
  Hand,
  List,
  ListFilter,
  Play,
  RefreshCw,
  RotateCw,
  TriangleAlert,
  Zap,
} from "lucide-react";
import { type ReactNode, useEffect, useRef, useState } from "react";
import {
  canPlay,
  type CIDeployment,
  type CIJob,
  type CIPipeline,
  CIStatusIcon,
  eventTitle,
  groupByBranch,
  isActiveCI,
  isFinishedCI,
  statusInfo,
} from "@/entities/ci";
import type { Provider } from "@/entities/git";
import { accounts } from "@/entities/hosting";
import type { RepoStore } from "@/entities/repo";
import { settings } from "@/shared/config";
import { t } from "@/shared/i18n";
import { shortDate, useObserve } from "@/shared/lib";
import {
  Button,
  IconButton,
  showContextMenu,
  showMenuBelow,
  Spinner,
} from "@/shared/ui";

/** 사이드바 'CI/CD' 탭: GitLab 파이프라인·GitHub Actions 실행. 수동 작업 ▶ 실행, 다시 실행, 취소, 배포 승인. */
export function CIPanel({
  store,
  openSettings,
}: {
  store: RepoStore;
  openSettings: () => void;
}) {
  useObserve(store);
  const ci = useObserve(store.ci);
  useObserve(accounts);
  const target = store.target;
  useObserve(settings);
  const [expanded, setExpanded] = useState<Set<number>>(new Set());
  // 보기: 시간순 목록 / 브랜치별(접은 브랜치는 이 창에서만 기억)
  const byBranch = settings.get<boolean>("ciGroupByBranch", false);
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set());
  const expandedRef = useRef(expanded);
  expandedRef.current = expanded;
  const key = target
    ? `${target.host}/${target.path}/${ci.currentBranchOnly}/${accounts.revision}`
    : "";

  // 처음 읽고, 실행 중인 게 있으면 8초·없으면 45초마다 새로 고친다(펼친 파이프라인의 작업도)
  useEffect(() => {
    if (!key) return;
    let stop = false;
    let timer: ReturnType<typeof setTimeout> | null = null;
    const tick = async () => {
      if (stop) return;
      await ci.load(true);
      for (const p of ci.pipelines) {
        if (
          expandedRef.current.has(p.id) &&
          (isActiveCI(p.status) || !ci.jobs.has(p.id))
        )
          await ci.loadJobs(p, true);
      }
      schedule();
    };
    const schedule = () => {
      if (stop) return;
      const active = ci.pipelines.some((p) => isActiveCI(p.status));
      timer = setTimeout(() => void tick(), active ? 8000 : 45000);
    };
    void ci.load().then(schedule);
    return () => {
      stop = true;
      if (timer) clearTimeout(timer);
    };
  }, [key, ci]);

  // a run opened from a graph badge: expand its branch group and the run, show it, then let go of the focus
  const root = useRef<HTMLDivElement>(null);
  const focus = store.ciFocus;
  useEffect(() => {
    if (focus === null) return;
    if (target && (ci.state.kind === "idle" || ci.state.kind === "loading")) return; // the list is still on its way
    const p = ci.pipelines.find((x) => x.id === focus);
    if (p) {
      setCollapsed((prev) => { if (!prev.has(p.ref)) return prev; const next = new Set(prev); next.delete(p.ref); return next; });
      setExpanded((prev) => (prev.has(p.id) ? prev : new Set(prev).add(p.id)));
      if (!ci.jobs.has(p.id)) void ci.loadJobs(p);
      requestAnimationFrame(() => root.current?.querySelector(`[data-pipeline="${p.id}"]`)?.scrollIntoView({ block: "center" }));
    }
    store.ciFocus = null;
    store.changed();
  }, [focus, target, ci, ci.state.kind, ci.pipelines, store]);

  if (!target) {
    return (
      <div
        className="side-scroll col"
        style={{
          alignItems: "center",
          justifyContent: "center",
          gap: 8,
          padding: 20,
          textAlign: "center",
        }}
      >
        <Zap size={28} style={{ opacity: 0.35 }} />
        <span className="muted">
          {t(
            "You can view and run pipelines in repositories with a GitHub or GitLab remote.",
          )}
        </span>
      </div>
    );
  }

  const toggle = (p: CIPipeline, open?: boolean) => {
    const next = new Set(expanded);
    const willOpen = open ?? !next.has(p.id);
    if (willOpen) {
      next.add(p.id);
      void ci.loadJobs(p);
    } else next.delete(p.id);
    setExpanded(next);
  };

  const st = ci.state;
  return (
    <div className="col" style={{ flex: 1, minHeight: 0 }} ref={root}>
      <div
        className="row"
        style={{
          padding: "4px 12px 6px",
          gap: 4,
          borderBottom: "1px solid var(--border)",
        }}
      >
        <span style={{ fontWeight: 600 }}>
          {target.provider === "gitlab" ? t("Pipelines") : "Actions"}
        </span>
        {st.kind === "loading" && <Spinner size={11} />}
        <span className="spacer" />
        <IconButton
          small
          icon={byBranch ? <GitBranch size={13} /> : <List size={13} />}
          tip={t("Show runs as a list or grouped by branch")}
          aria-label={t("Show runs as a list or grouped by branch")}
          onClick={(e) =>
            showMenuBelow(e.currentTarget, [
              {
                label: t("List"),
                checked: !byBranch,
                onClick: () => settings.set("ciGroupByBranch", false),
              },
              {
                label: t("By branch"),
                checked: byBranch,
                onClick: () => settings.set("ciGroupByBranch", true),
              },
            ])
          }
        />
        <IconButton
          small
          className={ci.currentBranchOnly ? "on" : ""}
          icon={<ListFilter size={13} />}
          tip={
            ci.currentBranchOnly
              ? t("Show all branches")
              : t("Show only the current branch ({0})", ci.currentRef ?? "-")
          }
          onClick={() => ci.setCurrentBranchOnly(!ci.currentBranchOnly)}
        />
        <IconButton
          small
          icon={<RefreshCw size={12} />}
          tip={t("Refresh")}
          onClick={() => void ci.load()}
        />
        <IconButton
          small
          icon={<CirclePlay size={14} />}
          tip={
            target.provider === "gitlab"
              ? t("Run new pipeline|Choose a branch and variables to run")
              : t(
                  "Run workflow|Runs a workflow_dispatch workflow with a branch and inputs",
                )
          }
          disabled={!ci.hasAccess || ci.busy.has("run")}
          onClick={() => {
            store.sheet = { kind: "runPipeline" };
            store.changed();
          }}
        />
      </div>
      <div className="side-scroll">
        {st.kind === "needsAccount" && (
          <div
            className="col"
            style={{ gap: 6, padding: 8, alignItems: "flex-start" }}
          >
            <span className="muted">
              {t(
                "Connect a {0} account to see pipelines.",
                target.provider === "gitlab"
                  ? t("Self-hosted GitLab ({0})", target.host)
                  : "GitHub",
              )}
            </span>
            <button className="link" onClick={openSettings}>
              {t("Connect account…")}
            </button>
          </div>
        )}
        {st.kind === "failed" && (
          <div
            className="col"
            style={{ gap: 6, padding: 8, alignItems: "flex-start" }}
          >
            <span
              className="error-text"
              style={{
                fontSize: 11.5,
                whiteSpace: "pre-wrap",
                userSelect: "text",
              }}
            >
              {st.message}
            </span>
            <button className="link" onClick={() => void ci.load()}>
              {t("Try again")}
            </button>
          </div>
        )}
        {st.kind === "loaded" && !ci.pipelines.length && (
          <div className="muted" style={{ padding: 8 }}>
            {ci.currentBranchOnly
              ? t("No runs for this branch.")
              : t("No runs yet.")}
          </div>
        )}
        {st.kind !== "needsAccount" &&
          st.kind !== "failed" &&
          (byBranch
            ? groupByBranch(ci.pipelines).map((g) => {
                const closed = collapsed.has(g.ref);
                return (
                  <div key={g.ref} className="ci-branch">
                    <div
                      className={`side-row ci-branch-head ${closed ? "collapsed" : ""}`}
                      onClick={() => {
                        const next = new Set(collapsed);
                        if (closed) next.delete(g.ref);
                        else next.add(g.ref);
                        setCollapsed(next);
                      }}
                      data-tip={`${g.ref} · ${statusInfo[g.pipelines[0].status].title}`}
                    >
                      <ChevronRight size={12} className="chev" />
                      <CIStatusIcon status={g.pipelines[0].status} size={13} />
                      <span className="mono ellipsis grow">{g.ref}</span>
                      <span className="muted" style={{ fontSize: 11 }}>
                        {g.pipelines.length}
                      </span>
                    </div>
                    {!closed &&
                      g.pipelines.map((p) => (
                        <div key={p.id} style={{ paddingLeft: 12 }}>
                          <PipelineRow
                            store={store}
                            pipeline={p}
                            provider={target.provider}
                            open={expanded.has(p.id)}
                            toggle={(o) => toggle(p, o)}
                            showRef={false}
                          />
                          {expanded.has(p.id) && (
                            <PipelineJobs store={store} pipeline={p} />
                          )}
                        </div>
                      ))}
                  </div>
                );
              })
            : ci.pipelines.map((p) => (
                <div key={p.id}>
                  <PipelineRow
                    store={store}
                    pipeline={p}
                    provider={target.provider}
                    open={expanded.has(p.id)}
                    toggle={(o) => toggle(p, o)}
                  />
                  {expanded.has(p.id) && (
                    <PipelineJobs store={store} pipeline={p} />
                  )}
                </div>
              )))}
      </div>
    </div>
  );
}

function PipelineRow({
  store,
  pipeline: p,
  provider,
  open,
  toggle,
  showRef = true,
}: {
  store: RepoStore;
  pipeline: CIPipeline;
  provider: Provider;
  open: boolean;
  toggle: (open?: boolean) => void;
  /** 브랜치별 보기에서는 묶음 머리에 브랜치가 있으니 줄마다 다시 적지 않는다 */
  showRef?: boolean;
}) {
  const ci = store.ci;
  const title = p.title || ci.subject(p.sha) || p.name || p.sha.slice(0, 8);
  const manual = (ci.jobs.get(p.id) ?? []).filter(canPlay).length;
  const busy = ci.busy.has(`pipeline:${p.id}`);
  const failed = p.status === "failed" || p.status === "canceled";
  return (
    <div
      className="side-row"
      style={{ alignItems: "center", cursor: "default" }}
      data-pipeline={p.id}
      onClick={() => toggle()}
      onContextMenu={(e) =>
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
        ])
      }
    >
      <ChevronRight
        size={12}
        style={{
          flex: "none",
          opacity: 0.6,
          transform: open ? "rotate(90deg)" : undefined,
          transition: "transform .12s",
        }}
      />
      <CIStatusIcon status={p.status} />
      <div className="col grow" style={{ minWidth: 0, gap: 0 }}>
        <span className="ellipsis">{title}</span>
        <span className="side-sub row" style={{ gap: 4, minWidth: 0 }}>
          {provider === "github" && p.name && (
            <span className="ellipsis" style={{ flex: "0 1 auto" }}>
              {p.name}
            </span>
          )}
          <span style={{ flex: "none" }}>#{p.number}</span>
          {showRef && (
            <span className="mono ellipsis" style={{ flex: "0 1 auto" }}>
              {p.ref}
            </span>
          )}
          {p.created != null && (
            <span style={{ flex: "none" }}>{shortDate(p.created)}</span>
          )}
          {p.event && p.event !== "push" && (
            <span style={{ flex: "none" }}>· {eventTitle(p.event)}</span>
          )}
        </span>
      </div>
      {manual > 0 && (
        <button
          className="link row"
          style={{
            gap: 2,
            color: "#e8912d",
            fontWeight: 600,
            fontSize: 11,
            flex: "none",
          }}
          data-tip={t(
            "{0} jobs waiting to be run manually — expand to run",
            manual,
          )}
          onClick={(e) => {
            e.stopPropagation();
            toggle(true);
          }}
        >
          <Play size={10} fill="currentColor" /> {manual}
        </button>
      )}
      {busy ? (
        <Spinner size={11} />
      ) : isActiveCI(p.status) ? (
        <IconButton
          small
          icon={<CircleStop size={13} />}
          tip={t("Cancel run")}
          onClick={(e) => {
            e.stopPropagation();
            ci.cancelPipeline(p);
          }}
        />
      ) : failed ? (
        <IconButton
          small
          icon={<RotateCw size={12} />}
          tip={
            provider === "gitlab"
              ? t("Rerun failed and canceled jobs")
              : t("Rerun failed jobs only")
          }
          onClick={(e) => {
            e.stopPropagation();
            void ci.retryPipeline(p, true);
          }}
        />
      ) : null}
    </div>
  );
}

function PipelineJobs({
  store,
  pipeline,
}: {
  store: RepoStore;
  pipeline: CIPipeline;
}) {
  const ci = store.ci;
  const jobs = ci.jobs.get(pipeline.id);
  if (!jobs)
    return (
      <div style={{ padding: "4px 30px" }}>
        <Spinner size={12} />
      </div>
    );
  const order: string[] = [];
  const by = new Map<string, CIJob[]>();
  for (const j of jobs) {
    if (!by.has(j.stage)) order.push(j.stage);
    by.set(j.stage, [...(by.get(j.stage) ?? []), j]);
  }
  const deps = ci.deployments.get(pipeline.id) ?? [];
  return (
    <div className="col" style={{ padding: "2px 4px 6px 26px", gap: 1 }}>
      {deps.length > 0 && (
        <DeploymentApproval
          store={store}
          pipeline={pipeline}
          deployments={deps}
        />
      )}
      {!jobs.length && (
        <span className="muted" style={{ fontSize: 11.5 }}>
          {t("No jobs")}
        </span>
      )}
      {order.map((stage) => (
        <div key={stage || "-"} className="col" style={{ gap: 1 }}>
          {stage && (
            <span
              className="muted"
              style={{
                fontSize: 10.5,
                fontWeight: 600,
                textTransform: "uppercase",
                marginTop: 3,
              }}
            >
              {stage}
            </span>
          )}
          {by.get(stage)!.map((j) => (
            <JobRow key={j.id} store={store} job={j} pipeline={pipeline} />
          ))}
        </div>
      ))}
    </div>
  );
}

function JobRow({
  store,
  job,
  pipeline,
}: {
  store: RepoStore;
  job: CIJob;
  pipeline: CIPipeline;
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
      className="side-row"
      style={{ minHeight: 22, cursor: "default" }}
      data-tip={statusInfo[job.status].title}
      onDoubleClick={() => store.openUrl(job.url)}
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
      <CIStatusIcon status={job.status} size={12} />
      <span className="ellipsis grow">{job.name}</span>
      {job.allowFailure && job.status === "failed" && (
        <span
          data-tip={t("Allowed to fail")}
          style={{ color: "#e8912d", display: "inline-flex" }}
        >
          <TriangleAlert size={11} />
        </span>
      )}
      {job.duration != null && job.duration > 0 && (
        <span className="side-sub" style={{ flex: "none" }}>
          {duration(job.duration)}
        </span>
      )}
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
        background: "color-mix(in srgb, #e8912d 10%, transparent)",
      }}
    >
      <span
        className="row"
        style={{ gap: 4, color: "#e8912d", fontWeight: 600, fontSize: 11.5 }}
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

// MARK: - 실행 시트
