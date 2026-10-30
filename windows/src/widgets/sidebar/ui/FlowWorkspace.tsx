import { Clock3, Code2, History, Play, ShieldCheck, TriangleAlert, Workflow } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { type FlowPlan, type FlowPlanNode, type FlowStore, flowEngine, formatDuration, runRowPresentationState } from "@/entities/flow";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, Spinner } from "@/shared/ui";
import { FlowGraph } from "./FlowGraph";
import { FlowStateIcon, stateTitle } from "./FlowState";

/** Flow selection, command inspection and execution history on one workspace. */
export function FlowWorkspace({ flows, affected, busy, onRun, onOpen, onEdit, onReview }: { flows: FlowStore; affected: boolean; busy: string | null; onRun: (flow: string) => void; onOpen: (run: string) => void; onEdit: () => void; onReview: (flow: string) => void }) {
  useObserve(flows);
  const [selectedFlow, setSelectedFlow] = useState<string | null>(null);
  const [tab, setTab] = useState<"graph" | "history">("graph");
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
    void flowEngine.plan(flow.name, flows.repo, affected).then((value) => { if (!stale) { loadedFlow.current = flow.name; setPlan(value); setSelectedNode((previous) => value.nodes.some((node) => node.id === previous) ? previous : value.nodes[0]?.id ?? null); } }, (reason) => { if (!stale) setError(reason instanceof Error ? reason.message : String(reason)); }).finally(() => { if (!stale) setLoading(false); });
    return () => { stale = true; };
  }, [flow?.name, flows.repo, flows.list, affected]);
  const active = flows.runs.find((run) => run.flow === flow?.name && run.running);
  const shownPlan = plan?.flow === flow?.name ? plan : null;
  const graphNodes = shownPlan?.nodes ?? [];
  const selected = shownPlan?.nodes.find((node) => node.id === selectedNode);
  return <div className="flow-workspace" data-flow-workspace>
    <aside className="flow-library">
      <div className="flow-library-title"><Workflow size={15} /><strong>{t("Flows")}</strong><span className="flow-count">{items.length}</span></div>
      <div className="flow-library-list">{items.map((item) => <button key={item.name} className={`flow-choice ${flow?.name === item.name ? "selected" : ""}`} onClick={() => setSelectedFlow(item.name)}>
        <span className="row"><FlowStateIcon state={flows.runs.find((run) => run.runId === item.last?.runId) ? runRowPresentationState(flows.runs.find((run) => run.runId === item.last?.runId)!) : item.last?.state ?? null} /><strong>{item.name}</strong></span>
        <span className="flow-choice-description">{item.description || t("Script workflow")}</span>
        <span className="flow-choice-meta">{t("{0} steps", item.nodes)}{item.trigger.length ? ` · ${item.trigger.join(", ")}` : ""}</span>
      </button>)}</div>
      <button className="flow-library-config" onClick={onEdit}><Code2 size={14} />{t("Configure scripts")}</button>
    </aside>
    <main className="flow-main">
      <div className="flow-workspace-heading"><div><h2>{flow?.name || t("Flows")}</h2><p>{flow?.description || t("Connect scripts into a repeatable workflow.")}</p></div><span className="spacer" />{flow && <><Button onClick={() => onReview(flow.name)}><ShieldCheck size={13} />{t("Review commands…")}</Button><Button kind="primary" disabled={busy !== null} onClick={() => onRun(flow.name)}>{busy === flow.name ? <Spinner size={12} /> : <Play size={12} />}{t("Run flow")}</Button></>}</div>
      <div className="flow-tabs" role="tablist" aria-label={t("Flows")}><button role="tab" aria-label={t("Flow graph")} aria-selected={tab === "graph"} className={tab === "graph" ? "selected" : ""} onClick={() => setTab("graph")}><Workflow size={14} />{t("Flow graph")}</button><button role="tab" aria-label={t("Run history")} aria-selected={tab === "history"} className={tab === "history" ? "selected" : ""} onClick={() => setTab("history")}><History size={14} />{t("Run history")}<span className="flow-count">{flows.runs.length}</span></button></div>
      {tab === "history" ? <FlowHistory flows={flows} onOpen={onOpen} /> : <>
        <div className="flow-plan-meta"><span><Clock3 size={12} />{shownPlan?.env || flow?.env || t("Local")}</span><span>{t("{0} steps", shownPlan?.nodes.length ?? flow?.nodes ?? 0)}</span><span>{t("{0} connections", shownPlan?.nodes.reduce((sum, node) => sum + node.needs.length, 0) ?? 0)}</span>{active && <button onClick={() => onOpen(active.runId)}><FlowStateIcon state="RUNNING" />{t("View running flow")}</button>}</div>
        {error ? <div className="flow-empty error-text">{error}<Button onClick={onEdit}>{t("Configure scripts")}</Button></div> : loading && !shownPlan ? <div className="flow-empty"><Spinner /></div> : <div className="flow-plan-body"><FlowGraph nodes={graphNodes} selected={selectedNode} onSelect={setSelectedNode} /><FlowInspector node={selected} /></div>}
        {!!shownPlan?.warnings.length && <div className="flow-graph-warning">{shownPlan.warnings.join("\n")}</div>}
      </>}
    </main>
  </div>;
}

function FlowInspector({ node }: { node?: FlowPlanNode }) {
  return <aside className="flow-inspector"><span className="flow-eyebrow">{t("Step details")}</span>{node ? <>
    <h3>{node.id}</h3><span className="flow-step-block mono">{node.block}</span>
    <dl><dt>{t("Step")}</dt><dd className="mono">{node.id}</dd><dt>{t("Depends on")}</dt><dd>{node.needs.join(", ") || t("None")}</dd><dt>{t("Executor")}</dt><dd>{node.executor || "local"}</dd>{node.src && <><dt>{t("Source")}</dt><dd className="mono">{node.src}</dd></>}</dl>
    {node.run && <><h4>{t("Script")}</h4><pre className="flow-script mono">{node.run}</pre></>}
    {node.undo && <><h4>{t("Undo script")}</h4><pre className="flow-script mono">{node.undo}</pre></>}
    {node.reason?.message && <p className="muted">{node.reason.message}</p>}
    {node.outward && <span className="flow-graph-warning">{t("Acts outside this computer")}</span>}
  </> : <p className="muted">{t("Choose a step to inspect its script and dependencies.")}</p>}</aside>;
}

function FlowHistory({ flows, onOpen }: { flows: FlowStore; onOpen: (run: string) => void }) {
  const [filter, setFilter] = useState("");
  const [state, setState] = useState("all");
  const runs = flows.runs.filter((run) => (!filter || run.flow.toLowerCase().includes(filter.toLowerCase()) || run.runId.toLowerCase().includes(filter.toLowerCase())) && (state === "all" || (state === "RUNNING" ? run.running : runRowPresentationState(run) === state)));
  return <div className="flow-history" data-flow-history><div className="flow-history-filters"><input aria-label={t("Filter runs")} placeholder={t("Filter runs")} value={filter} onChange={(event) => setFilter(event.target.value)} /><select aria-label={t("Run status")} value={state} onChange={(event) => setState(event.target.value)}><option value="all">{t("All statuses")}</option>{["RUNNING", "SUCCEEDED", "FAILED", "CANCELLED", "ROLLED_BACK", "ROLLBACK_FAILED", "REJECTED", "INTERRUPTED"].map((value) => <option key={value} value={value}>{stateTitle(value)}</option>)}</select></div>
    {runs.length ? <div className="flow-history-list"><div className="flow-history-labels"><span>{t("Flow")}</span><span>{t("Status")}</span><span>{t("Started")}</span><span>{t("Duration")}</span></div>{runs.map((run) => <button className="flow-history-row" key={run.runId} onClick={() => onOpen(run.runId)} data-flow-run={run.runId}><span><strong>{run.flow}</strong><small className="mono">{run.runId}</small></span><span className="row"><FlowStateIcon state={runRowPresentationState(run)} />{stateTitle(runRowPresentationState(run))}{run.signed === false && !run.running && <TriangleAlert size={12} color="var(--orange)" data-tip={t("This record isn't signed by the engine, so gates don't trust it")} />}</span><span>{run.startedAt ? new Date(run.startedAt).toLocaleString() : "—"}</span><span className="mono">{run.durationMs != null ? formatDuration(run.durationMs) : "—"}</span></button>)}</div> : <div className="flow-empty"><History size={28} /><strong>{t("No runs yet")}</strong><span>{t("Run a flow to see its steps, output and results here.")}</span></div>}
  </div>;
}
