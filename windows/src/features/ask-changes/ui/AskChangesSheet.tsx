import { useEffect } from "react";
import { ai, changeQuestionContext, changeQuestionLimits } from "@/entities/ai";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, Modal, Spinner } from "@/shared/ui";

export function AskChangesSheet({ store, close }: { store: RepoStore; close: () => void }) {
  useObserve(store);
  useEffect(() => () => store.cancelChangeQuestion(), [store]);
  const session = store.changeQuestionSession;
  const finish = () => { store.cancelChangeQuestion(); close(); };
  const problem = session ? ai.problem(session.provider) : null;
  const snapshot = session?.snapshot;
  return <Modal title={t("Ask AI about changes")} width={800} onClose={finish} footer={<>
    <Button disabled={!session || session.loading || session.working} onClick={() => void store.openChangeQuestion(true)}>{t("New snapshot")}</Button>
    <span className="spacer" />
    {session?.working && <><Spinner size={13} /><Button onClick={() => store.stopChangeQuestion()}>{t("Stop waiting")}</Button></>}
    <Button onClick={finish}>{t("Close")}</Button>
    <Button kind="primary" disabled={!snapshot || session?.loading || session?.working || !session?.question.trim() || session.question.length > changeQuestionLimits.question || !!problem}
      onClick={() => void store.sendChangeQuestion()}>{t("Send question")}</Button>
  </>}>
    <span className="muted">{session?.providerTitle}</span>
    <span className="hint">{t("Review the snapshot before sending. Your question and recent conversation are included. AI answers do not change files.")}</span>
    {session?.loading && <div className="row" style={{ gap: 8, padding: 24 }}><Spinner />{t("Preparing change snapshot…")}</div>}
    {snapshot && <>
      <div className="col" style={{ gap: 3 }}>
        <strong>{snapshot.scope}</strong>
        {snapshot.path && <span className="mono" style={{ userSelect: "text" }}>{snapshot.path}</span>}
        <span className="hint" style={{ userSelect: "text" }}>{snapshot.repository} · HEAD {snapshot.head.slice(0, 12)}</span>
        <span className="hint">{t("This conversation keeps this snapshot even if your selection or files change. Use New snapshot to start again.")}</span>
      </div>
      {snapshot.omitted > 0 && <span className="hint" style={{ color: "var(--orange)" }}>{t("Diff truncated: {0} characters omitted.", snapshot.omitted)}</span>}
      {snapshot.limitations.map((limitation, i) => <span key={i} className="hint" style={{ color: "var(--orange)" }}>{limitation}</span>)}
      <details open={!session?.messages.length}>
        <summary style={{ cursor: "pointer" }}>{t("Context for AI")}</summary>
        <pre className="mono" style={{ maxHeight: 190, overflow: "auto", whiteSpace: "pre-wrap", overflowWrap: "anywhere", userSelect: "text", background: "var(--bg)", padding: 8 }}>{changeQuestionContext(snapshot)}</pre>
      </details>
      {!!session?.messages.length && <div className="col" role="log" aria-label={t("AI conversation")} style={{ maxHeight: 260, overflow: "auto", gap: 12, padding: 8 }}>
        {session.messages.map((message, i) => <div key={i} className="col" style={{ gap: 4 }}>
          <strong className="hint">{message.role === "user" ? t("You") : t("AI answer")}</strong>
          <div style={{ whiteSpace: "pre-wrap", overflowWrap: "anywhere", userSelect: "text" }}>{message.text}</div>
        </div>)}
      </div>}
      <textarea className="textarea" rows={3} aria-label={t("Question about this snapshot")} value={session?.question ?? ""} placeholder={t("Question about this snapshot")}
        onChange={(event) => store.setChangeQuestion(event.target.value)}
        onKeyDown={(event) => { if (event.key === "Enter" && (event.ctrlKey || event.metaKey)) { event.preventDefault(); void store.sendChangeQuestion(); } }} />
      <div className="row" style={{ gap: 6, flexWrap: "wrap" }}>
        {[t("What risks do you see?"), t("Which tests should I run?"), t("Explain this change.")].map((question) => <Button key={question} size="small" disabled={session?.working} onClick={() => store.setChangeQuestion(question)}>{question}</Button>)}
        <span className="spacer" /><span className="hint" style={{ color: (session?.question.length ?? 0) > changeQuestionLimits.question ? "var(--red)" : undefined }}>{session?.question.length ?? 0}/{changeQuestionLimits.question}</span>
      </div>
    </>}
    {(session?.error || problem) && <span role="alert" style={{ color: "var(--red)", whiteSpace: "pre-wrap", userSelect: "text" }}>{session?.error || problem}</span>}
  </Modal>;
}
