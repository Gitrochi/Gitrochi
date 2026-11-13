import { TriangleAlert } from "lucide-react";
import { CircleCheck, CircleX, designIcon } from "@/shared/icons";
import { useEffect, useState } from "react";
import { type FlowItem, type FlowPlan, type FlowPlanNode, type FlowStore, flowEngine, flowStoreFor, type FlowInitProposal, type FlowImportSource, needsConfirmation, readFlowImport, readWebFlowImport } from "@/entities/flow";
import type { RepoStore } from "@/entities/repo";
import { ipc } from "@/shared/api";
import { settings } from "@/shared/config";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, type MenuItem, Modal, NoticeBlock, SharedSheet, Spinner } from "@/shared/ui";
import { FlowRunDialog } from "./FlowRunDialog";
import { FlowWorkspace } from "./FlowWorkspace";
import { FlowConfigDialog } from "./FlowConfigDialog";
import { FlowConnectedCI } from "./FlowConnectedCI";
import { FlowCreateDialog } from "./FlowCreateDialog";
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
  return <FlowPanelBody flows={flowStoreFor(store.path)} repo={store} />;
}

type Dialog = { kind: "run"; runId: string } | { kind: "trust"; flow: string; plan: FlowPlan; thenRun: boolean } | { kind: "confirm"; flow: string; plan: FlowPlan } | { kind: "setup" } | { kind: "create" } | { kind: "config"; source?: FlowImportSource; flow?: string; node?: string } | { kind: "error"; message: string };

function FlowPanelBody({ flows, repo }: { flows: FlowStore; repo: RepoStore }) {
  useObserve(flows);
  useObserve(settings);
  const [dialog, setDialog] = useState<Dialog | null>(null);
  const [starting, setStarting] = useState<string | null>(null);
  const [requestedFlow, setRequestedFlow] = useState<string>();
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
  useEffect(() => {
    if (dialog?.kind === "config" || dialog?.kind === "create") return;
    let disposed = false;
    let unlisten: (() => void) | undefined;
    void ipc.onFileDrop((paths) => {
      if (disposed) return;
      if (paths.length !== 1) { fail(new Error(t("Drop one workflow file at a time."))); return; }
      void readFlowImport(paths[0]).then((source) => { if (!disposed) setDialog({ kind: "config", source }); }).catch(fail);
    }).then((stop) => { if (disposed) stop(); else unlisten = stop; }).catch(() => {});
    return () => { disposed = true; unlisten?.(); };
  }, [flows.repo, dialog?.kind]);


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
  /** Everything about a flow that is not Edit or Run, each with its name: what used to be five unlabeled icons. */
  const moreActions = (flow: FlowItem): MenuItem[] => {
    const names = list?.flows.map((item) => item.name) ?? [];
    const gateFlow = flows.gate?.flow ?? (names.includes("pre-push") ? "pre-push" : flow.name);
    return [
      { label: t("Review commands…"), onClick: () => void flowEngine.plan(flow.name, flows.repo, affected).then((plan) => setDialog({ kind: "trust", flow: flow.name, plan, thenRun: false }), fail) },
      "divider",
      { label: t("Check a flow before every push"), checked: gateOn, tip: gateOn ? t("Pushes check a flow first") : t("Pushes don't check a flow"), onClick: () => void flows.setGate(!gateOn, gateFlow).catch(fail) },
      ...(gateOn ? names.map((name) => ({ label: name, checked: flows.gate?.flow === name, onClick: () => void flows.setGate(true, name).catch(fail) })) : []),
      { label: t("Run only affected tests"), checked: affected, tip: t("Run only tests affected by your changes"), onClick: () => settings.set("flowAffectedOnly", !affected) },
      "divider",
      { label: t("Set up flows…"), tip: t("Detect tests and propose a flow file"), disabled: !flows.engine, onClick: () => setDialog({ kind: "setup" }) },
      { label: t("Refresh"), onClick: () => void flows.refresh() },
    ];
  };
  return (
    <div className="col flow-drop-surface" style={{ flex: 1, minHeight: 0 }} onDragOver={(event) => { if (event.dataTransfer.types.includes("Files")) event.preventDefault(); }} onDrop={(event) => {
      event.preventDefault();
      if (dialog?.kind === "create") return;
      if (event.dataTransfer.files.length !== 1) { fail(new Error(t("Drop one workflow file at a time."))); return; }
      const dropped = event.dataTransfer.files[0];
      if (dropped.size > 2 * 1024 * 1024) { fail(new Error(t("Choose a UTF-8 workflow file smaller than 2 MB."))); return; }
      void readWebFlowImport(dropped).then((source) => setDialog({ kind: "config", source })).catch(fail);
    }}>
      <FlowWorkspace flows={flows} affected={affected} busy={starting} requestedFlow={requestedFlow}
        onCreate={flows.engine ? () => setDialog({ kind: "create" }) : undefined}
        onRun={(flow) => void prepare(flow)}
        onStop={(runId) => void flows.cancel(runId).catch(fail)}
        onOpen={(id) => setDialog({ kind: "run", runId: id })}
        onEdit={(flow, node) => setDialog({ kind: "config", flow, node })}
        onReview={(flow) => void flowEngine.plan(flow, flows.repo, affected).then((plan) => setDialog({ kind: "trust", flow, plan, thenRun: false }), fail)}
        moreActions={moreActions}
        connectedCI={<FlowConnectedCI store={repo} />}
        emptyState={<FlowEmptyContent flows={flows} onCreate={() => setDialog({ kind: "create" })} onSetup={() => setDialog({ kind: "setup" })} onEdit={() => setDialog({ kind: "config" })} />} />
      {dialog?.kind === "create" && <FlowCreateDialog flows={flows} onClose={() => setDialog(null)} onCreated={(name) => { setRequestedFlow(name); setDialog(null); }} />}
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
      {dialog?.kind === "config" && <FlowConfigDialog flows={flows} initialImport={dialog.source} initialFlow={dialog.flow} initialNode={dialog.node} onClose={() => setDialog(null)} />}
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

const FlowsIcon = designIcon("flows");

/** Why there is no flow to show, each in the shared empty form: an icon, one line, one caption and the next action. */
function FlowEmptyContent({ flows, onCreate, onSetup, onEdit }: { flows: FlowStore; onCreate: () => void; onSetup: () => void; onEdit: () => void }) {
  if (flows.engine === null) {
    return <div className="flow-empty"><TriangleAlert size={24} /><strong>{t("The flow engine (gitch-flow) isn't in this Gitrochi. Update Gitrochi to run flows.")}</strong></div>;
  }
  if (flows.error) {
    return (
      <div className="flow-empty">
        <NoticeBlock tone="failed" alert icon={<CircleX size={14} />} title={flows.error.message} caption={flows.error.action}
          actions={[{ label: t("Edit flow file…"), onClick: onEdit }, { label: t("Try again"), onClick: () => void flows.refresh() }]} />
      </div>
    );
  }
  if (!flows.hasFlowFile || (flows.list && !flows.list.flows.length)) {
    return (
      <div className="flow-empty" data-flow-empty>
        <FlowsIcon size={24} />
        <strong>{t("No flows in this repository")}</strong>
        <span>{t("Describe your build and test steps once in .gitch/flow.yml, then run them here and in CI.")}</span>
        <div className="flow-empty-actions">
          <Button kind="primary" onClick={onSetup}>{t("Set up flows…")}</Button>
          <Button onClick={onCreate}>{t("New flow…")}</Button>
        </div>
      </div>
    );
  }
  return <div className="flow-empty"><Spinner /></div>;
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

/** Trusting a flow file: it is code, so it runs unattended only after a person has seen what will run and approved it. */
function FlowTrustDialog({ plan, action, onApprove, onClose }: { plan: FlowPlan; action: string; onApprove: () => void; onClose: () => void }) {
  return (
    <SharedSheet title={t("Review this flow")} context={plan.flow} width={680} onClose={onClose} primary={{ label: action, onClick: onApprove }}>
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
    </SharedSheet>
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
