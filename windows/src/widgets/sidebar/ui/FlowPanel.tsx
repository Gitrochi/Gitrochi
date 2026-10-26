import { Circle, CircleCheck, CircleSlash, CircleX, Crosshair, FileSearch, Hand, MinusCircle, Play, RefreshCw, RotateCcw, Shield, ShieldCheck, TriangleAlert, Undo2, Wand2, Workflow } from "lucide-react";
import { type ReactNode, useEffect, useMemo, useRef, useState } from "react";
import { type FlowItem, type FlowPlan, type FlowPlanNode, type FlowRunRow, type FlowStore, flowEngine, flowStoreFor, formatDuration, type FlowInitProposal, isBadState, needsConfirmation, runCounts, type RunNode } from "@/entities/flow";
import type { RepoStore } from "@/entities/repo";
import { ipc } from "@/shared/api";
import { joinPath, settings } from "@/shared/config";
import { t } from "@/shared/i18n";
import { shortDate, useObserve } from "@/shared/lib";
import { Button, IconButton, Modal, showContextMenu, showMenuBelow, Spinner } from "@/shared/ui";

/**
 * 사이드바 '흐름' 탭: 이 저장소의 테스트 · 점검 · 배포 단계를 조립한 흐름(.gitch/flow.yml)과 최근 실행(맥 FlowPanel.swift 와 같다).
 * 실행 · 판정 · 되돌림은 흐름 엔진(gitch-flow)이 하고, 이 화면은 사람이 누른 동작을 보내고 결과를 보여 준다.
 */
export function FlowPanel({ store }: { store: RepoStore }) {
  useObserve(store);
  if (!store.path) {
    return <div className="side-scroll muted" style={{ padding: 20, textAlign: "center" }}>{t("Open a repository to use flows.")}</div>;
  }
  return <FlowPanelBody flows={flowStoreFor(store.path)} />;
}

type Dialog = { kind: "run"; runId: string } | { kind: "trust"; flow: string; plan: FlowPlan; thenRun: boolean } | { kind: "confirm"; flow: string; plan: FlowPlan } | { kind: "setup" } | { kind: "error"; message: string };

function FlowPanelBody({ flows }: { flows: FlowStore }) {
  useObserve(flows);
  useObserve(settings);
  const [dialog, setDialog] = useState<Dialog | null>(null);
  const [starting, setStarting] = useState<string | null>(null);
  const affected = settings.get<boolean>("flowAffectedOnly", false);

  // 처음 읽고, 도는 실행이 있으면 3초 · 없으면 30초마다 다시(다른 곳에서 돌린 실행 · 파일 변경도 보이게)
  useEffect(() => {
    let stop = false;
    let timer: ReturnType<typeof setTimeout> | null = null;
    const tick = async () => {
      if (stop) return;
      await flows.refresh();
      if (stop) return;
      timer = setTimeout(() => void tick(), flows.runs.some((r) => r.running) ? 3000 : 30000);
    };
    void tick();
    return () => {
      stop = true;
      if (timer) clearTimeout(timer);
    };
  }, [flows]);

  const fail = (e: unknown) => setDialog({ kind: "error", message: e instanceof Error ? e.message : String(e) });

  /** 실행 전: 계획을 읽어 신뢰 · 확인이 필요한지 본다. */
  const prepare = async (flow: string) => {
    setStarting(flow);
    try {
      const plan = await flowEngine.plan(flow, flows.repo, affected);
      if (!plan.trust.trusted) setDialog({ kind: "trust", flow, plan, thenRun: true });
      else if (needsConfirmation(plan)) setDialog({ kind: "confirm", flow, plan });
      else await launch(flow, false);
    } catch (e) {
      fail(e);
    } finally {
      setStarting(null);
    }
  };

  const launch = async (flow: string, yes: boolean) => {
    setStarting(flow);
    try {
      const id = await flows.start(flow, affected, yes);
      setDialog({ kind: "run", runId: id });
    } catch (e) {
      fail(e);
    } finally {
      setStarting(null);
    }
  };

  const list = flows.list;
  const gateOn = !!flows.gate && flows.gate.gate !== "OFF";
  return (
    <div className="col" style={{ flex: 1, minHeight: 0 }}>
      <div className="row" style={{ padding: "4px 12px 6px", gap: 4, borderBottom: "1px solid var(--border)" }}>
        <span style={{ fontWeight: 600 }}>{t("Flows")}</span>
        {flows.loading && <Spinner size={11} />}
        <span className="spacer" />
        {list && list.flows.length > 0 && (
          <IconButton
            small
            className={gateOn ? "on" : ""}
            icon={gateOn ? <ShieldCheck size={13} /> : <Shield size={13} />}
            tip={gateOn ? t("Pushes check a flow first") : t("Pushes don't check a flow")}
            aria-label={t("Pre-push check")}
            onClick={(e) => {
              const fallback = (list.flows.find((f) => f.name === "pre-push") ?? list.flows[0]).name;
              showMenuBelow(e.currentTarget, [
                {
                  label: t("Check a flow before every push"),
                  checked: gateOn,
                  onClick: () => void flows.setGate(!gateOn, flows.gate?.flow ?? fallback).catch(fail),
                },
                ...(gateOn
                  ? list.flows.map((f) => ({ label: f.name, checked: flows.gate?.flow === f.name, onClick: () => void flows.setGate(true, f.name).catch(fail) }))
                  : []),
              ]);
            }}
          />
        )}
        <IconButton
          small
          className={affected ? "on" : ""}
          icon={<Crosshair size={13} />}
          tip={affected ? t("Running only tests affected by your changes") : t("Run only tests affected by your changes")}
          aria-label={t("Run only affected tests")}
          onClick={() => settings.set("flowAffectedOnly", !affected)}
        />
        <IconButton small icon={<RefreshCw size={12} />} tip={t("Refresh")} onClick={() => void flows.refresh()} />
        <IconButton small icon={<Wand2 size={13} />} tip={t("Detect tests and propose a flow file")} disabled={!flows.engine} onClick={() => setDialog({ kind: "setup" })} />
      </div>
      <div className="side-scroll">
        {flows.engine === null ? (
          <EmptyNote icon={<TriangleAlert size={26} />} text={t("The flow engine (gitch-flow) isn't in this Gitrochi. Update Gitrochi to run flows.")} />
        ) : !flows.hasFlowFile ? (
          <div className="col" style={{ alignItems: "center", gap: 10, padding: 20, textAlign: "center" }}>
            <Workflow size={28} style={{ opacity: 0.35 }} />
            <span className="muted">{t("Connect this repository's tests, checks and CI into flows you can run here, from gitch, before a push or in CI.")}</span>
            <Button onClick={() => setDialog({ kind: "setup" })}>{t("Set up flows…")}</Button>
          </div>
        ) : flows.error ? (
          <div className="col" style={{ gap: 6, padding: 8, alignItems: "flex-start" }}>
            {flows.error.code && <span className="mono muted" style={{ fontSize: 11 }}>{flows.error.code}</span>}
            <span className="error-text" style={{ fontSize: 11.5, whiteSpace: "pre-wrap", userSelect: "text" }}>
              {flows.error.message}
            </span>
            {flows.error.action && <span className="muted" style={{ fontSize: 11.5 }}>{flows.error.action}</span>}
            <div className="row" style={{ gap: 10 }}>
              <button className="link" onClick={() => void ipc.reveal(joinPath(flows.repo, ".gitch/flow.yml"))}>
                {t("Show in Explorer")}
              </button>
              <button className="link" onClick={() => void flows.refresh()}>
                {t("Try again")}
              </button>
            </div>
          </div>
        ) : list ? (
          <>
            {!list.trusted && (
              <div className="row" style={{ gap: 6, padding: "6px 10px", color: "var(--orange)", fontSize: 11.5 }}>
                <Hand size={13} style={{ flex: "none" }} />
                <span>{t("This flow file is new or changed. Review the commands before running it.")}</span>
              </div>
            )}
            <div className="muted" style={{ padding: "6px 12px 2px", fontSize: 11, fontWeight: 600 }}>
              {t("Flows")}
            </div>
            {list.flows.map((f) => (
              <FlowRow key={f.name} f={f} busy={starting === f.name} onRun={() => void prepare(f.name)} onShow={(id) => setDialog({ kind: "run", runId: id })} onReview={() => void flowEngine.plan(f.name, flows.repo).then((plan) => setDialog({ kind: "trust", flow: f.name, plan, thenRun: false }), fail)} />
            ))}
            {flows.runs.length > 0 && (
              <>
                <div className="muted" style={{ padding: "10px 12px 2px", fontSize: 11, fontWeight: 600 }}>
                  {t("Recent runs")}
                </div>
                {flows.runs.slice(0, 30).map((r) => (
                  <RunRow key={r.runId} r={r} onOpen={() => setDialog({ kind: "run", runId: r.runId })} />
                ))}
              </>
            )}
          </>
        ) : (
          <div className="row" style={{ justifyContent: "center", padding: 20 }}>
            <Spinner />
          </div>
        )}
      </div>
      {dialog?.kind === "run" && <FlowRunDialog flows={flows} runId={dialog.runId} onClose={() => setDialog(null)} />}
      {dialog?.kind === "trust" && (
        <FlowTrustDialog
          plan={dialog.plan}
          action={dialog.thenRun ? t("Trust and run") : t("Trust")}
          onClose={() => setDialog(null)}
          onApprove={() => {
            const d = dialog;
            setDialog(null);
            void flows
              .trust()
              .then(() => (d.thenRun ? prepare(d.flow) : undefined))
              .catch(fail);
          }}
        />
      )}
      {dialog?.kind === "confirm" && (
        <Modal
          title={t("Run this flow?")}
          width={480}
          onClose={() => setDialog(null)}
          footer={
            <>
              <Button onClick={() => setDialog(null)}>{t("Cancel")}</Button>
              <Button
                kind="primary"
                onClick={() => {
                  const f = dialog.flow;
                  setDialog(null);
                  void launch(f, true);
                }}
              >
                {t("Run")}
              </Button>
            </>
          }
        >
          <div style={{ whiteSpace: "pre-line", lineHeight: 1.5 }}>{confirmText(dialog.plan)}</div>
        </Modal>
      )}
      {dialog?.kind === "setup" && <FlowSetupDialog flows={flows} onClose={() => setDialog(null)} />}
      {dialog?.kind === "error" && (
        <Modal title={t("Couldn't run the flow")} width={480} onClose={() => setDialog(null)} footer={<Button onClick={() => setDialog(null)}>{t("OK")}</Button>}>
          <div className="error-text" style={{ whiteSpace: "pre-wrap", userSelect: "text" }}>
            {dialog.message}
          </div>
        </Modal>
      )}
    </div>
  );
}

function confirmText(p: FlowPlan) {
  const parts: string[] = [];
  if (p.outward.length) parts.push(t("It acts outside this computer: {0}.", p.outward.join(", ")));
  const destructive = p.nodes.filter((n) => n.destructive && n.decision === "run").map((n) => n.id);
  if (destructive.length) parts.push(t("Hard to undo: {0}.", destructive.join(", ")));
  if (p.gates.length) parts.push(t("Running it approves its manual steps: {0}.", p.gates.join(", ")));
  parts.push(t("Environment: {0}", p.env));
  return parts.join("\n");
}

function EmptyNote({ icon, text }: { icon: ReactNode; text: string }) {
  return (
    <div className="col" style={{ alignItems: "center", gap: 8, padding: 20, textAlign: "center" }}>
      <span style={{ opacity: 0.35 }}>{icon}</span>
      <span className="muted">{text}</span>
    </div>
  );
}

function FlowRow({ f, busy, onRun, onShow, onReview }: { f: FlowItem; busy: boolean; onRun: () => void; onShow: (runId: string) => void; onReview: () => void }) {
  return (
    <div
      className="side-row"
      style={{ gap: 6, height: "auto", padding: "4px 10px" }}
      onDoubleClick={onRun}
      onContextMenu={(e) =>
        showContextMenu(e, [
          { label: t("Run"), onClick: onRun },
          ...(f.last ? [{ label: t("Show last run"), onClick: () => onShow(f.last!.runId) }] : []),
          { label: t("Review commands…"), onClick: onReview },
        ])
      }
    >
      <FlowStateIcon state={f.last?.state ?? null} />
      <div className="col" style={{ minWidth: 0, flex: 1, gap: 1 }}>
        <span style={{ overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{f.name}</span>
        <span className="muted" style={{ fontSize: 11, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
          {[f.description, t("{0} steps", f.nodes)].filter(Boolean).join(" · ")}
        </span>
      </div>
      {busy ? <Spinner size={12} /> : <IconButton small icon={<Play size={12} />} tip={t("Run {0}", f.name)} aria-label={t("Run {0}", f.name)} onClick={onRun} />}
    </div>
  );
}

function RunRow({ r, onOpen }: { r: FlowRunRow; onOpen: () => void }) {
  return (
    <div className="side-row" style={{ gap: 6, height: "auto", padding: "4px 10px" }} onClick={onOpen}>
      <FlowStateIcon state={r.running ? "RUNNING" : r.state} />
      <div className="col" style={{ minWidth: 0, flex: 1, gap: 1 }}>
        <span style={{ overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{r.flow}</span>
        <span className="muted" style={{ fontSize: 11 }}>
          {[r.startedAt ? shortDate(Date.parse(r.startedAt) / 1000) : null, !r.running && r.durationMs != null ? formatDuration(r.durationMs) : null, !r.running ? r.code : null].filter(Boolean).join(" · ")}
        </span>
      </div>
      {r.signed === false && !r.running && (
        <span data-tip={t("This record isn't signed by the engine, so gates don't trust it")} style={{ color: "var(--orange)", display: "inline-flex" }}>
          <TriangleAlert size={12} />
        </span>
      )}
    </div>
  );
}

export function stateTitle(s: string | null | undefined): string {
  switch (s) {
    case "SUCCEEDED":
      return t("Succeeded");
    case "PASSED":
      return t("Passed");
    case "CACHED":
      return t("Passed before with the same inputs");
    case "FAILED":
      return t("Failed");
    case "INDETERMINATE":
      return t("Couldn't judge (counts as a failure)");
    case "REJECTED":
      return t("Rejected before running");
    case "ROLLING_BACK":
      return t("Rolling back");
    case "ROLLED_BACK":
      return t("Failed and rolled back");
    case "ROLLBACK_FAILED":
      return t("Rollback failed — environment on hold");
    case "CANCELLED":
      return t("Canceled");
    case "RUNNING":
    case "PREFLIGHT":
      return t("Running");
    case "SKIPPED":
      return t("Skipped");
    case "PENDING":
      return t("Waiting");
    default:
      return t("Not run yet");
  }
}

/** 실행 · 노드 상태 아이콘(도는 중이면 도는 표시) */
export function FlowStateIcon({ state, size = 14 }: { state: string | null; size?: number }) {
  const title = stateTitle(state);
  if (state === "RUNNING" || state === "PREFLIGHT") {
    return (
      <span data-tip={title} aria-label={title} style={{ display: "inline-flex", width: size, justifyContent: "center", flex: "none" }}>
        <Spinner size={size - 2} />
      </span>
    );
  }
  let icon: ReactNode = <Circle size={size} />;
  let color = "var(--text-3)";
  if (state === "SUCCEEDED" || state === "PASSED" || state === "CACHED") {
    icon = <CircleCheck size={size} />;
    color = "var(--green)";
  } else if (state === "FAILED" || state === "INDETERMINATE" || state === "ROLLBACK_FAILED") {
    icon = <CircleX size={size} />;
    color = "var(--red)";
  } else if (state === "ROLLED_BACK" || state === "ROLLING_BACK") {
    icon = <RotateCcw size={size} />;
    color = "var(--orange)";
  } else if (state === "REJECTED") {
    icon = <CircleSlash size={size} />;
    color = "var(--orange)";
  } else if (state === "SKIPPED" || state === "CANCELLED") {
    icon = <MinusCircle size={size} />;
  }
  return (
    <span data-tip={title} aria-label={title} style={{ color, display: "inline-flex", flex: "none" }}>
      {icon}
    </span>
  );
}

type Json = Record<string, unknown>;
const arr = (v: unknown) => (Array.isArray(v) ? (v as Json[]) : []);
const str = (v: unknown) => (typeof v === "string" ? v : null);

/** 실행 하나: 노드 상태(실시간) · 고른 노드의 로그 끝 · 실패 위치 · 되돌림. 판정은 엔진이 한 그대로 보여 준다. */
function FlowRunDialog({ flows, runId, onClose }: { flows: FlowStore; runId: string; onClose: () => void }) {
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
  // 따로 고르지 않았으면 지금 도는(없으면 처음 실패한) 노드
  const shown = useMemo(() => {
    const pick = nodes.find((n) => n.id === selected);
    if (pick && !(pick.state === "PASSED" && !selected)) return pick;
    return nodes.find((n) => n.state === "RUNNING") ?? nodes.find((n) => isBadState(n.state)) ?? pick ?? null;
  }, [nodes, selected, view?.lastSeq]);
  const state = view?.state ?? str(record?.state);
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
      <div className="row" style={{ alignItems: "stretch", gap: 12, height: 480 }}>
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

/** 흐름 파일 신뢰: 흐름 파일은 코드라서 사람이 무엇이 돌지 보고 승인해야 비대화형으로 돈다. */
function FlowTrustDialog({ plan, action, onApprove, onClose }: { plan: FlowPlan; action: string; onApprove: () => void; onClose: () => void }) {
  return (
    <Modal
      title={t("Review this flow")}
      width={680}
      onClose={onClose}
      footer={
        <>
          <Button onClick={onClose}>{t("Cancel")}</Button>
          <Button kind="primary" onClick={onApprove}>
            {action}
          </Button>
        </>
      }
    >
      <div className="col" style={{ gap: 10 }}>
        <span className="muted">{t("A flow file is code. Approve it only if you would run these commands yourself — changing the file asks again.")}</span>
        {!!plan.trust.changed?.length && (
          <div className="row" style={{ gap: 6 }}>
            <span className="muted">{t("New or changed")}</span>
            <span className="mono">{plan.trust.changed.join(", ")}</span>
          </div>
        )}
        <div className="col" style={{ gap: 10, maxHeight: 380, overflow: "auto" }}>
          {plan.nodes
            .filter((n) => n.decision === "run")
            .map((n) => (
              <TrustNode key={n.id} n={n} />
            ))}
        </div>
        {plan.outward.length > 0 && <span style={{ color: "var(--orange)" }}>{t("Acts outside this computer: {0}", plan.outward.join(", "))}</span>}
        {plan.services.length > 0 && <span className="muted">{t("Starts services: {0}", plan.services.join(", "))}</span>}
        {plan.warnings.map((w) => (
          <span key={w} style={{ color: "var(--orange)", fontSize: 11.5 }}>
            {w}
          </span>
        ))}
      </div>
    </Modal>
  );
}

function TrustNode({ n }: { n: FlowPlanNode }) {
  const tag = (text: string, color: string) => (
    <span style={{ fontSize: 10.5, fontWeight: 600, color, border: `1px solid ${color}`, borderRadius: 8, padding: "0 5px" }}>{text}</span>
  );
  return (
    <div className="col" style={{ gap: 4 }}>
      <div className="row" style={{ gap: 6 }}>
        <span style={{ fontWeight: 600 }}>{n.id}</span>
        <span className="muted mono" style={{ fontSize: 11 }}>{n.block}</span>
        {n.executor && n.executor !== "local" && <span className="mono" style={{ fontSize: 11, color: "var(--accent)" }}>{n.executor}</span>}
        {n.outward && tag(t("outward"), "var(--orange)")}
        {n.destructive && tag(t("hard to undo"), "var(--red)")}
        <span className="spacer" />
        {n.src && <span className="muted mono" style={{ fontSize: 10.5 }}>{n.src}</span>}
      </div>
      {n.run && <pre className="mono" style={{ margin: 0, fontSize: 11, padding: 6, whiteSpace: "pre-wrap", userSelect: "text", background: "var(--term-bg)", border: "1px solid var(--border)", borderRadius: "var(--radius)" }}>{n.run}</pre>}
      {n.undo && <span className="muted mono" style={{ fontSize: 11 }}>{t("Undo: {0}", n.undo)}</span>}
    </div>
  );
}

/** 흐름 파일 만들기: 엔진이 저장소 파일만 읽어 테스트 · 도구를 찾아 제안한다(아무것도 돌리지 않는다). */
function FlowSetupDialog({ flows, onClose }: { flows: FlowStore; onClose: () => void }) {
  const [proposal, setProposal] = useState<FlowInitProposal | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [writing, setWriting] = useState(false);
  useEffect(() => {
    flowEngine.proposeInit(flows.repo).then(setProposal, (e) => setError(e instanceof Error ? e.message : String(e)));
  }, [flows]);
  const write = async () => {
    setWriting(true);
    try {
      await flowEngine.writeInit(flows.repo);
      await flows.refresh();
      onClose();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setWriting(false);
    }
  };
  return (
    <Modal
      title={t("Set up flows")}
      width={700}
      onClose={onClose}
      footer={
        <>
          {writing && <Spinner size={12} />}
          <span className="spacer" />
          <Button onClick={onClose}>{t("Cancel")}</Button>
          <Button kind="primary" disabled={!proposal || proposal.exists || writing} onClick={() => void write()}>
            {t("Create flow file")}
          </Button>
        </>
      }
    >
      <div className="col" style={{ gap: 10 }}>
        <span className="muted">{t("Gitrochi read this repository's files to find its tests and tools. Nothing runs, and nothing is written until you create the file.")}</span>
        {proposal ? (
          <>
            {proposal.findings.map((f) => (
              <div key={f.kind + f.evidence} className="row" style={{ gap: 6 }}>
                <CircleCheck size={13} color="var(--green)" />
                <span style={{ fontWeight: 500 }}>{f.kind}</span>
                <span className="muted mono" style={{ fontSize: 11 }}>{f.evidence}</span>
                {f.note && <span className="muted" style={{ fontSize: 11 }}>{f.note}</span>}
              </div>
            ))}
            <span style={{ fontWeight: 600 }}>{t("Proposed .gitch/flow.yml")}</span>
            <pre className="mono" style={{ margin: 0, fontSize: 11, padding: 8, height: 300, overflow: "auto", userSelect: "text", background: "var(--term-bg)", border: "1px solid var(--border)", borderRadius: "var(--radius)" }}>{proposal.yaml}</pre>
            {proposal.exists && <span style={{ color: "var(--orange)" }}>{t("A flow file already exists, so nothing will be written. Merge the proposal by hand.")}</span>}
          </>
        ) : error ? (
          <span className="error-text" style={{ whiteSpace: "pre-wrap", userSelect: "text" }}>
            {error}
          </span>
        ) : (
          <div className="row" style={{ justifyContent: "center", padding: 30 }}>
            <Spinner />
          </div>
        )}
      </div>
    </Modal>
  );
}
