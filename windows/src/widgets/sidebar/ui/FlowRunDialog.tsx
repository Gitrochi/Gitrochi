import { Circle, CircleX, FileSearch, Undo2 } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";
import { type FlowStore, flowEngine, formatDuration, isBadState, runCounts, runPresentationState, type RunNode } from "@/entities/flow";
import { ipc } from "@/shared/api";
import { joinPath } from "@/shared/config";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, IconButton, Modal, Spinner } from "@/shared/ui";
import { FlowGraph } from "./FlowGraph";
import { FlowStateIcon, stateTitle } from "./FlowState";

type Json = Record<string, unknown>;
const arr = (v: unknown) => (Array.isArray(v) ? (v as Json[]) : []);
const str = (v: unknown) => (typeof v === "string" ? v : null);

/** One run: live node states, the end of the chosen node's log, failure locations and rollback. Verdicts are shown exactly as the engine made them. */
export function FlowRunDialog({ flows, runId, onClose }: { flows: FlowStore; runId: string; onClose: () => void }) {
  useObserve(flows);
  const [selected, setSelected] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);
  const [cancelling, setCancelling] = useState(false);
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
    if (pick && !(pick.state === "PASSED" && !selected)) return pick;
    return nodes.find((n) => n.state === "RUNNING") ?? nodes.find((n) => isBadState(n.state)) ?? pick ?? nodes[0] ?? null;
  }, [nodes, selected, view?.lastSeq]);
  const state = view ? runPresentationState(view) : str(record?.state);
  const counts = view ? runCounts(view) : null;
  return (
    <Modal
      width={900}
      onClose={onClose}
      title={
        <div className="row" style={{ gap: 8 }}>
          <FlowStateIcon state={state} size={16} />
          <span>{view?.flow || str(record?.flow) || ""}</span>
          <span className="muted" style={{ fontSize: 12, fontWeight: 400 }}>
            {stateTitle(state)}
            {(view?.code ?? str(record?.code)) ? ` · ${view?.code ?? str(record?.code)}` : ""}
          </span>
          <span className="spacer" />
          {counts && <span className="muted" style={{ fontSize: 12, fontWeight: 400 }}>{t("{0} passed · {1} failed · {2} steps", counts.passed, counts.failed, counts.total)}</span>}
          {running && <Spinner size={12} />}
        </div>
      }
      footer={
        <>
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
          <span className="spacer" />
          <Button kind="primary" onClick={onClose}>
            {t("Done")}
          </Button>
        </>
      }
    >
      {nodes.length > 0 && <div className="flow-run-graph"><FlowGraph nodes={nodes} selected={shown?.id ?? null} onSelect={setSelected} /></div>}
      <div className="row" style={{ alignItems: "stretch", gap: 12, height: 330 }}>
        <div className="col" style={{ width: 260, flex: "none", overflow: "auto", borderRight: "1px solid var(--border)", paddingRight: 8 }}>
          <div className="muted" style={{ fontSize: 11, fontWeight: 600, padding: "2px 4px" }}>{t("Steps")}</div>
          {nodes.map((n) => (
            <div key={n.id} className={`side-row ${shown?.id === n.id ? "current" : ""}`} style={{ gap: 6 }} onClick={() => setSelected(n.id)}>
              <FlowStateIcon state={n.state} size={13} />
              <span style={{ flex: 1, minWidth: 0, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{n.branchOf ? "↳ " + n.id : n.id}</span>
              {n.testsExecuted != null && <span className="muted mono" style={{ fontSize: 11 }}>{`${n.testsPassed ?? 0}/${n.testsExecuted}`}</span>}
              {n.durationMs != null && <span className="muted mono" style={{ fontSize: 11 }}>{formatDuration(n.durationMs)}</span>}
            </div>
          ))}
          {!!view?.steps.length && (
            <>
              <div className="muted" style={{ fontSize: 11, fontWeight: 600, padding: "10px 4px 2px" }}>{t("Services and rollback")}</div>
              {view.steps.map((s) => (
                <div key={s.id} className="row" style={{ gap: 6, padding: "2px 6px", fontSize: 12 }}>
                  {s.state === "UNDONE" ? <Undo2 size={12} /> : s.state === "FAILED" ? <CircleX size={12} color="var(--red)" /> : <Circle size={12} />}
                  <span style={{ flex: 1, minWidth: 0, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{s.node ? `${s.node}: ${s.text}` : s.text}</span>
                  <span className="muted mono" style={{ fontSize: 10.5 }}>{s.state}</span>
                </div>
              ))}
            </>
          )}
        </div>
        <div className="col" style={{ flex: 1, minWidth: 0, gap: 8 }}>
          {shown ? <NodeDetail node={shown} record={record} repo={flows.repo} /> : <RollbackNote record={record} empty={nodes.length === 0} />}
        </div>
      </div>
    </Modal>
  );
}

function NodeDetail({ node, record, repo }: { node: RunNode; record: Json | undefined; repo: string }) {
  const rec = arr(record?.nodes).find((n) => n.id === node.id);
  const failure = rec?.failure as Json | null | undefined;
  const failures = arr(rec?.failures);
  const verdicts = arr(rec?.verdicts);
  const logRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const el = logRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [node.tail.length]);
  const runDir = str(record?.runDir);
  return (
    <>
      <div className="row" style={{ gap: 8 }}>
        <FlowStateIcon state={node.state} size={14} />
        <span style={{ fontWeight: 600, userSelect: "text" }}>{node.id}</span>
        <span className="muted mono" style={{ fontSize: 11 }}>{node.block}</span>
        <span className="spacer" />
        {node.log && runDir && <IconButton small icon={<FileSearch size={13} />} tip={t("Show the full log in Explorer")} onClick={() => void ipc.reveal(joinPath(runDir, node.log!))} />}
      </div>
      {failure ? (
        <div className="col" style={{ gap: 3, padding: 8, borderRadius: "var(--radius)", background: "color-mix(in srgb, var(--red) 9%, transparent)" }}>
          <span style={{ fontWeight: 500 }}>{str(failure.description)}</span>
          {str(failure.action) && <span className="muted" style={{ fontSize: 11.5 }}>{str(failure.action)}</span>}
          {str(failure.detail) && <span className="muted mono" style={{ fontSize: 11, whiteSpace: "pre-wrap", userSelect: "text" }}>{str(failure.detail)}</span>}
        </div>
      ) : (
        node.reason && <span className="muted" style={{ fontSize: 11.5 }}>{node.reason}</span>
      )}
      {failures.length > 0 && (
        <div className="col" style={{ gap: 4 }}>
          <span style={{ fontWeight: 600, fontSize: 12 }}>{t("Failed tests")}</span>
          {failures.map((f, i) => (
            <div key={i} className="col" style={{ gap: 1 }}>
              <span style={{ fontSize: 12 }}>{str(f.name)}</span>
              {str(f.file) && (
                <button className="link mono" style={{ fontSize: 11, alignSelf: "flex-start" }} data-tip={t("Show in Explorer")} onClick={() => void ipc.reveal(joinPath(repo, str(f.file)!))}>
                  {str(f.file)}
                  {typeof f.line === "number" ? `:${f.line}` : ""}
                </button>
              )}
              {str(f.message) && <span className="muted" style={{ fontSize: 11 }}>{str(f.message)}</span>}
            </div>
          ))}
        </div>
      )}
      {verdicts.length > 0 && (
        <div className="col" style={{ gap: 2 }}>
          <span style={{ fontWeight: 600, fontSize: 12 }}>{t("Verdicts")}</span>
          {verdicts.map((v, i) => (
            <div key={i} className="row" style={{ gap: 6, fontSize: 11.5 }}>
              <FlowStateIcon state={v.result === "PASS" ? "PASSED" : "FAILED"} size={11} />
              <span className="mono">{str(v.rule)}</span>
              <span style={{ flex: 1, minWidth: 0, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{str(v.title)}</span>
              <span className="muted">{str(v.observed)}</span>
            </div>
          ))}
        </div>
      )}
      <span style={{ fontWeight: 600, fontSize: 12 }}>{t("Output")}</span>
      <div ref={logRef} className="mono" style={{ flex: 1, minHeight: 0, overflow: "auto", fontSize: 11, padding: 6, whiteSpace: "pre", userSelect: "text", background: "var(--term-bg)", border: "1px solid var(--border)", borderRadius: "var(--radius)" }}>
        {node.tail.join("\n")}
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
