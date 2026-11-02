import { Check, CircleHelp, ClipboardList, MessageCircleQuestion, ShieldQuestion, SquareTerminal, Timer, TimerOff, X } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { countdown, describeAnswer, heldText, type AnswerDraft, type LedgerPendingPrompt, type LedgerStore, promptActions, promptAnswerQuestions, promptDraftAnswer, promptHold, promptSummary, serverNow, waitingPrompts } from "@/entities/ledger";
import { answerText } from "./parts";
import { LedgerAnswerForm } from "@/features/answer-ledger-question";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button } from "@/shared/ui";
import { SessionId } from "./parts";

const kindLooks = { stop_question: { icon: MessageCircleQuestion, label: "Asks before it stops" }, ask_user_question: { icon: CircleHelp, label: "Asks you to choose" }, exit_plan_mode: { icon: ClipboardList, label: "Plan to approve" }, permission: { icon: ShieldQuestion, label: "Asks for permission" } } as const;

/** Waiting prompts in the project shown, the one answered soonest first */
export function visiblePrompts(store: LedgerStore): LedgerPendingPrompt[] {
  const project = store.project;
  return waitingPrompts(store.state?.pendingPrompts ?? []).filter((p) => !project || (p.sessionId ? store.session(p.sessionId)?.project === project : true));
}

/** Re-renders every second while a countdown runs */
export function useSecondTicker(on: boolean) {
  const [, setTick] = useState(0);
  useEffect(() => {
    if (!on) return;
    const timer = setInterval(() => setTick((n) => n + 1), 1000);
    return () => clearInterval(timer);
  }, [on]);
}

/**
 * The top of the Inbox: agents waiting for an answer, each with the time left before auto-continue answers for the
 * person. Answer, allow or deny here (`prompt_answer`), answer in the agent's terminal instead, or keep this one from
 * being answered automatically; the last two end the hook's wait without a decision, so the terminal asks. A permission
 * request shows in the terminal during the wait as well (#171). (macOS: Views/Ledger/LedgerPromptStrip.swift)
 */
export function LedgerPromptStrip({ store, onOpen, onOpenTerminal }: { store: LedgerStore; onOpen: (sessionId: string) => void; onOpenTerminal: (prompt: LedgerPendingPrompt) => void }) {
  useObserve(store);
  const prompts = visiblePrompts(store);
  const [retained, setRetained] = useState<Record<number, LedgerPendingPrompt>>({});
  const shown = [...prompts, ...Object.values(retained).filter((prompt) => !prompts.some((live) => live.id === prompt.id))];
  useSecondTicker(prompts.some((p) => p.deadline));
  if (!store.state || !shown.length) return null;
  const now = serverNow(store.state.now, store.stateReadAt, Date.now());
  return (
    <section className="ledger-prompts" aria-label={t("Waiting for you")}>
      <div className="ledger-prompts-head">
        <Timer size={13} />
        {t("Waiting for you")}
        {prompts.length > 0 && <span className="counter">{prompts.length}</span>}
      </div>
      {shown.map((p) => <PromptRow key={p.id} store={store} prompt={p} now={now} available={prompts.some((live) => live.id === p.id)} onRetain={(keep) => setRetained((previous) => {
        const next = { ...previous };
        if (keep) next[p.id] = p; else delete next[p.id];
        return next;
      })} onOpen={onOpen} onOpenTerminal={onOpenTerminal} />)}
    </section>
  );
}

function PromptRow({ store, prompt, now, available, onRetain, onOpen, onOpenTerminal }: { store: LedgerStore; prompt: LedgerPendingPrompt; now: number; available: boolean; onRetain: (keep: boolean) => void; onOpen: (id: string) => void; onOpenTerminal: (p: LedgerPendingPrompt) => void }) {
  const [answering, setAnswering] = useState(false);
  const [drafts, setDrafts] = useState<Record<string, AnswerDraft>>({});
  const [saving, setSaving] = useState(false);
  const inFlight = useRef(false);
  const session = store.session(prompt.sessionId);
  const look = kindLooks[prompt.kind];
  const actions = promptActions(prompt.kind);
  const questions = promptAnswerQuestions(prompt);
  const summary = promptSummary(prompt);
  const proposed = prompt.payload.proposed ? describeAnswer(prompt.payload.proposed) : null;
  // a wait auto-continue left to the person: no hook waits on it, so an answer here would not reach the agent
  const hold = promptHold(prompt);
  const terminalOnly = !!hold || prompt.deadline <= 0;
  const left = countdown(terminalOnly ? 0 : prompt.deadline, now);
  const busy = store.busy > 0 || saving;
  const automatic = !terminalOnly && prompt.payload.autoAnswer !== false;
  const send = async (answer: Parameters<LedgerStore["answerPrompt"]>[1]) => {
    const ok = await store.answerPrompt(prompt, answer);
    if (ok) onRetain(false);
    return ok;
  };
  const submit = async () => {
    const answer = promptDraftAnswer(prompt, questions, drafts);
    if (!answer || busy || !available || inFlight.current) return;
    inFlight.current = true;
    setSaving(true);
    try { await send(answer); } finally { inFlight.current = false; setSaving(false); }
  };
  return (
    <div className="ledger-prompt" data-prompt={prompt.id}>
      <div className="ledger-prompt-head">
        <look.icon size={15} className="muted" aria-hidden />
        <span className="hint" style={{ fontWeight: 600 }}>{t(look.label)}</span>
        {session ? (
          <button type="button" className="link" onClick={() => onOpen(session.id)} data-tip={session.title}>
            <SessionId session={session} />
          </button>
        ) : prompt.agentId ? (
          <span className="faint">{prompt.agentId}</span>
        ) : null}
        {session && <span className="ellipsis muted grow">{session.title}</span>}
        {available && <span className={`ledger-countdown ${left.tone}`} role="timer" aria-live="off" data-tip={left.tone === "none" || !automatic ? t("A person answers this one.") : t("Auto-continue answers with a careful default when the time runs out.")}>
          {left.tone === "none" ? <><TimerOff size={12} />{t("No automatic answer")}</> : !automatic ? <><Timer size={12} />{t("Time left {0}", left.text)}</> : left.tone === "due" ? t("Answering automatically…") : <><Timer size={12} />{t("Auto-answer in {0}", left.text)}</>}
        </span>}
      </div>
      {summary && !answering && available && <div className={`ledger-prompt-text selectable${prompt.kind === "permission" ? " mono" : ""}`}>{summary}</div>}
      {available && proposed && proposed.kind !== "unknown" && left.tone !== "none" && automatic && <div className="hint selectable">{t("If nobody answers: {0}", answerText(proposed))}</div>}
      {hold ? <div className="hint">{heldText(hold)}</div> : prompt.kind === "permission" && <div className="hint">{t("The agent's terminal shows this request too; an answer there counts as well.")}</div>}
      {!available && <div className="hint" role="status">{t("The prompt was already answered.")} {t("Your draft was not sent.")}</div>}
      {terminalOnly ? (
        <div className="ledger-row-actions">
          <Button size="small" kind="primary" onClick={() => onOpenTerminal(prompt)}>
            <SquareTerminal size={13} />
            {t("Answer in terminal")}
          </Button>
        </div>
      ) : answering || !available ? (
        <>
          <LedgerAnswerForm questions={questions} drafts={drafts} onChange={(id, value) => {
            const next = { ...drafts, [id]: value };
            setDrafts(next);
            onRetain(Object.values(next).some((draft) => draft.text.length > 0));
          }} onSubmit={() => void submit()} onCancel={available ? () => setAnswering(false) : undefined} disabled={!available || store.busy > 0} saving={saving} autoFocus={available} />
          {!available && <div className="ledger-row-actions"><Button size="small" onClick={() => onRetain(false)}>{t("Close")}</Button></div>}
        </>
      ) : (
        <div className="ledger-row-actions">
          {actions.reply && <Button size="small" kind="primary" disabled={busy} onClick={() => setAnswering(true)}>{t("Answer")}</Button>}
          {actions.allow && <Button size="small" kind="primary" disabled={busy} onClick={() => void send({ decision: "allow" })}><Check size={13} />{t("Allow")}</Button>}
          {actions.allow && <Button size="small" disabled={busy} onClick={() => void send({ decision: "deny" })}><X size={13} />{t("Deny")}</Button>}
          <Button size="small" disabled={busy} onClick={() => { onOpenTerminal(prompt); void send({ release: true }); }} tip={`${t("Answer in terminal")}|${t("Stops the countdown and leaves the question to the agent's terminal.")}`}>
            <SquareTerminal size={13} />
            {t("Answer in terminal")}
          </Button>
          {prompt.deadline > 0 && automatic && (
            <Button size="small" disabled={busy} onClick={() => void send({ hold: true })} tip={`${t("Not this time")}|${t("No automatic answer for this prompt; it waits for you in the agent's terminal.")}`}>
              <TimerOff size={13} />
              {t("Not this time")}
            </Button>
          )}
        </div>
      )}
    </div>
  );
}
