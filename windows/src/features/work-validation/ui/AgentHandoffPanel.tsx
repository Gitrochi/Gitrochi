import { useState } from "react";
import { agents, agentStatusTitle } from "@/entities/agent";
import { statusFiles } from "@/entities/git";
import type { RepoStore } from "@/entities/repo";
import { env, settings, samePath } from "@/shared/config";
import { decodeAgentAssignments, handoffReport, safeWorkPath, taskBoundaryOverlaps, useObserve, type FlowEvidence } from "@/shared/lib";
import { t } from "@/shared/i18n";
import { Button } from "@/shared/ui";

export function AgentHandoffPanel({ store, stamp, evidence }: { store: RepoStore; stamp: string; evidence: FlowEvidence[] }) {
  useObserve(agents);
  const key = "agentAssignments:" + store.path;
  const [assignments, setAssignments] = useState(() => decodeAgentAssignments(settings.get(key, [])));
  const [report, setReport] = useState("");
  const [drafts, setDrafts] = useState<Record<string, string>>({});
  const invalidPaths = Object.values(drafts).some(text => !text.split("\n").map(path => path.trim()).filter(Boolean).every(safeWorkPath));
  const sessions = agents.sessions.filter(session => samePath(session.path, store.path) || store.worktrees.some(tree => samePath(tree.path, session.path)));
  const save = (sessionID: string, patch: Partial<typeof assignments[number]>) => {
    const prior = assignments.find(item => item.sessionID === sessionID) ?? { sessionID, taskID: "", goal: "", paths: [], remaining: "" };
    const next = [...assignments.filter(item => item.sessionID !== sessionID), { ...prior, ...patch }];
    setAssignments(next); settings.set(key, next); setReport("");
  };
  const overlaps = taskBoundaryOverlaps(assignments.filter(item => sessions.some(session => session.id === item.sessionID && session.status !== "ended")));
  return <section className="validation-section" aria-label={t("Agent handoff")}>
    <h3>{t("Agent handoff")}</h3>
    <p className="hint">{t("Declare task boundaries explicitly. Shared paths do not prove which agent edited a file.")}</p>
    {sessions.map(session => {
      const assignment = assignments.find(item => item.sessionID === session.id);
      return <details key={session.id}><summary>{session.kind} · {agentStatusTitle[session.status]} · {assignment?.taskID || session.id}</summary>
        <p className="hint">{t("Observed at {0}", new Date(session.updated * 1000).toISOString())}</p>
        <div className="validation-fields"><label>{t("Task ID")}<input className="input" value={assignment?.taskID ?? ""} maxLength={200} onChange={event => save(session.id, { taskID: event.target.value })} /></label><label>{t("Task goal")}<input className="input" value={assignment?.goal ?? ""} maxLength={2000} onChange={event => save(session.id, { goal: event.target.value })} /></label></div>
        <label>{t("Task boundaries · relative paths, one per line")}<textarea className="textarea" rows={3} value={drafts[session.id] ?? assignment?.paths.join("\n") ?? ""} onChange={event => { const text = event.target.value; setDrafts(values => ({ ...values, [session.id]: text })); setReport(""); const paths = text.split("\n").map(path => path.trim()).filter(Boolean); if (paths.every(safeWorkPath)) save(session.id, { paths }); }} /></label>
        <label>{t("Remaining work")}<textarea className="textarea" rows={2} value={assignment?.remaining ?? ""} maxLength={4000} onChange={event => save(session.id, { remaining: event.target.value })} /></label>
      </details>;
    })}
    {!sessions.length && <p className="hint">{t("No tracked agent sessions are available for this repository.")}</p>}
    {overlaps.length > 0 && <div role="status"><strong>{t("Overlapping task boundaries")}</strong>{overlaps.map(overlap => <p className="mono" key={overlap.a + overlap.b}>{overlap.a} ↔ {overlap.b}: {overlap.paths.join(", ")}</p>)}</div>}
    {invalidPaths && <p role="alert" className="error-text">{t("Use repository-relative paths without parent traversal.")}</p>}
    <Button disabled={!stamp || invalidPaths} onClick={() => setReport(handoffReport({ head: store.headHash, stamp, appVersion: env.version, changedPaths: statusFiles(store.status).map(file => file.path), candidates: store.commitImpact?.kind === "done" ? store.commitImpact.result.tests.map(test => test.path) : [], evidence, assignments, sessions: sessions.map(session => ({ taskID: assignments.find(item => item.sessionID === session.id)?.taskID ?? "", kind: session.kind, state: session.status, branch: store.worktrees.find(tree => samePath(tree.path, session.path))?.branch ?? store.headBranch, observedAt: new Date(session.updated * 1000).toISOString() })), observedAt: new Date().toISOString() }))}>{t("Create handoff report")}</Button>
    {report && <><p className="hint">{t("Review task text before sharing this report.")}</p><textarea className="textarea mono" rows={12} readOnly value={report} aria-label={t("Handoff report")} onFocus={event => event.target.select()} /></>}
  </section>;
}
