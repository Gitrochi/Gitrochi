import { t } from "@/shared/i18n";
import type { LedgerPendingPrompt, LedgerState, LedgerStreamCycle, LedgerVerdict } from "../model/types";
import { countdown, describeAnswer, promptHold, promptSummary, waitingPrompts } from "./countdown";

/** What a click on a notification opens: a session, and the prompt or question it was about */
export interface LedgerTarget {
  sessionId?: string;
  promptId?: number;
  questionId?: number;
}

export interface LedgerNotice {
  title: string;
  body: string;
  target: LedgerTarget;
}

const tidy = (verdict: LedgerVerdict | undefined) => verdict === "confirm" || verdict === "expirable";
const cycleKey = (c: LedgerStreamCycle) => `${c.sessionId}\u0000${c.version}`;
const answerWords: Record<string, string> = { allow: "Allow", deny: "Deny", approve: "Approve the plan", release: "Left to the terminal", hold: "No automatic answer", unknown: "Continue" };

/** An answer in words, as the review list shows it */
function answerText(value: unknown) {
  const answer = describeAnswer(value);
  if (answer.kind === "text") return answer.text;
  return answer.text ? `${t(answerWords[answer.kind])}: ${answer.text}` : t(answerWords[answer.kind]);
}

/** Why auto-continue left a wait to the person, and where to answer it */
export const heldText = (hold: { reason: string; count: number }) => [hold.reason && t(hold.reason, hold.count), t("Answer it in the agent's terminal.")].filter(Boolean).join(" ");

/** Who a prompt belongs to: its session, else the agent that asked */
const owner = (p: LedgerPendingPrompt) => p.sessionId ?? p.agentId ?? "";

/**
 * What changed between two states that a person should hear about (docs/ledger/DESIGN.md §10.11). Nothing is
 * announced for what existed when the app started (no `before`). New questions, sessions newly to confirm or clean up
 * and new `applied` reports make one notification, several of them one grouped notification; every new waiting
 * prompt (with the time left, or that nothing answers it) and every automatic answer makes one of its own.
 * (macOS: the same rules with UserNotifications)
 */
export function ledgerNotices(before: LedgerState | null, after: LedgerState): LedgerNotice[] {
  if (!before) return [];
  const titles = new Map(after.sessions.map((s) => [s.id, s.title]));
  const grouped: LedgerNotice[] = [];
  const asked = new Set(before.questions.map((q) => q.id));
  for (const q of after.questions) if (!asked.has(q.id)) grouped.push({ title: t("Question from {0}", q.sessionId), body: q.text, target: { sessionId: q.sessionId, questionId: q.id } });
  const verdicts = new Map(before.sessions.map((s) => [s.id, s.verdict]));
  for (const s of after.sessions) {
    if (!tidy(s.verdict) || tidy(verdicts.get(s.id))) continue;
    grouped.push({ title: t(s.verdict === "confirm" ? "To confirm: {0}" : "Ready to clean up: {0}", s.id), body: s.title, target: { sessionId: s.id } });
  }
  const applied = new Set(before.streams.filter((c) => c.state === "applied").map(cycleKey));
  for (const c of after.streams) if (c.state === "applied" && !applied.has(cycleKey(c))) grouped.push({ title: t("{0} applied {1}", c.sessionId, c.version), body: titles.get(c.sessionId) ?? "", target: { sessionId: c.sessionId } });

  const out: LedgerNotice[] = grouped.length > 1 ? [{ title: t("{0} new items in the Ledger", grouped.length), body: grouped.slice(0, 4).map((n) => `${n.title} · ${n.body}`).join("\n"), target: {} }] : grouped;
  const waiting = new Set(before.pendingPrompts.map((p) => p.id));
  for (const p of waitingPrompts(after.pendingPrompts)) {
    if (waiting.has(p.id)) continue;
    const hold = promptHold(p);
    const left = hold ? heldText(hold) : p.deadline ? t("Auto-answer in {0}", countdown(p.deadline, after.now).text) : t("No automatic answer");
    out.push({ title: t("{0} is waiting for you", owner(p)), body: [promptSummary(p), left].filter(Boolean).join("\n"), target: { sessionId: p.sessionId, promptId: p.id } });
  }
  const reviewed = new Set((before.autoReview ?? []).map((p) => p.id));
  for (const p of after.autoReview ?? []) {
    if (reviewed.has(p.id)) continue;
    out.push({ title: t("Answered automatically for {0}", owner(p)), body: [promptSummary(p), answerText(p.answer)].filter(Boolean).join("\n"), target: { sessionId: p.sessionId, promptId: p.id } });
  }
  return out;
}

/** The overlay's text: the count, at most two digits */
export const badgeLabel = (total: number) => (total > 99 ? "99+" : total > 0 ? String(total) : "");
