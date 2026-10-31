import { Check, CircleHelp, ClipboardList, MessageCircleQuestion, ShieldQuestion, SquareTerminal, Timer, TimerOff, X } from "lucide-react";
import { useEffect, useState } from "react";
import { countdown, type LedgerPendingPrompt, type LedgerStore, promptActions, promptOptions, promptSummary, serverNow, waitingPrompts } from "@/entities/ledger";
import { LedgerAnswerField } from "@/features/answer-ledger-question";
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
 * person. Answer, allow or deny here, answer in the agent's terminal instead, or keep this one from being answered
 * automatically. (macOS: Views/Ledger/LedgerPromptStrip.swift)
 */
export function LedgerPromptStrip({ store, onOpen, onOpenTerminal }: { store: LedgerStore; onOpen: (sessionId: string) => void; onOpenTerminal: (prompt: LedgerPendingPrompt) => void }) {
  useObserve(store);
  const prompts = visiblePrompts(store);
  useSecondTicker(prompts.some((p) => p.deadline));
  if (!store.state || !prompts.length) return null;
  const now = serverNow(store.state.now, store.stateReadAt, Date.now());
  return (
    <section className="ledger-prompts" aria-label={t("Waiting for you")}>
      <div className="ledger-prompts-head">
        <Timer size={13} />
        {t("Waiting for you")}
        <span className="counter">{prompts.length}</span>
      </div>
      {prompts.map((p) => <PromptRow key={p.id} store={store} prompt={p} now={now} onOpen={onOpen} onOpenTerminal={onOpenTerminal} />)}
    </section>
  );
}

function PromptRow({ store, prompt, now, onOpen, onOpenTerminal }: { store: LedgerStore; prompt: LedgerPendingPrompt; now: number; onOpen: (id: string) => void; onOpenTerminal: (p: LedgerPendingPrompt) => void }) {
  const [answering, setAnswering] = useState(false);
  const session = store.session(prompt.sessionId);
  const look = kindLooks[prompt.kind];
  const left = countdown(prompt.deadline, now);
  const actions = promptActions(prompt.kind);
  const options = promptOptions(prompt);
  const summary = promptSummary(prompt);
  const busy = store.busy > 0;
  const send = (answer: Parameters<LedgerStore["answerPrompt"]>[1]) => store.answerPrompt(prompt, answer);
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
          <span className="mono faint">{prompt.agentId}</span>
        ) : null}
        {session && <span className="ellipsis muted grow">{session.title}</span>}
        <span className={`ledger-countdown ${left.tone}`} role="timer" aria-live="off" data-tip={left.tone === "none" ? t("A person answers this one.") : t("Auto-continue answers with a careful default when the time runs out.")}>
          {left.tone === "none" ? <><TimerOff size={12} />{t("No automatic answer")}</> : left.tone === "due" ? t("Answering automatically…") : <><Timer size={12} />{t("Auto-answer in {0}", left.text)}</>}
        </span>
      </div>
      {summary && <div className={`ledger-prompt-text selectable${prompt.kind === "permission" ? " mono" : ""}`}>{summary}</div>}
      {answering ? (
        <>
          {options.length > 0 && (
            <div className="ledger-options">
              {options.map((option) => <Button key={option} size="small" disabled={busy} onClick={() => void send({ action: "reply", text: option })}>{option}</Button>)}
            </div>
          )}
          <LedgerAnswerField autoFocus label={t("Answer")} placeholder={t("Write an answer…")} submitLabel="Send answer" onSubmit={(text) => send({ action: "reply", text })} onCancel={() => setAnswering(false)} />
        </>
      ) : (
        <div className="ledger-row-actions">
          {actions.reply && <Button size="small" kind="primary" disabled={busy} onClick={() => setAnswering(true)}>{t("Answer")}</Button>}
          {actions.allow && <Button size="small" kind="primary" disabled={busy} onClick={() => void send({ action: "allow" })}><Check size={13} />{t("Allow")}</Button>}
          {actions.allow && <Button size="small" disabled={busy} onClick={() => void send({ action: "deny" })}><X size={13} />{t("Deny")}</Button>}
          <Button size="small" disabled={busy} onClick={() => { onOpenTerminal(prompt); void send({ action: "release" }); }} tip={`${t("Answer in terminal")}|${t("Stops the countdown and leaves the question to the agent's terminal.")}`}>
            <SquareTerminal size={13} />
            {t("Answer in terminal")}
          </Button>
          {prompt.deadline > 0 && (
            <Button size="small" disabled={busy} onClick={() => void send({ action: "hold" })} tip={`${t("Not automatically this time")}|${t("Stops the countdown for this prompt only; it waits for you here.")}`}>
              <TimerOff size={13} />
              {t("Not automatically this time")}
            </Button>
          )}
        </div>
      )}
    </div>
  );
}
