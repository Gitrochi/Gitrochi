import { ChevronRight, CirclePlay, CircleX, Clock, RefreshCw, Search, Zap } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import {
  canPlay,
  type CIPipeline,
  CIStatusIcon,
  commonWorkflow,
  groupByBranch,
  isActiveCI,
  runCount,
  type RunSegment,
  runSegment,
  runSegments,
  statusInfo,
  visibleRuns,
} from "@/entities/ci";
import type { Provider } from "@/entities/git";
import { accounts } from "@/entities/hosting";
import type { RepoStore } from "@/entities/repo";
import { settings } from "@/shared/config";
import { t } from "@/shared/i18n";
import { listWhen, useObserve } from "@/shared/lib";
import {
  hostedListAge, HostedAccountNeeded, HostedListChip, HostedListEmpty, HostedListLoading, HostedListNotice, HostedListRow, HostedListSearch, HostedListSegments,
  IconButton, Spinner,
} from "@/shared/ui";
import { runMenu, runName, runTitle } from "./CIRunDetail";
import "./ci-panel.css";

/**
 * Reads the runs, then again every 8 seconds while one is active and every 45 otherwise (the selected run's jobs too),
 * and selects the run a commit's CI badge asked for once the list has it. The Actions page calls it; so does the run
 * list where it stands alone (Flows).
 */
export function useRuns(store: RepoStore, enabled = true) {
  const ci = store.ci;
  const target = store.target;
  const selectedRef = useRef(store.ciSelected);
  selectedRef.current = store.ciSelected;
  const key = enabled && target ? `${target.host}/${target.path}/${ci.currentBranchOnly}/${accounts.revision}` : "";
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

  const focus = store.ciFocus;
  useEffect(() => {
    if (!enabled || focus === null) return;
    // a CI badge may ask for a run in a repository without a remote; nothing can show it, so let go
    if (target && (ci.state.kind === "idle" || ci.state.kind === "loading")) return; // the list is still on its way
    const p = ci.pipelines.find((x) => x.id === focus);
    if (p) store.selectRun(p);
    store.ciFocus = null;
    store.changed();
  }, [enabled, focus, target, ci, ci.state.kind, ci.pipelines, store]);
}

/**
 * The Actions page's list column, as the Actions board draws it: search with the sort and filter menu (order, all
 * branches or this one, grouping), the segments that count what failed, runs or waits, and two-line rows.
 * A row shows the run on the right (CIRunDetail). On the page (`page`) the page reads the runs and holds Refresh and
 * Run; standing alone it does both itself. (macOS: CIPanel.swift)
 */
export function CIPanel({
  store,
  openSettings,
  page = false,
}: {
  store: RepoStore;
  openSettings: () => void;
  page?: boolean;
}) {
  useObserve(store);
  const ci = useObserve(store.ci);
  useObserve(accounts);
  const target = store.target;
  useObserve(settings);
  // rows in one list, or under their branches (the folded branches are remembered for this window only)
  const byBranch = settings.get<boolean>("ciGroupByBranch", false);
  const oldestFirst = settings.get<boolean>("ciOldestFirst", false);
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set());
  const [search, setSearch] = useState("");
  const [segment, setSegment] = useState<RunSegment>("all");
  useRuns(store, !page);
  const title = (p: CIPipeline) => runTitle(store, p);
  const runs = visibleRuns(ci.pipelines, segment, search, oldestFirst, title);

  // the run the page selected (a row, or a commit's CI badge): open its branch group, drop a filter that hides it and
  // bring it into view; a row already in view stays where it is
  const root = useRef<HTMLElement>(null);
  const selected = store.ciSelected;
  useEffect(() => {
    const p = selected === null ? undefined : ci.pipelines.find((x) => x.id === selected);
    if (!p) return;
    setCollapsed((prev) => { if (!prev.has(p.ref)) return prev; const next = new Set(prev); next.delete(p.ref); return next; });
    if (!visibleRuns(ci.pipelines, segment, search, oldestFirst, title).some((x) => x.id === p.id)) { setSearch(""); setSegment("all"); }
    requestAnimationFrame(() => root.current?.querySelector(`[data-pipeline="${p.id}"]`)?.scrollIntoView({ block: "nearest" }));
    // only a new selection moves the list
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selected]);

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

  const st = ci.state, host = target.host;
  const common = commonWorkflow(ci.pipelines);
  const row = (p: CIPipeline, showRef: boolean) => (
    <PipelineRow
      key={p.id}
      store={store}
      pipeline={p}
      provider={target.provider}
      selected={store.ciSelected === p.id}
      showRef={showRef}
      common={common}
    />
  );
  const order = oldestFirst ? t("Oldest first") : t("Newest first");
  const branch = ci.currentBranchOnly ? ci.currentRef ?? t("Current branch") : t("All branches");
  const segmentTitle = (value: RunSegment) => t(({ all: "All", failed: "Failed", running: "Running", waiting: "Waiting" } as const)[value]);
  return (
    <aside className="hosted-list ci-runs" aria-label={t("Run list")} ref={root}>
      {!page && (
        <div className="ci-list-actions">
          {st.kind === "loading" && <Spinner size={11} />}
          <span className="spacer" />
          <IconButton small icon={<RefreshCw size={12} />} tip={t("Refresh")} aria-label={t("Refresh")} onClick={() => void ci.load()} />
          <IconButton
            small
            icon={<CirclePlay size={14} />}
            tip={target.provider === "gitlab" ? t("Run new pipeline|Choose a branch and variables to run") : t("Run workflow|Runs a workflow_dispatch workflow with a branch and inputs")}
            disabled={!ci.hasAccess || ci.busy.has("run")}
            onClick={() => { store.sheet = { kind: "runPipeline" }; store.changed(); }}
          />
        </div>
      )}
      {st.kind === "failed" && ci.pipelines.length > 0 && <HostedListNotice title={t("Couldn't reach {0}", host)} caption={hostedListAge(ci.loadedAt)} detail={st.message} retry={() => void ci.load()} />}
      <HostedListSearch
        prompt={t("Search runs")}
        text={search}
        onText={setSearch}
        menuTitle={`${t("Sort and filter")}: ${order}, ${branch}`}
        menu={() => [
          { label: t("Newest first"), checked: !oldestFirst, onClick: () => settings.set("ciOldestFirst", false) },
          { label: t("Oldest first"), checked: oldestFirst, onClick: () => settings.set("ciOldestFirst", true) },
          "divider",
          // the branch filter lives here, not in a control of its own
          { label: t("All branches"), checked: !ci.currentBranchOnly, onClick: () => ci.setCurrentBranchOnly(false) },
          { label: ci.currentRef ?? t("Current branch"), checked: ci.currentBranchOnly, onClick: () => ci.setCurrentBranchOnly(true) },
          "divider",
          { label: t("Group by branch"), checked: byBranch, onClick: () => settings.set("ciGroupByBranch", !byBranch) },
        ]}
      />
      {/* Failed, Running and Waiting count what they hold; All never does, and nothing counts zero */}
      <HostedListSegments<RunSegment>
        options={runSegments.map((value) => ({ value, title: segmentTitle(value), count: value !== "all" && runCount(ci.pipelines, value) > 0 ? String(runCount(ci.pipelines, value)) : null }))}
        selection={segment}
        onSelect={setSegment}
      />
      {st.kind === "needsAccount" ? (
        <HostedAccountNeeded gitlab={target.provider === "gitlab"} host={host} path={target.path} onConnect={openSettings} />
      ) : !ci.pipelines.length ? (
        st.kind === "failed" ? (
          <HostedListEmpty failed icon={<CircleX size={24} />} title={t("Couldn't reach {0}", host)} caption={st.message} action={{ label: t("Retry"), onClick: () => void ci.load() }} />
        ) : st.kind === "loaded" ? (
          <HostedListEmpty icon={<CirclePlay size={24} />} title={ci.currentBranchOnly ? t("No runs for this branch.") : t("No runs yet.")}
            action={ci.currentBranchOnly ? { label: t("Show all branches"), onClick: () => ci.setCurrentBranchOnly(false) } : undefined} />
        ) : (
          <HostedListLoading caption={t("Loading runs…")} />
        )
      ) : !runs.length ? (
        <HostedListEmpty icon={<Search size={24} />} title={t("No runs match this filter.")}
          action={{ label: search ? t("Clear search") : t("Show all runs"), onClick: () => { setSearch(""); setSegment("all"); } }} />
      ) : (
        <div className="hosted-rows ci-run-list">
          {byBranch
            ? groupByBranch(runs).map((g) => {
                const closed = collapsed.has(g.ref);
                return (
                  <div key={g.ref} className="ci-branch">
                    <button
                      className={`ci-branch-head ${closed ? "collapsed" : ""}`}
                      aria-expanded={!closed}
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
                      <span className="ellipsis grow">{g.ref}</span>
                    </button>
                    {!closed && <div className="ci-branch-runs">{g.pipelines.map((p) => row(p, false))}</div>}
                  </div>
                );
              })
            : runs.map((p) => row(p, true))}
        </div>
      )}
    </aside>
  );
}

/** One run: its title and when it started, then which run it is, its state and its branch. Its commands are in the detail and the context menu. */
function PipelineRow({
  store,
  pipeline: p,
  provider,
  selected,
  showRef = true,
  common,
}: {
  store: RepoStore;
  pipeline: CIPipeline;
  provider: Provider;
  selected: boolean;
  /** Under a branch heading the branch is not repeated on every row */
  showRef?: boolean;
  /** The workflow most runs belong to: it goes without saying, any other one is named before the run */
  common: string | null;
}) {
  const ci = store.ci;
  const manual = (ci.jobs.get(p.id) ?? []).filter(canPlay).length;
  // a waiting run says so in words, so it carries no separate status icon
  const waiting = runSegment(p.status) === "waiting" || manual > 0;
  return (
    <HostedListRow
      className="ci-run"
      selected={selected}
      title={runTitle(store, p)}
      when={p.created != null ? listWhen(p.created) : null}
      data-pipeline={p.id}
      aria-pressed={selected}
      onClick={() => store.selectRun(p)}
      onContextMenu={(e) => runMenu(e, store, p, provider)}
    >
      <span className="ci-run-which">{p.name && p.name !== common ? `${p.name} · ` : ""}<span className="mono">{runName(provider, p)}</span></span>
      {waiting ? (
        <HostedListChip tone="waiting" icon={<Clock size={11} />} data-tip={manual > 0 ? t("{0} jobs waiting to be run manually", manual) : statusInfo[p.status].title}>{t("Waiting")}</HostedListChip>
      ) : (
        <CIStatusIcon status={p.status} size={12} />
      )}
      {ci.busy.has(`pipeline:${p.id}`) && <Spinner size={11} />}
      <span className="spacer" />
      {/* the branch on the right is cut last, and from the front */}
      {showRef && <span className="ci-run-ref">{p.ref}</span>}
    </HostedListRow>
  );
}
