import type { LedgerPendingPrompt, LedgerQuestion, LedgerSession, LedgerState } from "../model/types";
import { inProject } from "./filter";

export type InboxGroupId = "questions" | "auto" | "tidy" | "decide";

export type InboxItem =
  | { kind: "question"; key: string; session: LedgerSession; question: LedgerQuestion }
  | { kind: "autoQuestion"; key: string; session: LedgerSession; question: LedgerQuestion }
  | { kind: "autoPrompt"; key: string; session: LedgerSession | null; prompt: LedgerPendingPrompt }
  | { kind: "session"; key: string; session: LedgerSession };

export interface InboxGroup {
  id: InboxGroupId;
  /** English title; the screen translates it */
  title: string;
  items: InboxItem[];
}

/** What a triage key does to an item; null = nothing */
export type InboxAction = "open" | "answer" | "confirm" | "archive" | "snooze";

const titles: Record<InboxGroupId, string> = { questions: "Questions", auto: "Continued automatically — review", tidy: "To clean up", decide: "To decide" };

/**
 * Only what needs a person, in four groups: open questions (answered in place, newest session first), automatic replies
 * to review, finished sessions to confirm or archive, and sessions to decide (done, or stale). Streams stay out of the
 * last group. Empty groups are left out. (macOS: LedgerInbox.groups)
 */
export function inboxGroups(state: Pick<LedgerState, "sessions" | "questions" | "pendingPrompts">, project: string | null): InboxGroup[] {
  const byId = new Map(state.sessions.map((s) => [s.id, s]));
  const live = (id: string | undefined) => {
    const s = id ? byId.get(id) : undefined;
    return s && s.verdict !== "archived" && inProject(s, project) ? s : undefined;
  };
  const latest = new Map<string, number>();
  for (const q of state.questions) if (q.state === "open") latest.set(q.sessionId, Math.max(latest.get(q.sessionId) ?? 0, q.createdAt));
  const questions: InboxItem[] = state.questions
    .filter((q) => q.state === "open" && live(q.sessionId))
    .sort((a, b) => (latest.get(b.sessionId) ?? 0) - (latest.get(a.sessionId) ?? 0) || a.sessionId.localeCompare(b.sessionId) || a.createdAt - b.createdAt || a.id - b.id)
    .map((q) => ({ kind: "question", key: `q:${q.id}`, session: live(q.sessionId)!, question: q }));
  const auto: { at: number; item: InboxItem }[] = [
    ...state.questions
      .filter((q) => q.state === "answered" && q.answeredBy === "auto" && live(q.sessionId))
      .map((q) => ({ at: q.answeredAt ?? q.createdAt, item: { kind: "autoQuestion" as const, key: `aq:${q.id}`, session: live(q.sessionId)!, question: q } })),
    ...state.pendingPrompts
      .filter((p) => p.state === "auto" && (p.sessionId ? !!live(p.sessionId) : !project))
      .map((p) => ({ at: p.deadline || p.createdAt, item: { kind: "autoPrompt" as const, key: `ap:${p.id}`, session: live(p.sessionId) ?? null, prompt: p } })),
  ];
  auto.sort((a, b) => b.at - a.at || a.item.key.localeCompare(b.item.key));
  const sessions = state.sessions.filter((s) => inProject(s, project));
  const recent = (a: LedgerSession, b: LedgerSession) => b.lastAt - a.lastAt || a.id.localeCompare(b.id);
  const tidy = sessions.filter((s) => s.verdict === "confirm" || s.verdict === "expirable").sort((a, b) => (a.verdict === b.verdict ? recent(a, b) : a.verdict === "confirm" ? -1 : 1));
  const decide = sessions.filter((s) => !s.stream && (s.verdict === "pending_merge" || s.verdict === "stale")).sort((a, b) => (a.verdict === b.verdict ? recent(a, b) : a.verdict === "pending_merge" ? -1 : 1));
  const groups: InboxGroup[] = [
    { id: "questions", title: titles.questions, items: questions },
    { id: "auto", title: titles.auto, items: auto.map((a) => a.item) },
    { id: "tidy", title: titles.tidy, items: tidy.map((s) => ({ kind: "session", key: `s:${s.id}`, session: s })) },
    { id: "decide", title: titles.decide, items: decide.map((s) => ({ kind: "session", key: `s:${s.id}`, session: s })) },
  ];
  return groups.filter((g) => g.items.length);
}

/** The items in screen order, for ↑ and ↓ */
export const inboxItems = (groups: readonly InboxGroup[]) => groups.flatMap((g) => g.items);

/** The Inbox count: questions + clean up + decide + automatic replies to review (macOS: LedgerAttention.total) */
export function inboxCount(groups: readonly InboxGroup[]) {
  return groups.reduce((n, g) => n + g.items.length, 0);
}

/**
 * Triage keys, never while typing: Enter opens the session, A answers (or sends a correction to an automatic reply),
 * C confirms, E archives, S marks a stale session still active. A key an item does not take does nothing.
 */
export function inboxKeyAction(item: InboxItem, key: string): InboxAction | null {
  switch (key.toLowerCase()) {
    case "enter":
      return item.session ? "open" : null;
    case "a":
      return item.kind === "question" || item.kind === "autoQuestion" || item.kind === "autoPrompt" ? "answer" : null;
    case "c":
      return item.kind === "autoQuestion" || item.kind === "autoPrompt" || (item.kind === "session" && item.session.verdict === "confirm") ? "confirm" : null;
    case "e":
      return item.kind === "session" && item.session.verdict === "expirable" ? "archive" : null;
    case "s":
      return item.kind === "session" && item.session.verdict === "stale" ? "snooze" : null;
    default:
      return null;
  }
}

/** The next item after a step of ↑ (-1) or ↓ (+1), staying inside the list */
export function stepIndex(index: number, step: number, count: number): number {
  if (!count) return -1;
  if (index < 0) return step > 0 ? 0 : count - 1;
  return Math.min(count - 1, Math.max(0, index + step));
}
