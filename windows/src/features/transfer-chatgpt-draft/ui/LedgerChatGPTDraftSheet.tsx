import { Clipboard } from "lucide-react";
import { MessageSquare } from "@/shared/icons";
import { useEffect, useId, useMemo, useRef, useState } from "react";
import { parseChatGPTQuestion, type ChatGPTQuestion, type LedgerStore } from "@/entities/ledger";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, Modal, Spinner } from "@/shared/ui";
import "./ledger-chatgpt-draft.css";

/** An explicit paste is previewed locally; importing never reads or sends to another app. */
export function LedgerChatGPTDraftSheet({ store, onClose, onOpenQuestion }: { store: LedgerStore; onClose: () => void; onOpenQuestion: (sessionId: string) => void }) {
  useObserve(store);
  const root = useRef<HTMLDivElement>(null);
  const id = useId();
  useEffect(() => {
    const dialog = root.current?.closest<HTMLElement>("[role='dialog']");
    const title = dialog?.querySelector<HTMLElement>(".modal-title");
    if (!dialog || !title) return;
    title.id = `${id}-title`;
    dialog.setAttribute("aria-labelledby", title.id);
    dialog.setAttribute("aria-modal", "true");
    const trap = (event: KeyboardEvent) => {
      if (event.key !== "Tab" || event.defaultPrevented || event.isComposing) return;
      const controls = [...dialog.querySelectorAll<HTMLElement>("button:not(:disabled),input:not(:disabled),select:not(:disabled),textarea:not(:disabled)")].filter((element) => element.tabIndex >= 0 && element.getClientRects().length);
      if (event.shiftKey && document.activeElement === controls[0]) { event.preventDefault(); controls.at(-1)?.focus(); }
      else if (!event.shiftKey && document.activeElement === controls.at(-1)) { event.preventDefault(); controls[0]?.focus(); }
    };
    dialog.addEventListener("keydown", trap);
    return () => dialog.removeEventListener("keydown", trap);
  }, [id]);
  const [mode, setMode] = useState<"answer" | "question">("answer");
  const [raw, setRaw] = useState("");
  const [questionId, setQuestionId] = useState(() => {
    const available = (store.state?.questions ?? []).filter((question) => question.state === "open" && (!store.project || store.session(question.sessionId)?.project === store.project));
    const initial = available.find((question) => question.sessionId === store.selectedId) ?? available[0];
    return initial ? String(initial.id) : "";
  });
  const [project, setProject] = useState(store.project ?? store.state?.projects[0]?.key ?? "");
  const [sessionId, setSessionId] = useState(() => {
    const initial = store.session(store.selectedId);
    return initial && !initial.archivedAt && initial.status === "active" && initial.project === (store.project ?? store.state?.projects[0]?.key ?? "") ? initial.id : "";
  });
  const [preview, setPreview] = useState<ChatGPTQuestion | null>(null);
  const [working, setWorking] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const sessions = (store.state?.sessions ?? []).filter((session) => !session.archivedAt && session.status === "active");
  const questions = useMemo(() => (store.state?.questions ?? []).filter((question) => question.state === "open" && (!store.project || store.session(question.sessionId)?.project === store.project)), [store.state, store.project]);
  const selected = questions.find((question) => String(question.id) === questionId);
  const target = sessions.find((session) => session.id === sessionId && session.project === project);
  const tooLarge = new TextEncoder().encode(raw).length > 65_536;
  const usable = !!raw.trim() && !tooLarge;
  const update = (text: string) => { setRaw(text); setPreview(null); setError(null); };
  const previewQuestion = () => {
    try { setPreview(parseChatGPTQuestion(raw)); setError(null); } catch (cause) { setPreview(null); setError(t(cause instanceof Error ? cause.message : String(cause))); }
  };
  const useDraft = () => {
    if (!selected || !usable) return;
    store.setUnsentAnswer(selected.id, raw);
    store.changed();
    store.setView("inbox");
    onOpenQuestion(selected.sessionId);
    onClose();
  };
  const save = async () => {
    if (!preview || !project.trim() || working || (sessionId && !target)) return;
    setWorking(true);
    setError(null);
    try {
      const report = { event: "question", project: project.trim(), ...(target ? { session: target.id } : { title: [...preview.text].slice(0, 120).join("") }), summary: preview.text,
        question: preview, body: "Source: text pasted by the user. The source app was not verified." };
      const summary = await store.importReports(JSON.stringify(report));
      if (summary.failed) { setError(summary.lines.find((line) => line.error)?.error ?? t("Could not read this block")); return; }
      const id = summary.lines.find((line) => line.sessionId)?.sessionId;
      if (!id) { setError(t("No report blocks found.")); return; }
      store.setProjectChoice(project.trim());
      await store.refresh(true);
      store.setView("inbox");
      onOpenQuestion(id);
      onClose();
    } catch (cause) { setError(cause instanceof Error ? cause.message : String(cause)); }
    finally { setWorking(false); }
  };
  return <Modal title={t("Bring a ChatGPT draft…")} width={700} onClose={() => { if (!working) onClose(); }} footer={<>
    <span className="hint grow">{mode === "answer" ? t("Only fills a draft. Send it from the question form.") : t("Preview the question and choices before saving.")}</span>
    <Button disabled={working} onClick={onClose}>{t("Cancel")}</Button>
    {mode === "answer" ? <Button kind="primary" disabled={!usable || !selected || working} onClick={useDraft}>{t("Use draft")}</Button>
      : preview ? <Button kind="primary" disabled={!project.trim() || working || (!!sessionId && !target)} onClick={() => void save()}>{working && <Spinner size={12} />}{t("Save question")}</Button>
      : <Button kind="primary" disabled={!usable || working} onClick={previewQuestion}>{t("Preview")}</Button>}
  </>}>
    <div className="ledger-chatgpt-draft" ref={root}>
      <div className="ledger-chatgpt-source"><Clipboard size={15} aria-hidden /><span>{t("Pasted by you")}</span></div>
      <p className="hint">{t("Accept the suggestion with Tab in its original app without sending it. Copy the draft or question and paste it here. Review the destination before using it.")}</p>
      <p className="hint">{t("This is a manual transfer. The Ledger does not read ChatGPT or Codex input boxes automatically.")}</p>
      <div className="ledger-chatgpt-modes" role="tablist" aria-label={t("Use pasted text")} onKeyDown={(event) => {
        if (working || !["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return;
        event.preventDefault();
        const next = event.key === "Home" ? "answer" : event.key === "End" ? "question" : mode === "answer" ? "question" : "answer";
        setMode(next); setError(null);
        document.getElementById(`${id}-${next}`)?.focus();
      }}>
        <button type="button" role="tab" id={`${id}-answer`} tabIndex={mode === "answer" ? 0 : -1} className={mode === "answer" ? "on" : ""} aria-selected={mode === "answer"} disabled={working} onClick={() => { setMode("answer"); setError(null); }}>{t("Answer a question")}</button>
        <button type="button" role="tab" id={`${id}-question`} tabIndex={mode === "question" ? 0 : -1} className={mode === "question" ? "on" : ""} aria-selected={mode === "question"} disabled={working} onClick={() => { setMode("question"); setError(null); }}>{t("Add a question")}</button>
      </div>
      {mode === "answer" ? questions.length ? <label className="col"><span>{t("Question in your Ledger")}</span><select className="select" aria-label={t("Question in your Ledger")} value={selected ? String(selected.id) : ""} disabled={working} onChange={(event) => setQuestionId(event.target.value)}>
        {!selected && <option value="">{t("Select a question")}</option>}
        {questions.map((question) => <option key={question.id} value={String(question.id)}>{store.session(question.sessionId)?.title} · {question.text}</option>)}
      </select></label> : <div className="ledger-chatgpt-empty"><MessageSquare size={24} aria-hidden /><strong>{t("No open questions")}</strong><span className="hint">{t("Add a question from the pasted text, or choose another project in the Ledger.")}</span><Button onClick={() => setMode("question")}>{t("Add a question")}</Button></div>
        : <div className="ledger-chatgpt-target"><label className="col"><span>{t("Project")}</span><input className="input" aria-label={t("Project")} value={project} disabled={working} onChange={(event) => { setProject(event.target.value); setSessionId(""); }} /></label><label className="col"><span>{t("Session")}</span><select className="select" aria-label={t("Session")} value={sessionId} disabled={working} onChange={(event) => setSessionId(event.target.value)}><option value="">{t("New session")}</option>{sessionId && !target && <option value={sessionId}>{t("Select a session")}</option>}{sessions.filter((session) => session.project === project).map((session) => <option key={session.id} value={session.id}>{session.title}</option>)}</select></label></div>}
      <label className="col"><span>{t("Copied text")}</span><textarea className="textarea" rows={7} autoFocus aria-label={t("Copied text")} value={raw} readOnly={working} onChange={(event) => update(event.target.value)} placeholder={t("Paste the copied draft or question here…")} /></label>
      {mode === "question" && <span className="hint">{t("A question can include bullet choices or a structured Ledger question. Use Paste reports for several questions.")}</span>}
      {tooLarge && <span className="error-text" role="alert">{t("Pasted text is limited to 64 KiB.")}</span>}
      {!usable && !tooLarge && <span className="hint">{t("Paste text before continuing.")}</span>}
      {mode === "answer" && questionId && !selected && <span className="hint">{t("The selected question is no longer open. Choose another question; your copied text is still here.")}</span>}
      {mode === "question" && sessionId && !target && <span className="hint">{t("The selected session is no longer active. Choose a destination again.")}</span>}
      {mode === "question" && !project.trim() && <span className="hint">{t("Choose a project name before saving.")}</span>}
      {preview && mode === "question" && <section className="ledger-chatgpt-preview" aria-label={t("Preview")}><strong className="selectable">{preview.text}</strong>{preview.options?.map((option) => <div key={option.label}><span>{option.label}</span>{option.recommended && <span className="hint"> · {t("Recommended")}</span>}{option.description && <div className="hint">{option.description}</div>}</div>)}{preview.suggestedAnswer && <div className="hint">{t("Suggested answer")}: {preview.suggestedAnswer}</div>}<Button size="small" onClick={previewQuestion}>{t("Update preview")}</Button></section>}
      {error && <span className="error-text" role="alert">{error}</span>}
    </div>
  </Modal>;
}
