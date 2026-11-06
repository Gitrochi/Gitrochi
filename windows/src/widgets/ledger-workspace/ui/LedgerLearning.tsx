import { Archive, ArrowRight, BookOpen, CheckCheck, SquareKanban, Waves, Waypoints } from "lucide-react";
import { CircleCheck } from "@/shared/icons";
import { GitBranch, Inbox, Search, X } from "@/shared/icons";
import { useEffect, useId, useRef, useState } from "react";
import { advanceLearningDelivery, canAdvanceLedgerLearning, emptyAnswerDraft, LEDGER_LEARNING_SETTING, ledgerLearningConnectBody, type LedgerLearningProgress, ledgerLearningSteps, ledgerLearningTitles, ledgerLearningTopics, readLedgerLearning, searchLedgerGuide, type AnswerDraft, type AnswerQuestion } from "@/entities/ledger";
import { LedgerAnswerForm } from "@/features/answer-ledger-question";
import { settings } from "@/shared/config";
import { t } from "@/shared/i18n";
import { Button, Empty, IconButton, Modal } from "@/shared/ui";
import "./ledger-learning.css";

const stepTopics = ["concepts", "views", "answers", "delivery"];
const viewIcons = { Inbox, Board: SquareKanban, Graph: Waypoints, Streams: Waves };
const deliveryCopy = {
  saved: "Your answer is saved. Mark it delivered to simulate the agent reading it.",
  delivered: "The agent has received the practice answer. Confirm the result next.",
  confirmed: "The result is confirmed. Clean up to archive the conversation.",
  archived: "Practice complete. The conversation is archived.",
};

/** Replayable local practice and a searchable guide; no Ledger backend is passed to this component. */
export function LedgerLearning({ onClose, onConnect, onImport, onBringChatGPT, onBrowser }: { onClose: () => void; onConnect: () => void; onImport?: () => void; onBringChatGPT?: () => void; onBrowser?: () => void }) {
  const [tab, setTab] = useState<"tutorial" | "guide">("tutorial");
  const [progress, setProgress] = useState(() => readLedgerLearning(settings.get<unknown>(LEDGER_LEARNING_SETTING, null)));
  const [draft, setDraft] = useState<AnswerDraft>(emptyAnswerDraft);
  const [view, setView] = useState<keyof typeof viewIcons>("Inbox");
  const [query, setQuery] = useState("");
  const [topicId, setTopicId] = useState<string>("setup");
  const root = useRef<HTMLDivElement>(null), heading = useRef<HTMLHeadingElement>(null);
  const id = useId();
  const save = (next: LedgerLearningProgress) => { setProgress(next); settings.set(LEDGER_LEARNING_SETTING, next); };
  const restart = () => { save(readLedgerLearning(null)); setDraft(emptyAnswerDraft()); setView("Inbox"); setTab("tutorial"); };
  const step = ledgerLearningSteps[progress.step];
  const matches = searchLedgerGuide(query, t);
  const topic = matches.find((item) => item.id === topicId) ?? matches[0];
  const stepBody = progress.step === 4 ? ledgerLearningConnectBody : ledgerLearningTopics.find((item) => item.id === stepTopics[progress.step])!.body;
  const question: AnswerQuestion = { id: "practice", question: t("Which channel should this practice session use?"), multiSelect: false, suggestedAnswer: t("Stable"), options: [
    { label: t("Stable"), description: t("Use a verified release"), recommended: true },
    { label: t("Nightly"), description: t("Try the newest changes"), recommended: false },
  ] };
  useEffect(() => {
    const dialog = root.current?.closest("[role='dialog']");
    dialog?.setAttribute("aria-labelledby", `${id}-title`);
    dialog?.setAttribute("aria-modal", "true");
  }, [id]);
  useEffect(() => { if (tab === "tutorial") heading.current?.focus(); }, [progress.step]);
  const action = (callback: () => void) => { onClose(); callback(); };
  const actions = <div className="ledger-learning-actions">
    <Button onClick={() => action(onConnect)}>{t("Connect agents")}</Button>
    {onBrowser && <Button onClick={() => action(onBrowser)}>{t("ChatGPT browser extension")}</Button>}
    {onBringChatGPT && <Button onClick={() => action(onBringChatGPT)}>{t("Bring a ChatGPT draft…")}</Button>}
    {onImport && <Button onClick={() => action(onImport)}>{t("Paste reports")}</Button>}
  </div>;
  return <Modal width={820} onClose={onClose}>
    <div className="ledger-learning" ref={root} onKeyDown={(event) => {
      if (event.key !== "Tab" || event.defaultPrevented || event.nativeEvent.isComposing) return;
      const controls = [...root.current!.querySelectorAll<HTMLElement>("button:not(:disabled),input:not(:disabled),textarea:not(:disabled),[tabindex='0']")].filter((element) => element.getClientRects().length);
      const first = controls[0], last = controls.at(-1);
      if (event.shiftKey && (document.activeElement === first || document.activeElement === heading.current)) { event.preventDefault(); last?.focus(); }
      else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus(); }
    }}>
      <header className="ledger-learning-head"><BookOpen size={18} className="muted" /><h1 id={`${id}-title`}>{t("Learn Ledger")}</h1><span className="spacer" /><IconButton small icon={<X size={16} />} aria-label={t("Close")} tip={t("Close")} onClick={onClose} /></header>
      <div className="ledger-learning-tabs" role="tablist" aria-label={t("Learn Ledger")} onKeyDown={(event) => {
        if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return;
        event.preventDefault();
        const next = tab === "tutorial" ? "guide" : "tutorial";
        setTab(next);
        document.getElementById(`${id}-${next}`)?.focus();
      }}>
        {(["tutorial", "guide"] as const).map((item) => <button key={item} type="button" role="tab" id={`${id}-${item}`} tabIndex={tab === item ? 0 : -1} aria-selected={tab === item} aria-controls={`${id}-panel`} onClick={() => setTab(item)}>{t(item === "tutorial" ? "Tutorial" : "Guide")}</button>)}
      </div>
      <div className="ledger-learning-panel" role="tabpanel" id={`${id}-panel`} aria-labelledby={`${id}-${tab}`}>
        {tab === "tutorial" ? <>
          <div className="ledger-learning-progress"><span className="hint">{t("Step {0} of {1}", progress.step + 1, ledgerLearningSteps.length)}</span><progress max={5} value={progress.step + 1} aria-label={t("Tutorial")} /></div>
          <div className="ledger-learning-tutorial">
            <ol className="ledger-learning-steps" aria-label={t("Tutorial")}>
              {ledgerLearningSteps.map((item, index) => <li key={item} className={index === progress.step ? "current" : ""} aria-current={index === progress.step ? "step" : undefined}><span className="ledger-learning-step-number">{index < progress.step ? <CheckCheck size={13} /> : index + 1}</span><span className="ledger-learning-step-title">{t(ledgerLearningTitles[index])}</span></li>)}
            </ol>
            <section className="ledger-learning-content" data-learning-step={step}>
              <h2 ref={heading} tabIndex={-1}>{t(ledgerLearningTitles[progress.step])}</h2>
              <p>{t(stepBody)}</p>
              {step === "concepts" && <div className="ledger-learning-path" aria-label={t("Sessions and baselines")}><span className="ledger-learning-baseline">v1.0.0</span><ArrowRight size={18} className="muted" /><div className="ledger-learning-session"><GitBranch size={16} className="muted" /><span>{t("Session")}</span><span className="hint">{t("Report")}</span></div></div>}
              {step === "views" && <div className="ledger-learning-views">
                {(Object.keys(viewIcons) as (keyof typeof viewIcons)[]).map((item) => { const Icon = viewIcons[item]; return <button type="button" key={item} aria-pressed={view === item} onClick={() => setView(item)}><Icon size={20} /><span>{t(item)}</span></button>; })}
              </div>}
              {step === "answer" && <div className="ledger-learning-practice">
                <span className="hint">{t("This practice stays local and does not change your Ledger.")}</span>
                {progress.answerSent ? <div className="ledger-learning-complete" role="status"><CircleCheck size={18} /><span>{t("Completed")}</span>{draft.text && <p className="selectable">{draft.text}</p>}<Button size="small" onClick={() => { setDraft(emptyAnswerDraft()); save({ ...progress, completed: false, answerSent: false, deliveryState: "saved" }); }}>{t("Reset")}</Button></div>
                  : <LedgerAnswerForm questions={[question]} drafts={{ practice: draft }} onChange={(_, value) => setDraft(value)} onSubmit={() => { if (draft.text.trim()) save({ ...progress, answerSent: true }); }} />}
              </div>}
              {step === "delivery" && <div className="ledger-learning-practice" data-delivery={progress.deliveryState}>
                <span className="hint">{t("This practice stays local and does not change your Ledger.")}</span>
                <div className="ledger-learning-delivery-path">{["Save answer", "Delivered", "Confirm", "Clean up"].map((label, index) => <span key={label} className={index === ["saved", "delivered", "confirmed", "archived"].indexOf(progress.deliveryState) ? "current" : ""}>{index > 0 && <ArrowRight size={12} />}{t(label)}</span>)}</div>
                <p role="status">{t(deliveryCopy[progress.deliveryState])}</p>
                <div className="ledger-learning-actions">
                  {progress.deliveryState !== "archived" && <Button kind="primary" data-learning-deliver onClick={() => save({ ...progress, deliveryState: advanceLearningDelivery(progress.deliveryState) })}>{progress.deliveryState === "saved" ? <CheckCheck size={14} /> : progress.deliveryState === "delivered" ? <CircleCheck size={14} /> : <Archive size={14} />}{t(progress.deliveryState === "saved" ? "Mark delivered" : progress.deliveryState === "delivered" ? "Confirm" : "Clean up")}</Button>}
                  <Button onClick={() => save({ ...progress, completed: false, deliveryState: "saved" })}>{t("Reset")}</Button>
                </div>
              </div>}
              {step === "connect" && <>{actions}{progress.completed && <div className="ledger-learning-complete" role="status"><CircleCheck size={18} />{t("Completed")}</div>}</>}
            </section>
          </div>
        </> : <div className="ledger-learning-guide">
          <div className="ledger-learning-search"><Search size={15} className="muted" /><input className="input" value={query} placeholder={t("Search the guide")} aria-label={t("Search the guide")} onChange={(event) => setQuery(event.target.value)} /></div>
          {!topic ? <div className="ledger-learning-no-topics"><Empty title={t("No guide topics match.")} /><Button onClick={() => setQuery("")}>{t("Clear search")}</Button></div> : <>
            <nav className="ledger-learning-topics" aria-label={t("Guide")}>{matches.map((item) => <button key={item.id} type="button" aria-current={topic.id === item.id ? "page" : undefined} onClick={() => setTopicId(item.id)}>{t(item.title)}</button>)}</nav>
            <article className="ledger-learning-content" data-guide-topic={topic.id}><h2 ref={heading} tabIndex={-1}>{t(topic.title)}</h2><p>{t(topic.body)}</p>
              {topic.id === "setup" && actions}
              {"detail" in topic && <p>{t(topic.detail)}</p>}
              {topic.id === "answers" && <Button onClick={() => { setDraft(emptyAnswerDraft()); save({ ...progress, step: 2, completed: false, answerSent: false, deliveryState: "saved" }); setTab("tutorial"); }}>{t("Try answering a question")}</Button>}
            </article>
          </>}
        </div>}
      </div>
      <footer className="ledger-learning-footer"><Button onClick={restart}>{t("Restart")}</Button><span className="spacer" />
        {tab === "tutorial" ? <><Button disabled={progress.step === 0} onClick={() => save({ ...progress, step: Math.max(0, progress.step - 1) })}>{t("Back")}</Button><Button kind="primary" data-learning-next disabled={!canAdvanceLedgerLearning(progress)} onClick={() => { if (progress.step < 4) save({ ...progress, step: progress.step + 1 }); else { save({ ...progress, completed: true }); onClose(); } }}>{t(progress.step === 4 ? "Done" : "Next")}</Button></> : <Button kind="primary" onClick={onClose}>{t("Done")}</Button>}
      </footer>
    </div>
  </Modal>;
}
