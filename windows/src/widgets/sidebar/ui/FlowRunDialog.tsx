import { FileSearch } from "lucide-react";
import { ChevronDown, ChevronRight, Circle, CircleX, Undo2 } from "@/shared/icons";
import { useEffect, useMemo, useRef, useState } from "react";
import { type FlowStepView, type FlowStore, flowEngine, flowSkipCause, flowTone, formatDuration, isBadState, runCounts, runPresentationState, type RunNode } from "@/entities/flow";
import { ipc } from "@/shared/api";
import { joinPath } from "@/shared/config";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, IconButton, Modal, Spinner, StatusPill } from "@/shared/ui";
import { FlowGraph } from "./FlowGraph";
import { FlowStateIcon, flowStepKindTitle, stateTitle } from "./FlowState";
import { StepOutcome, StepVerdicts } from "./FlowStepDetails";
import "./flow-run.css";

type Json = Record<string, unknown>;
const arr = (v: unknown) => (Array.isArray(v) ? (v as Json[]) : []);
const str = (v: unknown) => (typeof v === "string" ? v : null);

/** The groups of the step list, in the order a person needs them: what failed, what is going, what was left out, what passed */
const GROUPS: { state: string; has: (node: RunNode) => boolean }[] = [
  { state: "FAILED", has: (node) => isBadState(node.state) },
  { state: "RUNNING", has: (node) => node.state === "RUNNING" },
  { state: "PENDING", has: (node) => node.state === "PENDING" },
  { state: "SKIPPED", has: (node) => node.state === "SKIPPED" },
  { state: "PASSED", has: (node) => node.state === "PASSED" || node.state === "CACHED" },
];

/** A run node in the shape the step details draw (the run is its own plan) */
const asStep = (node: RunNode): FlowStepView => ({ id: node.id, title: node.title, block: node.block, needs: node.needs, decision: "run", state: node.state, durationMs: node.durationMs });

/**
 * One run: the step graph with its states, the steps grouped by outcome, and the chosen step's result and output.
 * Verdicts are shown exactly as the engine made them. (macOS: FlowRunSheet)
 */
export function FlowRunDialog({ flows, runId, onClose }: { flows: FlowStore; runId: string; onClose: () => void }) {
  useObserve(flows);
  const [selected, setSelected] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);
  const [cancelling, setCancelling] = useState(false);
  const [showPassed, setShowPassed] = useState<boolean | null>(null);
  useEffect(() => {
    void flows.open(runId);
  }, [flows, runId]);
  const view = flows.views.get(runId);
  const record = flows.records.get(runId);
  const running = !!view && !view.done;
  const nodes = view?.nodes ?? [];
  // Without a choice, the node that is running (or else the first that failed)
  const shown = useMemo(() => {
    const pick = nodes.find((n) => n.id === selected);
    if (pick) return pick;
    return nodes.find((n) => n.state === "RUNNING") ?? nodes.find((n) => isBadState(n.state)) ?? nodes[0] ?? null;
  }, [nodes, selected, view?.lastSeq]);
  const state = view ? runPresentationState(view) : str(record?.state);
  const counts = view ? runCounts(view) : null;
  const steps = nodes.map(asStep);
  // Passed steps fold away while something else needs reading; a run where everything passed shows them.
  const passedOpen = showPassed ?? !nodes.some((node) => node.state !== "PASSED" && node.state !== "CACHED");
  const code = view?.code ?? str(record?.code);
  return (
    <Modal
      width={960}
      onClose={onClose}
      title={
        <div className="flow-run-title">
          <span className="flow-run-name">
            <span>{view?.flow || str(record?.flow) || ""}</span>
            <StatusPill tone={flowTone(state)} icon={<FlowStateIcon state={state} size={11} />}>{stateTitle(state)}</StatusPill>
          </span>
          <span className="flow-run-context">
            <span className="mono">{runId}</span>
            {code && <span className="mono">{code}</span>}
            {counts && <span>{t("{0} passed · {1} failed · {2} steps", counts.passed, counts.failed, counts.total)}</span>}
          </span>
        </div>
      }
      footer={
        <>
          <Button
            disabled={running}
            tip={t("Copy a Markdown summary (failures with file and line) to paste into a PR or an AI chat")}
            onClick={() =>
              void flowEngine.markdown(runId, flows.repo).then((md) => {
                void navigator.clipboard.writeText(md);
                setCopied(true);
              })
            }
          >
            {copied ? t("Copied") : t("Copy summary")}
          </Button>
          {running && (
            <Button
              kind="danger"
              disabled={cancelling}
              tip={t("Stops every step and its child processes, then undoes what was changed")}
              onClick={() => {
                setCancelling(true);
                void flows.cancel(runId).catch(() => setCancelling(false));
              }}
            >
              {t("Cancel run")}
            </Button>
          )}
          {running && <Spinner size={12} />}
          <span className="spacer" />
          <Button kind="primary" onClick={onClose}>
            {t("Done")}
          </Button>
        </>
      }
    >
      <div className="flow-run">
        <div className="flow-run-overview">
          {nodes.length > 0 && <div className="flow-run-graph"><FlowGraph fitOnMount nodes={nodes} selected={shown?.id ?? null} onSelect={setSelected} /></div>}
          <nav className="flow-run-steps" aria-label={t("Steps")}>
            {GROUPS.map((group) => {
              const members = nodes.filter(group.has);
              if (!members.length) return null;
              const folds = group.state === "PASSED";
              const open = !folds || passedOpen;
              const label = `${stateTitle(group.state)} ${members.length}`;
              return (
                <div key={group.state} className="flow-run-group">
                  {folds
                    ? <button type="button" className="flow-run-group-title" aria-expanded={open} onClick={() => setShowPassed(!open)}>{open ? <ChevronDown size={10} /> : <ChevronRight size={10} />}{label}</button>
                    : <span className="flow-run-group-title">{label}</span>}
                  {open && members.map((n) => (
                    <button type="button" key={n.id} className={`flow-run-step ${shown?.id === n.id ? "selected" : ""}`} aria-current={shown?.id === n.id} onClick={() => setSelected(n.id)}>
                      <FlowStateIcon state={n.state} size={14} />
                      <span className="flow-run-step-name mono">{n.branchOf ? "↳ " + n.id : n.id}</span>
                      {n.state === "SKIPPED" && flowSkipCause(asStep(n), steps) && <span className="flow-run-step-note">{t("Needs")} <span className="mono">{flowSkipCause(asStep(n), steps)}</span></span>}
                      <span className="spacer" />
                      {n.testsExecuted != null && <span className="flow-run-step-meta mono">{`${n.testsPassed ?? 0}/${n.testsExecuted}`}</span>}
                      {n.durationMs != null && <span className="flow-run-step-meta mono">{formatDuration(n.durationMs)}</span>}
                    </button>
                  ))}
                </div>
              );
            })}
            {!!view?.steps.length && (
              <div className="flow-run-group">
                <span className="flow-run-group-title">{t("Services and rollback")}</span>
                {view.steps.map((s) => (
                  <div key={s.id} className="flow-run-service">
                    {s.state === "UNDONE" ? <Undo2 size={12} /> : s.state === "FAILED" ? <CircleX size={12} color="var(--red)" /> : <Circle size={12} />}
                    <span className="flow-run-step-name">{s.node ? `${s.node}: ${s.text}` : s.text}</span>
                    <span className="flow-run-step-meta mono">{s.state}</span>
                  </div>
                ))}
              </div>
            )}
          </nav>
        </div>
        <section className="flow-run-detail" aria-label={shown?.id}>
          {shown ? <NodeDetail node={shown} steps={steps} record={record} repo={flows.repo} /> : <RollbackNote record={record} empty={nodes.length === 0} />}
        </section>
      </div>
    </Modal>
  );
}

/** The chosen step: its outcome and reason first, then failed tests, verdicts and the output that keeps following a live run */
function NodeDetail({ node, steps, record, repo }: { node: RunNode; steps: FlowStepView[]; record: Json | undefined; repo: string }) {
  const rec = arr(record?.nodes).find((n) => n.id === node.id);
  const failures = arr(rec?.failures);
  const logRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const el = logRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [node.id, node.tail.length]);
  const runDir = str(record?.runDir);
  return (
    <>
      <header className="flow-inspector-header">
        <strong className="mono selectable">{node.id}</strong>
        <StatusPill tone="neutral">{flowStepKindTitle(node.block)}</StatusPill>
        <span className="spacer" />
        {node.log && runDir && <IconButton small icon={<FileSearch size={13} />} tip={t("Show the full log in Explorer")} aria-label={t("Show the full log in Explorer")} onClick={() => void ipc.reveal(joinPath(runDir, node.log!))} />}
      </header>
      <div className="flow-run-detail-body">
        <StepOutcome step={asStep(node)} steps={steps} run={node} failure={rec?.failure as Json | undefined} />
        {failures.length > 0 && (
          <section className="flow-step-section">
            <h4>{t("Failed tests")}</h4>
            {failures.map((f, i) => (
              <div key={i} className="flow-run-failure">
                <span>{str(f.name)}</span>
                {str(f.file) && (
                  <button className="link mono" data-tip={t("Show in Explorer")} onClick={() => void ipc.reveal(joinPath(repo, str(f.file)!))}>
                    {str(f.file)}
                    {typeof f.line === "number" ? `:${f.line}` : ""}
                  </button>
                )}
                {str(f.message) && <span className="muted">{str(f.message)}</span>}
              </div>
            ))}
          </section>
        )}
        <StepVerdicts verdicts={arr(rec?.verdicts)} />
        <section className="flow-step-section flow-run-output">
          <h4>{t("Output")}</h4>
          <div ref={logRef} className="flow-output mono" role="region" aria-label={t("Output")} tabIndex={0}>
            {node.tail.map((line, index) => <div key={index} className="flow-output-line">{line || " "}</div>)}
          </div>
        </section>
      </div>
    </>
  );
}

function RollbackNote({ record, empty }: { record: Json | undefined; empty: boolean }) {
  const rb = record?.rollback as Json | null | undefined;
  const kept = arr(rb?.kept).map(String);
  return (
    <div className="col" style={{ flex: 1, alignItems: "center", justifyContent: "center", gap: 8, textAlign: "center" }}>
      {rb && str(rb.state) === "ROLLBACK_FAILED" && <span style={{ color: "var(--red)" }}>{t("Rollback failed. The environment is on hold until a person checks it and releases it (gitch flow hold release).")}</span>}
      {rb && str(rb.state) === "ROLLED_BACK" && <span style={{ color: "var(--orange)" }}>{t("The changes were undone in reverse order.")}</span>}
      {rb && str(rb.why) && <span className="muted" style={{ fontSize: 11.5 }}>{str(rb.why)}</span>}
      {kept.length > 0 && <span className="muted" style={{ fontSize: 11.5 }}>{t("Kept as is: {0}", kept.join(", "))}</span>}
      <span className="muted">{empty ? t("Waiting for the engine…") : t("Choose a step to see its output.")}</span>
    </div>
  );
}
