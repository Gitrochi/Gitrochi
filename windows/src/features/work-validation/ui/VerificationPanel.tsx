import { useEffect, useState } from "react";
import { flowEvidence, type FlowEvidence, useObserve } from "@/shared/lib";
import { worktreeStamp, describe } from "@/shared/platform";
import { flowStoreFor } from "@/entities/flow";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { Button, Spinner } from "@/shared/ui";

export function VerificationPanel({ store, onEvidence }: { store: RepoStore; onEvidence: (stamp: string, evidence: FlowEvidence[]) => void }) {
  const repo = store.path!;
  const flows = flowStoreFor(repo);
  useObserve(flows);
  useObserve(store);
  const [stamp, setStamp] = useState("");
  const [stampKey, setStampKey] = useState("");
  const [flow, setFlow] = useState("");
  const [working, setWorking] = useState(false);
  const [error, setError] = useState("");
  const impact = store.commitImpact?.kind === "done" ? store.commitImpact.result : null;
  const candidates = impact?.tests.map(test => test.path) ?? [];
  const contentKey = `${store.headHash}:${store.workContentRevision}`;
  const currentStamp = stampKey === contentKey ? stamp : "";
  const refresh = async () => {
    await flows.refresh();
    await Promise.all(flows.runs.slice(0, 12).map(row => flows.open(row.runId)));
    return (await worktreeStamp(repo)).stamp;
  };
  useEffect(() => {
    let active = true;
    let timer: ReturnType<typeof setTimeout>;
    const tick = async () => {
      try { const value = await refresh(); if (active) { setStamp(value); setStampKey(contentKey); setError(""); } }
      catch (error) { if (active) setError(describe(error)); }
      if (active) timer = setTimeout(() => void tick(), flows.runs.some(run => run.running) ? 3000 : 30000);
    };
    void tick();
    return () => { active = false; clearTimeout(timer); };
  }, [repo, flows, contentKey]);
  const evidence = flows.runs.slice(0, 12).flatMap(row => {
    const record = flows.records.get(row.runId);
    return record ? [flowEvidence(record, flows.validationBindings.find(binding => binding.runID === row.runId), currentStamp)] : [];
  });
  const evidenceKey = JSON.stringify(evidence);
  useEffect(() => { onEvidence(currentStamp, evidence); }, [currentStamp, evidenceKey]);
  const run = async () => {
    setWorking(true); setError("");
    try { await flows.startVerified(flow, candidates); setStamp(await refresh()); setStampKey(contentKey); }
    catch (error) { setError(describe(error)); }
    finally { setWorking(false); }
  };
  return <section className="validation-section" aria-label={t("Verification evidence")}>
    <h3>{t("Verification evidence")}</h3>
    <p className="hint">{t("Candidates are suggestions. Flow results report actual execution; they do not prove candidate coverage.")}</p>
    {candidates.length ? <details><summary>{t("Related test candidates")} ({candidates.length})</summary><ul>{candidates.map(path => <li key={path} className="mono">{path}</li>)}</ul></details> : <p className="hint">{t("Analyze staged files to find related test candidates.")}</p>}
    {store.commitImpactStale && <p role="status" className="hint">{t("The staged contents or HEAD changed. Analyze again before using this result.")}</p>}
    <p className="hint">{t("Verification runs the configured flow against the working tree, including unstaged edits.")}</p>
    <div className="row wrap">
      <label>{t("Flow")} <select className="select" value={flow} onChange={event => setFlow(event.target.value)} aria-label={t("Verification flow")}><option value="">{t("Choose a flow")}</option>{flows.list?.flows.map(item => <option key={item.name} value={item.name}>{item.name}</option>)}</select></label>
      <Button disabled={!flow || working || !flows.list?.trusted || store.commitImpactStale} onClick={() => void run()}>{t("Run verification flow")}</Button>
      <Button onClick={() => { store.navigate("flows"); store.sheet = null; store.changed(); }}>{t("Review flows")}</Button>
      <Button disabled={working} onClick={() => void refresh().then(value => { setStamp(value); setStampKey(contentKey); }).catch(error => setError(describe(error)))}>{t("Refresh")}</Button>
      {(working || flows.loading) && <Spinner size={14} />}
    </div>
    {!flows.hasFlowFile && <p className="hint">{t("Set up flows in the Flows workspace to connect your tests.")}</p>}
    {stamp.startsWith("untracked:") && <p className="hint">{t("Untracked file contents are not bound to verification. Add them to Git before relying on a current result.")}</p>}
    {stamp.startsWith("uncertified:") && <p className="hint">{t("Hidden tracked files or dirty submodules prevent content verification.")}</p>}
    <div className="validation-results" role="list" aria-live="polite">
      {evidence.map(item => <div role="listitem" key={item.runID}>
        <span className="mono">{item.runID}</span> · <strong>{item.state}</strong> · {t(item.freshness === "current" ? "Current content" : item.freshness === "stale" ? "Stale content" : item.freshness === "running" ? "Running" : "No content binding")}
        <div className="hint">{item.executed === null ? t("No test execution count was reported.") : t("Executed tests: {0}", item.executed)}{item.passed !== null && ` · ${t("Passed tests: {0}", item.passed)}`}{item.failed !== null && ` · ${t("Failed tests: {0}", item.failed)}`}</div>
      </div>)}
      {!evidence.length && <p className="hint">{t("No verification runs have been recorded.")}</p>}
    </div>
    {error && <div role="alert" className="error-text">{error}</div>}
  </section>;
}
