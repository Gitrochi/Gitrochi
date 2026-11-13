import { Square } from "lucide-react";
import { type KeyboardEvent, type ReactNode, useEffect, useId, useRef, useState } from "react";
import { type FlowItem, type FlowPlan, type FlowStore, flowBanner, flowEngine, flowStepViews, isBadState } from "@/entities/flow";
import { CircleX, Ellipsis, File, Plus } from "@/shared/icons";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, IconButton, type MenuItem, NoticeBlock, showMenuBelow, Spinner } from "@/shared/ui";
import { FlowGraph } from "./FlowGraph";
import { FlowHistory } from "./FlowHistory";
import { FlowLibrary } from "./FlowLibrary";
import { FlowRunBanner } from "./FlowRunBanner";
import { FlowStepDetails } from "./FlowStepDetails";

type Tab = "graph" | "history" | "ci";

/**
 * The Flows workspace, left to right: the list of flows, the selected flow (its name and actions, then Flow /
 * History / Connected CI), and the selected step. The Flow tab shows one banner about the latest run and the steps
 * as a graph in which a connector means "needs". (macOS: FlowWorkspaceView)
 */
export function FlowWorkspace({ flows, affected, busy, requestedFlow, onCreate, onRun, onStop, onOpen, onEdit, onReview, moreActions, connectedCI, emptyState }: {
  flows: FlowStore;
  /** Run only the steps the working changes affect */
  affected: boolean;
  /** The flow whose run is being prepared, if any */
  busy: string | null;
  /** A flow to select from outside, such as the one just created */
  requestedFlow?: string;
  onCreate?: () => void;
  onRun: (flow: string) => void;
  onStop: (runId: string) => void;
  onOpen: (runId: string) => void;
  onEdit: (flow?: string, step?: string) => void;
  onReview: (flow: string) => void;
  /** The "More flow actions" menu for the selected flow */
  moreActions: (flow: FlowItem) => MenuItem[];
  connectedCI?: ReactNode;
  /** Shown instead of the workspace while the repository has no flow to select */
  emptyState: ReactNode;
}) {
  useObserve(flows);
  const [selectedFlow, setSelectedFlow] = useState<string | null>(null);
  const [selectedStep, setSelectedStep] = useState<string | null>(null);
  const [search, setSearch] = useState("");
  const [tab, setTab] = useState<Tab>("graph");
  const [justCreated, setJustCreated] = useState<string | null>(null);
  const workspaceID = useId();
  /** The flow whose step the person chose themselves, so the workspace stops moving the selection for it */
  const pickedBy = useRef<string | null>(null);

  const items = flows.list?.flows ?? [];
  const flow = items.find((item) => item.name === selectedFlow) ?? items[0];
  const { plan, error, loading } = useFlowPlan(flows, flow?.name, affected, setSelectedStep);

  const chooseFlow = (name: string) => {
    if (name !== flow?.name) { setSelectedStep(null); pickedBy.current = null; }
    setSelectedFlow(name);
    setJustCreated(null);
    setTab("graph");
  };
  useEffect(() => {
    if (!requestedFlow) return;
    setSelectedFlow(requestedFlow); setSelectedStep(null); setSearch(""); setTab("graph"); setJustCreated(requestedFlow);
  }, [requestedFlow]);

  // The latest run of the selected flow, read once so the graph can show how each step did.
  const runs = flows.runs.filter((run) => run.flow === flow?.name);
  const latest = runs.find((run) => run.running) ?? runs[0];
  const latestID = latest?.runId;
  useEffect(() => { if (latestID && !flows.views.has(latestID)) void flows.open(latestID); }, [flows, latestID]);

  const trusted = flows.list?.trusted !== false;
  const banner = flowBanner({ trusted, latest, view: latestID ? flows.views.get(latestID) : undefined });
  // A changed flow file has no results yet: the old run's states would describe commands that no longer exist.
  const view = banner.kind === "review" || !latestID ? undefined : flows.views.get(latestID);
  const steps = plan ? flowStepViews(plan.nodes, view) : [];
  // Open on the step that needs attention (failed, else running) until the person picks one themselves.
  const attention = view?.nodes.find((node) => isBadState(node.state))?.id ?? view?.nodes.find((node) => node.state === "RUNNING")?.id;
  useEffect(() => {
    if (attention && plan && pickedBy.current !== flow?.name && plan.nodes.some((node) => node.id === attention)) setSelectedStep(attention);
  }, [attention, plan, flow?.name]);
  const chooseStep = (id: string) => { pickedBy.current = flow?.name ?? null; setSelectedStep(id); };
  const step = steps.find((entry) => entry.id === selectedStep);
  const runStep = view?.nodes.find((node) => node.id === selectedStep);

  if (!flow) return <div className="flow-workspace" data-flow-workspace>{emptyState}</div>;

  const tabs: { id: Tab; label: string }[] = [
    { id: "graph", label: t("Flow") },
    { id: "history", label: t("History") },
    ...(connectedCI ? [{ id: "ci" as const, label: t("Connected CI") }] : []),
  ];
  const navigateTabs = (event: KeyboardEvent<HTMLDivElement>) => {
    if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return;
    event.preventDefault();
    const index = tabs.findIndex((item) => item.id === tab);
    const next = event.key === "Home" ? 0 : event.key === "End" ? tabs.length - 1 : (index + (event.key === "ArrowRight" ? 1 : -1) + tabs.length) % tabs.length;
    setTab(tabs[next].id);
    event.currentTarget.querySelectorAll<HTMLButtonElement>('[role="tab"]')[next]?.focus();
  };
  const editFlow = () => onEdit(flow.name, selectedStep ?? undefined);

  return (
    <div className="flow-workspace" data-flow-workspace>
      <FlowLibrary flows={items} runs={flows.runs} selected={flow.name} search={search} onSearch={setSearch} onChoose={chooseFlow} onCreate={onCreate} />
      <main className="flow-main">
        <div className="flow-compact-selector">
          <label>{t("Flow")}
            <select aria-label={t("Flow")} value={flow.name} onChange={(event) => chooseFlow(event.target.value)}>
              {items.map((item) => <option key={item.name} value={item.name}>{item.name}</option>)}
            </select>
          </label>
          {onCreate && <Button size="small" onClick={onCreate}><Plus size={13} />{t("New flow…")}</Button>}
        </div>
        <header className="flow-workspace-heading">
          <div className="flow-heading-copy">
            <h2>{flow.name}</h2>
            {flow.description && <p>{flow.description}</p>}
          </div>
          <div className="flow-heading-actions">
            <Button onClick={editFlow}><File size={14} />{t("Edit flow file…")}</Button>
            {latest?.running
              ? <Button tip={t("Stops every step and its child processes, then undoes what was changed")} onClick={() => onStop(latest.runId)}><Square size={10} fill="currentColor" />{t("Stop")}</Button>
              : <Button className="flow-run-button" kind="primary" disabled={busy !== null || !plan || loading || !!error} onClick={() => onRun(flow.name)}>{busy === flow.name ? <Spinner size={13} /> : <PlayGlyph />}{t("Run flow")}</Button>}
            <IconButton icon={<Ellipsis size={14} />} tip={t("More flow actions")} aria-label={t("More flow actions")} aria-haspopup="menu" onClick={(event) => showMenuBelow(event.currentTarget, moreActions(flow))} />
          </div>
        </header>
        <div className="flow-tabs" role="tablist" aria-label={t("Flows")} onKeyDown={navigateTabs}>
          {tabs.map((item) => (
            <button key={item.id} id={`${workspaceID}-${item.id}`} role="tab" aria-label={item.label} aria-selected={tab === item.id} aria-controls={`${workspaceID}-panel`} tabIndex={tab === item.id ? 0 : -1} className={tab === item.id ? "selected" : ""} onClick={() => setTab(item.id)}>{item.label}</button>
          ))}
        </div>
        <div className="flow-tab-panel" role="tabpanel" id={`${workspaceID}-panel`} aria-labelledby={`${workspaceID}-${tab}`} tabIndex={0}>
          {tab === "ci" ? connectedCI : tab === "history" ? <FlowHistory runs={runs} onOpen={onOpen} /> : (
            <div className="flow-plan">
              <div className="flow-plan-main">
                {error
                  ? <NoticeBlock className="flow-banner" tone="failed" alert icon={<CircleX size={14} />} title={t("Couldn't read this flow")} caption={error} actions={[{ label: t("Edit flow file…"), onClick: editFlow }]} />
                  : <FlowRunBanner banner={banner} created={justCreated === flow.name} steps={{ done: view?.nodes.filter((node) => !["PENDING", "RUNNING"].includes(node.state)).length ?? 0, total: view?.nodes.length ?? 0 }} onOpenRun={onOpen} onReview={() => onReview(flow.name)} />}
                {plan
                  ? <FlowGraph key={flow.name} fitOnMount nodes={steps} selected={selectedStep} onSelect={chooseStep} />
                  : !error && <div className="flow-empty"><Spinner /></div>}
                {!!plan?.warnings.length && <div className="flow-graph-warning">{plan.warnings.join("\n")}</div>}
              </div>
              {plan && <FlowStepDetails step={step} steps={steps} run={runStep} record={view && latestID ? flows.records.get(latestID) : undefined} onEdit={() => onEdit(flow.name, step?.id)} onOpenRun={runStep && latestID ? () => onOpen(latestID) : undefined} />}
            </div>
          )}
        </div>
      </main>
    </div>
  );
}

/** The plan of one flow, re-read when the flow, its file or the affected-only switch changes */
function useFlowPlan(flows: FlowStore, flow: string | undefined, affected: boolean, selectStep: (update: (previous: string | null) => string | null) => void) {
  const [plan, setPlan] = useState<FlowPlan | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const loaded = useRef<string | null>(null);
  useEffect(() => {
    let stale = false;
    if (loaded.current !== flow) { setPlan(null); selectStep(() => null); }
    setError(null);
    if (!flow) { setLoading(false); return; }
    setLoading(true);
    void flowEngine.plan(flow, flows.repo, affected).then((value) => {
      if (stale) return;
      loaded.current = flow;
      setPlan(value);
      // Keep the chosen step across a refresh; otherwise start on the first one so the details are never empty.
      selectStep((previous) => value.nodes.some((node) => node.id === previous) ? previous : value.nodes[0]?.id ?? null);
    }, (reason) => { if (!stale) setError(reason instanceof Error ? reason.message : String(reason)); }).finally(() => { if (!stale) setLoading(false); });
    return () => { stale = true; };
  }, [flow, flows.repo, flows.list, affected]);
  return { plan: plan?.flow === flow ? plan : null, error, loading };
}

function PlayGlyph() {
  return <svg width="12" height="12" viewBox="0 0 16 16" aria-hidden="true"><path d="M4.5 3v10l8.5-5z" fill="currentColor" /></svg>;
}
