import { CircleCheck, Code2, Crosshair, Hand, RefreshCw, Shield, ShieldCheck, TriangleAlert, Wand2, Workflow } from "lucide-react";
import { type ReactNode, useEffect, useState } from "react";
import { type FlowPlan, type FlowPlanNode, type FlowStore, flowEngine, flowStoreFor, type FlowInitProposal, needsConfirmation } from "@/entities/flow";
import type { RepoStore } from "@/entities/repo";
import { ipc } from "@/shared/api";
import { joinPath, settings } from "@/shared/config";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, IconButton, Modal, showMenuBelow, Spinner } from "@/shared/ui";
import { FlowRunDialog } from "./FlowRunDialog";
import { FlowWorkspace } from "./FlowWorkspace";
import { FlowConfigDialog } from "./FlowConfigDialog";
import "./flow-workspace.css";

/**
 * The Flows workspace page: the flows (.gitch/flow.yml) that assemble this repository's tests, checks and deploy steps, and the recent runs (like the macOS FlowPanel.swift).
 * The flow engine (gitch-flow) runs, judges and rolls back; this screen sends the actions a person clicks and shows the results.
 */
export function FlowPanel({ store }: { store: RepoStore }) {
  useObserve(store);
  if (!store.path) {
    return <div className="side-scroll muted" style={{ padding: 20, textAlign: "center" }}>{t("Open a repository to use flows.")}</div>;
  }
  return <FlowPanelBody flows={flowStoreFor(store.path)} />;
}

type Dialog = { kind: "run"; runId: string } | { kind: "trust"; flow: string; plan: FlowPlan; thenRun: boolean } | { kind: "confirm"; flow: string; plan: FlowPlan } | { kind: "setup" } | { kind: "config" } | { kind: "error"; message: string };

function FlowPanelBody({ flows }: { flows: FlowStore }) {
  useObserve(flows);
  useObserve(settings);
  const [dialog, setDialog] = useState<Dialog | null>(null);
  const [starting, setStarting] = useState<string | null>(null);
  const affected = settings.get<boolean>("flowAffectedOnly", false);

  // Reads once, then again every 3 seconds while a run is going and every 30 seconds otherwise (so runs started elsewhere and file changes show up)
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

  /** Before a run: read the plan to see whether trust or confirmation is needed. */
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
        <IconButton small icon={<Code2 size={13} />} tip={t("Configure scripts")} disabled={!flows.engine} onClick={() => setDialog({ kind: "config" })} />
        <IconButton small icon={<Wand2 size={13} />} tip={t("Detect tests and propose a flow file")} disabled={!flows.engine} onClick={() => setDialog({ kind: "setup" })} />
      </div>
      <div className="col" style={{ flex: 1, minHeight: 0, overflow: "auto" }}>
        {flows.engine === null ? (
          <EmptyNote icon={<TriangleAlert size={26} />} text={t("The flow engine (gitch-flow) isn't in this Gitrochi. Update Gitrochi to run flows.")} />
        ) : !flows.hasFlowFile ? (
          <div className="col" style={{ alignItems: "center", gap: 10, padding: 20, textAlign: "center" }}>
            <Workflow size={28} style={{ opacity: 0.35 }} />
            <span className="muted">{t("Connect this repository's tests, checks and CI into flows you can run here, from gitch, before a push or in CI.")}</span>
            <div className="row" style={{ gap: 8 }}><Button onClick={() => setDialog({ kind: "setup" })}>{t("Set up flows…")}</Button><Button onClick={() => setDialog({ kind: "config" })}>{t("Configure scripts")}</Button></div>
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
              <button className="link" onClick={() => setDialog({ kind: "config" })}>{t("Configure scripts")}</button>
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
            <FlowWorkspace flows={flows} affected={affected} busy={starting} onRun={(flow) => void prepare(flow)} onOpen={(id) => setDialog({ kind: "run", runId: id })} onEdit={() => setDialog({ kind: "config" })} onReview={(flow) => void flowEngine.plan(flow, flows.repo, affected).then((plan) => setDialog({ kind: "trust", flow, plan, thenRun: false }), fail)} />
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
      {dialog?.kind === "config" && <FlowConfigDialog flows={flows} onClose={() => setDialog(null)} />}
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


/** Trusting a flow file: it is code, so it runs unattended only after a person has seen what will run and approved it. */
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

/** Creating a flow file: the engine reads only the repository's files to find tests and tools and proposes one (nothing runs). */
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
