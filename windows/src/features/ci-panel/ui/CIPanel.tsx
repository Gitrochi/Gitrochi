import {
  ChevronRight,
  CirclePlay,
  GitBranch,
  List,
  ListFilter,
  Play,
  RefreshCw,
  Zap,
} from "lucide-react";
import { useEffect, useRef, useState } from "react";
import {
  canPlay,
  type CIPipeline,
  CIStatusIcon,
  eventTitle,
  groupByBranch,
  isActiveCI,
  statusInfo,
} from "@/entities/ci";
import type { Provider } from "@/entities/git";
import { accounts } from "@/entities/hosting";
import type { RepoStore } from "@/entities/repo";
import { settings } from "@/shared/config";
import { t } from "@/shared/i18n";
import { shortDate, useObserve } from "@/shared/lib";
import { IconButton, showMenuBelow, Spinner } from "@/shared/ui";
import { runMenu, runTitle } from "./CIRunDetail";
import "./ci-panel.css";

/**
 * The Actions page's run list: GitLab pipelines or GitHub Actions runs, newest first or grouped by branch.
 * A row shows the run on the right (CIRunDetail). (macOS: CIPanel.swift)
 */
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
  // 보기: 시간순 목록 / 브랜치별(접은 브랜치는 이 창에서만 기억)
  const byBranch = settings.get<boolean>("ciGroupByBranch", false);
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set());
  const selectedRef = useRef(store.ciSelected);
  selectedRef.current = store.ciSelected;
  const key = target
    ? `${target.host}/${target.path}/${ci.currentBranchOnly}/${accounts.revision}`
    : "";

  // 처음 읽고, 실행 중인 게 있으면 8초·없으면 45초마다 새로 고친다(고른 실행의 작업도)
  useEffect(() => {
    if (!key) return;
    let stop = false;
    let timer: ReturnType<typeof setTimeout> | null = null;
    const tick = async () => {
      if (stop) return;
      await ci.load(true);
      const p = ci.pipelines.find((x) => x.id === selectedRef.current);
      if (p && (isActiveCI(p.status) || !ci.jobs.has(p.id)))
        await ci.loadJobs(p, true);
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

  // a run opened from a graph badge: open its branch group, select the run, show it, then let go of the focus
  const root = useRef<HTMLDivElement>(null);
  const focus = store.ciFocus;
  useEffect(() => {
    if (focus === null) return;
    if (target && (ci.state.kind === "idle" || ci.state.kind === "loading")) return; // the list is still on its way
    const p = ci.pipelines.find((x) => x.id === focus);
    if (p) {
      setCollapsed((prev) => { if (!prev.has(p.ref)) return prev; const next = new Set(prev); next.delete(p.ref); return next; });
      store.selectRun(p);
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

  const row = (p: CIPipeline, showRef: boolean) => (
    <PipelineRow
      key={p.id}
      store={store}
      pipeline={p}
      provider={target.provider}
      selected={store.ciSelected === p.id}
      showRef={showRef}
    />
  );
  const st = ci.state;
  return (
    <div className="col ci-runs" style={{ flex: 1, minHeight: 0 }} ref={root}>
      {/* styled like the Pull requests and Issues lists' section header */}
      <div className="side-head">
        <span className="row grow">
          <span className="ellipsis">
            {target.provider === "gitlab" ? t("Pipelines") : t("Runs")}
          </span>
          {ci.pipelines.length > 0 && (
            <span style={{ fontWeight: 500 }}>{ci.pipelines.length}</span>
          )}
          {st.kind === "loading" && <Spinner size={11} />}
        </span>
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
      <div className="side-scroll ci-run-list">
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
                    {!closed && (
                      <div style={{ paddingLeft: 12 }}>
                        {g.pipelines.map((p) => row(p, false))}
                      </div>
                    )}
                  </div>
                );
              })
            : ci.pipelines.map((p) => row(p, true)))}
      </div>
    </div>
  );
}

/** 파이프라인 한 줄: 상태 · 제목 · 브랜치 · 시간. 버튼은 오른쪽 상세와 우클릭 메뉴에 있다. */
function PipelineRow({
  store,
  pipeline: p,
  provider,
  selected,
  showRef = true,
}: {
  store: RepoStore;
  pipeline: CIPipeline;
  provider: Provider;
  selected: boolean;
  /** 브랜치별 보기에서는 묶음 머리에 브랜치가 있으니 줄마다 다시 적지 않는다 */
  showRef?: boolean;
}) {
  const ci = store.ci;
  const manual = (ci.jobs.get(p.id) ?? []).filter(canPlay).length;
  return (
    <div
      className={`side-row ci-run ${selected ? "selected" : ""}`}
      data-pipeline={p.id}
      role="button"
      tabIndex={0}
      aria-pressed={selected}
      onKeyDown={event => { if (event.key === "Enter" || event.key === " ") { event.preventDefault(); store.selectRun(p); } }}
      onClick={() => store.selectRun(p)}
      onContextMenu={(e) => runMenu(e, store, p, provider)}
    >
      <CIStatusIcon status={p.status} />
      <div className="col grow" style={{ minWidth: 0, gap: 0 }}>
        <span className="ci-run-title">{runTitle(store, p)}</span>
        <span className="ci-run-status" style={{ color: statusInfo[p.status].color }}>{statusInfo[p.status].title}</span>
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
        <span
          className="row ci-manual"
          data-tip={t("{0} jobs waiting to be run manually", manual)}
        >
          <Play size={10} fill="currentColor" /> {manual}
        </span>
      )}
      {ci.busy.has(`pipeline:${p.id}`) && <Spinner size={11} />}
    </div>
  );
}
