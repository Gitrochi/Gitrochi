import { useCallback, useState } from "react";
import type { RepoStore } from "@/entities/repo";
import { type FlowEvidence } from "@/shared/lib";
import { t } from "@/shared/i18n";
import { Button, Modal } from "@/shared/ui";
import { VerificationPanel } from "./VerificationPanel";
import { TeamHubPanel } from "./TeamHubPanel";
import { AgentHandoffPanel } from "./AgentHandoffPanel";
import "./work-validation.css";

/** Connect observed changes, execution evidence and deliberate team handoffs. */
export function WorkValidationSheet({ store, close }: { store: RepoStore; close: () => void }) {
  return store.path ? <WorkValidationBody key={store.path} store={store} close={close} /> : null;
}

function WorkValidationBody({ store, close }: { store: RepoStore; close: () => void }) {
  const [tab, setTab] = useState("verification");
  const [result, setResult] = useState<{ stamp: string; evidence: FlowEvidence[] }>({ stamp: "", evidence: [] });
  const onEvidence = useCallback((stamp: string, evidence: FlowEvidence[]) => setResult({ stamp, evidence }), []);
  if (!store.path) return null;
  return <Modal title={t("Work validation")} width={900} onClose={close} footer={<Button onClick={close}>{t("Close")}</Button>}>
    <div className="work-validation" key={store.path}>
      <div role="tablist" aria-label={t("Work validation")} className="row wrap">{[["verification", "Verification evidence"], ["team", "Team overlap evidence"], ["agents", "Agent handoff"]].map(([id, label]) => <Button key={id} role="tab" id={`work-validation-${id}`} aria-selected={tab === id} aria-controls={`work-validation-panel-${id}`} onClick={() => setTab(id)}>{t(label)}</Button>)}</div>
      <div role="tabpanel" id="work-validation-panel-verification" aria-labelledby="work-validation-verification" hidden={tab !== "verification"}><VerificationPanel store={store} onEvidence={onEvidence} /></div>
      <div role="tabpanel" id="work-validation-panel-team" aria-labelledby="work-validation-team" hidden={tab !== "team"}><TeamHubPanel store={store} /></div>
      <div role="tabpanel" id="work-validation-panel-agents" aria-labelledby="work-validation-agents" hidden={tab !== "agents"}><AgentHandoffPanel store={store} stamp={result.stamp} evidence={result.evidence} /></div>
    </div>
  </Modal>;
}
