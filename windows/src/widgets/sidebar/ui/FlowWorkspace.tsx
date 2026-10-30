import { ChevronRight, Clock3, Cloud, Code2, GitBranch, History, Layers3, ListFilter, Play, Search, ShieldCheck, Terminal, TriangleAlert, Workflow } from "lucide-react";
import { type ReactNode, useEffect, useRef, useState } from "react";
import { type FlowPlan, type FlowPlanNode, type FlowStore, flowEngine, formatDuration, runRowPresentationState } from "@/entities/flow";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, Spinner } from "@/shared/ui";
import { FlowGraph } from "./FlowGraph";
import { FlowBlockIcon, FlowStateIcon, FlowStatePill, flowBlockKind, stateTitle } from "./FlowState";

/** Flow selection, command inspection and execution history on one workspace. */
export function FlowWorkspace({ flows, affected, busy, onRun, onOpen, onEdit, onReview, connectedCI, emptyState }: { flows: FlowStore; affected: boolean; busy: string | null; onRun: (flow: string) => void; onOpen: (run: string) => void; onEdit: (flow?: string, node?: string) => void; onReview: (flow: string) => void; connectedCI?: ReactNode; emptyState?: ReactNode }) {
  useObserve(flows);
  const [selectedFlow, setSelectedFlow] = useState<string | null>(null);
  const [tab, setTab] = useState<"graph" | "history" | "ci">("graph");
  const [plan, setPlan] = useState<FlowPlan | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [selectedNode, setSelectedNode] = useState<string | null>(null);
  const loadedFlow = useRef<string | null>(null);
  const items = flows.list?.flows ?? [];
  const flow = items.find((item) => item.name === selectedFlow) ?? items[0];
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
  const shownPlan = plan?.flow === flow?.name ? plan : null;
  const graphNodes = shownPlan?.nodes ?? [];
  const selected = shownPlan?.nodes.find((node) => node.id === selectedNode);
  return <div className="flow-workspace" data-flow-workspace>
    <aside className="flow-library">
      <div className="flow-library-title"><Workflow size={16} /><strong>{t("Flows")}</strong><span className="flow-count">{items.length}</span></div>
      <div className="flow-library-list">{items.map((item) => {
        const last = flows.runs.find((run) => run.runId === item.last?.runId);
        return <button key={item.name} className={`flow-choice ${flow?.name === item.name ? "selected" : ""}`} aria-pressed={flow?.name === item.name} onClick={() => setSelectedFlow(item.name)}>
          <span className="flow-choice-heading"><span className="flow-choice-icon"><Workflow size={14} /></span><strong>{item.name}</strong><FlowStateIcon state={last ? runRowPresentationState(last) : item.last?.state ?? null} /></span>
          <span className="flow-choice-description">{item.description || t("Script workflow")}</span>
          <span className="flow-choice-meta"><span>{t("{0} steps", item.nodes)}{item.trigger.length ? ` · ${item.trigger.join(", ")}` : ""}</span><ChevronRight size={12} /></span>
        </button>;
      })}</div>
      <button className="flow-library-config" onClick={() => onEdit(flow?.name, selectedNode ?? undefined)}><Code2 size={15} />{t("Configure scripts")}</button>
    </aside>
    <main className="flow-main">
      <div className="flow-workspace-heading">
        <div className="flow-heading-emblem" aria-hidden="true"><Workflow size={24} /></div>
        <div className="flow-heading-copy"><span className="flow-eyebrow">{t("Workflow")}</span><h2>{flow?.name || t("Flows")}</h2><p>{flow?.description || t("Connect scripts into a repeatable workflow.")}</p></div>
        {flow && <div className="flow-heading-actions"><Button onClick={() => onEdit(flow?.name, selectedNode ?? undefined)}><Code2 size={14} />{t("Edit modules")}</Button><Button className="flow-review-button" onClick={() => onReview(flow.name)}><ShieldCheck size={14} />{t("Review commands…")}</Button><Button className="flow-run-button" kind="primary" disabled={busy !== null} onClick={() => onRun(flow.name)}>{busy === flow.name ? <Spinner size={13} /> : <Play size={13} fill="currentColor" />}{t("Run flow")}</Button></div>}
      </div>
      <div className="flow-tabs" role="tablist" aria-label={t("Flows")}>
        <button role="tab" aria-label={t("Flow graph")} aria-selected={tab === "graph"} className={tab === "graph" ? "selected" : ""} onClick={() => setTab("graph")}><Workflow size={15} />{t("Flow graph")}</button>
        <button role="tab" aria-label={t("Run history")} aria-selected={tab === "history"} className={tab === "history" ? "selected" : ""} onClick={() => setTab("history")}><History size={15} />{t("Run history")}<span className="flow-count">{flows.runs.length}</span></button>
        {connectedCI && <button role="tab" aria-label={t("Connected CI")} aria-selected={tab === "ci"} className={tab === "ci" ? "selected" : ""} onClick={() => setTab("ci")}><Cloud size={15} />{t("Connected CI")}</button>}
      </div>
      {tab === "ci" ? connectedCI : tab === "history" ? <FlowHistory flows={flows} onOpen={onOpen} /> : !flow && emptyState ? emptyState : <>
        <div className="flow-plan-meta">
          <span><Terminal size={12} />{shownPlan?.env || flow?.env || t("Local")}</span>
          <span><Layers3 size={12} />{t("{0} steps", shownPlan?.nodes.length ?? flow?.nodes ?? 0)}</span>
          <span><GitBranch size={12} />{t("{0} connections", shownPlan?.nodes.reduce((sum, node) => sum + node.needs.length, 0) ?? 0)}</span>
          {active && <button onClick={() => onOpen(active.runId)}><FlowStateIcon state="RUNNING" />{t("View running flow")}<ChevronRight size={12} /></button>}
        </div>
        {error ? <div className="flow-empty error-text">{error}<Button onClick={() => onEdit(flow?.name, selectedNode ?? undefined)}>{t("Configure scripts")}</Button></div> : loading && !shownPlan ? <div className="flow-empty"><Spinner /></div> : <div className="flow-plan-body"><FlowGraph key={flow?.name} nodes={graphNodes} selected={selectedNode} onSelect={setSelectedNode} /><FlowInspector node={selected} /></div>}
        {!!shownPlan?.warnings.length && <div className="flow-graph-warning">{shownPlan.warnings.join("\n")}</div>}
      </>}
    </main>
  </div>;
}

function FlowInspector({ node }: { node?: FlowPlanNode }) {
  return <aside className="flow-inspector">
    <div className="flow-inspector-caption"><span className="flow-eyebrow">{t("Step details")}</span><Code2 size={13} /></div>
    {node ? <>
      <div className={`flow-inspector-heading kind-${flowBlockKind(node.block)}`}><span className="flow-node-type"><FlowBlockIcon block={node.block} size={19} /></span><div><h3>{node.id}</h3><span className="flow-step-block mono">{node.block}</span></div></div>
      {node.title && node.title !== node.id && <p className="flow-step-description">{node.title}</p>}
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
    </div> : <div className="flow-empty"><History size={30} /><strong>{t("No runs yet")}</strong><span>{t("Run a flow to see its steps, output and results here.")}</span></div>}
  </div>;
}
