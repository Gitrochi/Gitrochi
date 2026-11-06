import { Clock3, History, Layers3, Play, ShieldCheck, TriangleAlert, Workflow } from "lucide-react";
import { CheckCircle2, Code2, ListFilter } from "@/shared/icons";
import { ChevronRight, Cloud, GitBranch, Plus, Search, Terminal, X } from "@/shared/icons";
import { type KeyboardEvent, type ReactNode, useEffect, useId, useRef, useState } from "react";
import { type FlowPlan, type FlowPlanNode, type FlowStore, flowEngine, formatDuration, runRowPresentationState } from "@/entities/flow";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, Spinner } from "@/shared/ui";
import { FlowGraph } from "./FlowGraph";
import { FlowBlockIcon, FlowStateIcon, FlowStatePill, flowBlockKind, stateTitle } from "./FlowState";

/** Flow selection, command inspection and execution history on one workspace. */
export function FlowWorkspace({ flows, affected, busy, requestedFlow, onCreate, onRun, onOpen, onEdit, onReview, connectedCI, emptyState }: { flows: FlowStore; affected: boolean; busy: string | null; requestedFlow?: string; onCreate?: () => void; onRun: (flow: string) => void; onOpen: (run: string) => void; onEdit: (flow?: string, node?: string) => void; onReview: (flow: string) => void; connectedCI?: ReactNode; emptyState?: ReactNode }) {
  useObserve(flows);
  const [selectedFlow, setSelectedFlow] = useState<string | null>(null);
  const [search, setSearch] = useState("");
  const [createdNotice, setCreatedNotice] = useState(false);
  const [tab, setTab] = useState<"graph" | "history" | "ci">("graph");
  const [plan, setPlan] = useState<FlowPlan | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [selectedNode, setSelectedNode] = useState<string | null>(null);
  const loadedFlow = useRef<string | null>(null);
  const searchInput = useRef<HTMLInputElement>(null);
  const workspaceID = useId();
  const items = flows.list?.flows ?? [];
  const flow = items.find((item) => item.name === selectedFlow) ?? items[0];
  const query = search.trim().toLocaleLowerCase();
  const visibleFlows = items.filter((item) => `${item.name} ${item.description ?? ""}`.toLocaleLowerCase().includes(query));
  const chooseFlow = (name: string) => { setSelectedFlow(name); if (name !== flow?.name) setSelectedNode(null); setTab("graph"); };
  const clearSearch = () => { setSearch(""); searchInput.current?.focus(); };
  useEffect(() => {
    if (!requestedFlow) return;
    setSelectedFlow(requestedFlow); setSelectedNode(null); setSearch(""); setTab("graph"); setCreatedNotice(true);
  }, [requestedFlow]);
  useEffect(() => {
    let stale = false;
    const changed = loadedFlow.current !== flow?.name;
    if (changed) { setPlan(null); setSelectedNode(null); }
    setError(null);
    if (!flow) { setLoading(false); return; }
    setLoading(true);
    void flowEngine.plan(flow.name, flows.repo, affected).then((value) => {
      if (!stale) {
        loadedFlow.current = flow.name;
        setPlan(value);
        setSelectedNode((previous) => value.nodes.some((node) => node.id === previous) ? previous : value.nodes[0]?.id ?? null);
      }
    }, (reason) => { if (!stale) setError(reason instanceof Error ? reason.message : String(reason)); }).finally(() => { if (!stale) setLoading(false); });
    return () => { stale = true; };
  }, [flow?.name, flows.repo, flows.list, affected]);
  const active = flows.runs.find((run) => run.flow === flow?.name && run.running);
  const latest = active ?? flows.runs.find((run) => run.flow === flow?.name);
  const latestID = latest?.runId ?? flow?.last?.runId;
  const latestState = latest ? runRowPresentationState(latest) : flow?.last?.state;
  const view = active ? flows.views.get(active.runId) : undefined;
  const liveNodes = view && !view.done && view.nodes.length ? view.nodes : undefined;
  const shownPlan = plan?.flow === flow?.name ? plan : null;
  const graphNodes = liveNodes?.map((node) => ({ ...shownPlan?.nodes.find((planned) => planned.id === node.id), id: node.id, title: node.title, block: node.block, needs: node.needs, state: node.state, durationMs: node.durationMs })) ?? shownPlan?.nodes ?? [];
  const selected = shownPlan?.nodes.find((node) => node.id === selectedNode);
  const selectedLive = liveNodes?.find((node) => node.id === selectedNode);
  const title = tab === "ci" ? t("Connected CI") : tab === "history" ? t("Run history") : flow?.name || t("Flows");
  const description = tab === "ci" ? t("Review connected runs, jobs and logs for this repository.") : tab === "history" ? t("Inspect saved flow runs, their steps and results.") : flow?.description || t("Connect scripts into a repeatable workflow.");
  const tabs = [
    { id: "graph" as const, label: t("Flow graph"), icon: <Workflow size={15} /> },
    { id: "history" as const, label: t("Run history"), icon: <History size={15} /> },
    ...(connectedCI ? [{ id: "ci" as const, label: t("Connected CI"), icon: <Cloud size={15} /> }] : []),
  ];
  const navigateTabs = (event: KeyboardEvent<HTMLDivElement>) => {
    if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return;
    event.preventDefault();
    const index = tabs.findIndex((item) => item.id === tab);
    const next = event.key === "Home" ? 0 : event.key === "End" ? tabs.length - 1 : (index + (event.key === "ArrowRight" ? 1 : -1) + tabs.length) % tabs.length;
    setTab(tabs[next].id);
    event.currentTarget.querySelectorAll<HTMLButtonElement>('[role="tab"]')[next]?.focus();
  };
  return <div className="flow-workspace" data-flow-workspace>
    <aside className="flow-library">
      <div className="flow-library-title"><Workflow size={16} /><strong>{t("Flows")}</strong><span className="flow-count">{items.length}</span></div>
      <div className="flow-library-search"><Search size={14} aria-hidden="true" /><input ref={searchInput} type="search" aria-label={t("Find flows")} placeholder={t("Find flows")} value={search} onChange={(event) => setSearch(event.target.value)} />{search && <button type="button" aria-label={t("Clear search")} data-tip={t("Clear search")} onClick={clearSearch}><X size={13} /></button>}</div>
      <div className="flow-library-list">{visibleFlows.map((item) => {
        const last = flows.runs.find((run) => run.flow === item.name);
        return <button key={item.name} className={`flow-choice ${flow?.name === item.name ? "selected" : ""}`} aria-pressed={flow?.name === item.name} onClick={() => chooseFlow(item.name)}>
          <span className="flow-choice-heading"><span className="flow-choice-icon"><Workflow size={14} /></span><strong>{item.name}</strong><FlowStateIcon state={last ? runRowPresentationState(last) : item.last?.state ?? null} /></span>
          <span className="flow-choice-description">{item.description || t("Script workflow")}</span>
          <span className="flow-choice-meta"><span>{t("{0} steps", item.nodes)}{item.trigger.length ? ` · ${item.trigger.join(", ")}` : ""}</span><ChevronRight size={12} /></span>
        </button>;
      })}{query && !visibleFlows.length && <div className="flow-library-empty" role="status"><Search size={22} /><span>{t("No matching flows")}</span><Button size="small" onClick={clearSearch}>{t("Clear search")}</Button></div>}</div>
      <div className="flow-library-footer">{onCreate && <Button className="flow-create-action" onClick={onCreate}><Plus size={14} />{t("Create flow")}</Button>}{tab === "graph" && <button className="flow-library-config" onClick={() => onEdit(flow?.name, selectedNode ?? undefined)}><Code2 size={15} />{t("Configure scripts")}</button>}</div>
    </aside>
    <main className="flow-main">
      <div className="flow-compact-selector"><Workflow size={15} /><label>{t("Flow")}<select aria-label={t("Flow")} value={flow?.name ?? ""} disabled={!items.length} onChange={(event) => chooseFlow(event.target.value)}>{items.map((item) => <option key={item.name} value={item.name}>{item.name}</option>)}</select></label>{onCreate && <Button size="small" onClick={onCreate}><Plus size={13} />{t("Create flow")}</Button>}</div>
      <div className="flow-workspace-heading">
        <div className="flow-heading-emblem" aria-hidden="true">{tab === "ci" ? <Cloud size={24} /> : tab === "history" ? <History size={24} /> : <Workflow size={24} />}</div>
        <div className="flow-heading-copy"><span className="flow-eyebrow">{tab === "graph" ? t("Workflow") : t("Repository")}</span><h2>{title}</h2><p>{description}</p></div>
        {flow && tab === "graph" && <div className="flow-heading-actions"><Button onClick={() => onEdit(flow.name, selectedNode ?? undefined)}><Code2 size={14} />{t("Edit flow")}</Button><Button className="flow-run-button" kind="primary" disabled={busy !== null || !shownPlan || loading || !!error} onClick={() => onRun(flow.name)}>{busy === flow.name ? <Spinner size={13} /> : <Play size={13} fill="currentColor" />}{t("Run flow")}</Button></div>}
      </div>
      <div className="flow-tabs" role="tablist" aria-label={t("Flows")} onKeyDown={navigateTabs}>
        {tabs.map((item) => <button key={item.id} id={`${workspaceID}-${item.id}`} role="tab" aria-label={item.label} aria-selected={tab === item.id} aria-controls={`${workspaceID}-panel`} tabIndex={tab === item.id ? 0 : -1} className={tab === item.id ? "selected" : ""} onClick={() => setTab(item.id)}>{item.icon}{item.label}{item.id === "history" && <span className="flow-count">{flows.runs.length}</span>}</button>)}
      </div>
      <div className="flow-tab-panel" role="tabpanel" id={`${workspaceID}-panel`} aria-labelledby={`${workspaceID}-${tab}`} tabIndex={0}>
      {createdNotice && tab === "graph" && flow?.name === requestedFlow && <div className="flow-created-note" role="status"><CheckCircle2 size={16} /><span>{t("Flow created. Review its commands, then run it.")}</span><button type="button" aria-label={t("Close")} data-tip={t("Close")} onClick={() => setCreatedNotice(false)}><X size={14} /></button></div>}
      {tab === "ci" ? connectedCI : tab === "history" ? <FlowHistory flows={flows} onOpen={onOpen} /> : !flow && emptyState ? emptyState : <>
        <div className="flow-plan-meta">
          <span><Terminal size={12} />{shownPlan?.env || flow?.env || t("Local")}</span>
          <span><Layers3 size={12} />{t("{0} steps", shownPlan?.nodes.length ?? flow?.nodes ?? 0)}</span>
          <span><GitBranch size={12} />{t("{0} connections", shownPlan?.nodes.reduce((sum, node) => sum + node.needs.length, 0) ?? 0)}</span>
          <div className="flow-plan-actions">{latestID && <button className="flow-latest-run" onClick={() => onOpen(latestID)}>{latestState && <FlowStatePill state={latestState} />}<span>{active ? t("View running flow") : t("Show last run")}</span><ChevronRight size={12} /></button>}<Button className={`flow-review-button ${flows.list?.trusted === false ? "needs-review" : ""}`} size="small" disabled={!shownPlan || loading || !!error} onClick={() => flow && onReview(flow.name)}><ShieldCheck size={13} />{flows.list?.trusted === false ? t("Review required") : t("Review commands…")}</Button></div>
        </div>
        {error ? <div className="flow-empty error-text">{error}<Button onClick={() => onEdit(flow?.name, selectedNode ?? undefined)}>{t("Configure scripts")}</Button></div> : loading && !shownPlan ? <div className="flow-empty"><Spinner /></div> : <div className="flow-plan-body"><FlowGraph key={flow?.name} fitOnMount nodes={graphNodes} selected={selectedNode} onSelect={setSelectedNode} /><FlowInspector node={selected} live={selectedLive} onEdit={() => onEdit(flow?.name, selected?.id)} /></div>}
        {!!shownPlan?.warnings.length && <div className="flow-graph-warning">{shownPlan.warnings.join("\n")}</div>}
      </>}
      </div>
    </main>
  </div>;
}

function FlowInspector({ node, live, onEdit }: { node?: FlowPlanNode; live?: { state: string; durationMs: number | null }; onEdit: () => void }) {
  return <aside className="flow-inspector">
    <div className="flow-inspector-caption"><span className="flow-eyebrow">{t("Step details")}</span><Code2 size={13} /></div>
    {node ? <>
      <div className={`flow-inspector-heading kind-${flowBlockKind(node.block)}`}><span className="flow-node-type"><FlowBlockIcon block={node.block} size={19} /></span><div><h3>{node.id}</h3><span className="flow-step-block mono">{node.block}</span></div></div>
      {node.title && node.title !== node.id && <p className="flow-step-description">{node.title}</p>}
      {live && <div className="flow-step-live" role="status"><FlowStatePill state={live.state} />{live.durationMs != null && <span className="mono">{formatDuration(live.durationMs)}</span>}</div>}
      <Button className="flow-edit-step" size="small" block onClick={onEdit}><Code2 size={13} />{t("Edit step")}<ChevronRight size={12} /></Button>
      <dl className="flow-step-metadata">
        <div><dt>{t("Step")}</dt><dd className="mono">{node.id}</dd></div>
        <div><dt>{t("Depends on")}</dt><dd className="flow-dependency-list">{node.needs.length ? node.needs.map((id) => <span key={id} className="flow-dependency-chip mono">{id}</span>) : <span className="muted">{t("None")}</span>}</dd></div>
        <div><dt>{t("Executor")}</dt><dd><span className="flow-executor-dot" />{node.executor || "local"}</dd></div>
        {node.src && <div><dt>{t("Source")}</dt><dd className="mono flow-step-source">{node.src}</dd></div>}
      </dl>
      {node.run && <ScriptSurface title={t("Script")} script={node.run} />}
      {node.undo && <ScriptSurface title={t("Undo script")} script={node.undo} />}
      {node.reason?.message && <p className="flow-step-note">{node.reason.message}</p>}
      {node.outward && <span className="flow-graph-warning"><TriangleAlert size={12} />{t("Acts outside this computer")}</span>}
    </> : <div className="flow-inspector-empty"><Workflow size={28} /><p>{t("Choose a step to inspect its script and dependencies.")}</p></div>}
  </aside>;
}

function ScriptSurface({ title, script }: { title: string; script: string }) {
  return <section className="flow-code-surface"><h4><Terminal size={12} />{title}</h4><pre className="flow-script mono"><code>{script}</code></pre></section>;
}

function FlowHistory({ flows, onOpen }: { flows: FlowStore; onOpen: (run: string) => void }) {
  const [filter, setFilter] = useState("");
  const [state, setState] = useState("all");
  const runs = flows.runs.filter((run) => (!filter || run.flow.toLowerCase().includes(filter.toLowerCase()) || run.runId.toLowerCase().includes(filter.toLowerCase())) && (state === "all" || (state === "RUNNING" ? run.running : runRowPresentationState(run) === state)));
  const summary = [
    { label: t("Run history"), count: flows.runs.length, tone: "neutral", icon: <History size={15} /> },
    { label: t("Succeeded"), count: flows.runs.filter((run) => run.state === "SUCCEEDED").length, tone: "success", icon: <FlowStateIcon state="SUCCEEDED" size={15} /> },
    { label: t("Failed"), count: flows.runs.filter((run) => run.state === "FAILED").length, tone: "failure", icon: <FlowStateIcon state="FAILED" size={15} /> },
    { label: t("Running"), count: flows.runs.filter((run) => run.running).length, tone: "active", icon: <Clock3 size={15} /> },
  ];
  return <div className="flow-history" data-flow-history>
    <div className="flow-history-summary">{summary.map((item) => <div className={`flow-history-stat ${item.tone}`} key={item.tone}><span className="flow-history-stat-icon">{item.icon}</span><div><span>{item.label}</span><strong className="mono">{item.count}</strong></div></div>)}</div>
    <div className="flow-history-filters">
      <label className="flow-history-search"><Search size={15} /><input aria-label={t("Filter runs")} placeholder={t("Filter runs")} value={filter} onChange={(event) => setFilter(event.target.value)} /></label>
      <label className="flow-history-status"><ListFilter size={14} /><select aria-label={t("Run status")} value={state} onChange={(event) => setState(event.target.value)}><option value="all">{t("All statuses")}</option>{["RUNNING", "SUCCEEDED", "FAILED", "CANCELLED", "ROLLED_BACK", "ROLLBACK_FAILED", "REJECTED", "INTERRUPTED"].map((value) => <option key={value} value={value}>{stateTitle(value)}</option>)}</select></label>
    </div>
    {runs.length ? <div className="flow-history-list">
      <div className="flow-history-labels"><span>{t("Flow")}</span><span>{t("Status")}</span><span>{t("Started")}</span><span>{t("Duration")}</span></div>
      {runs.map((run) => <button className="flow-history-row" key={run.runId} onClick={() => onOpen(run.runId)} data-flow-run={run.runId}>
        <span className="flow-history-name"><span className="flow-history-run-icon"><Workflow size={15} /></span><span><strong>{run.flow}</strong><small className="mono">{run.runId}</small></span></span>
        <span className="flow-history-verdict"><FlowStatePill state={runRowPresentationState(run)} />{run.signed === false && !run.running && <TriangleAlert size={12} color="var(--orange)" data-tip={t("This record isn't signed by the engine, so gates don't trust it")} />}</span>
        <span className="flow-history-time">{run.startedAt ? <time dateTime={run.startedAt}>{new Date(run.startedAt).toLocaleDateString()}<small>{new Date(run.startedAt).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}</small></time> : "—"}</span>
        <span className="flow-history-duration mono">{run.durationMs != null ? formatDuration(run.durationMs) : "—"}<ChevronRight size={13} /></span>
      </button>)}
    </div> : <div className="flow-empty"><History size={30} /><strong>{t(flows.runs.length ? "No matching runs" : "No runs yet")}</strong>{flows.runs.length ? <Button onClick={() => { setFilter(""); setState("all"); }}>{t("Clear filters")}</Button> : <span>{t("Run a flow to see its steps, output and results here.")}</span>}</div>}
  </div>;
}
