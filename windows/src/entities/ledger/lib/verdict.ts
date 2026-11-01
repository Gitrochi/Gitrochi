import type { LedgerSession, LedgerStatus, LedgerVerdict, Ms } from "../model/types";

/** Hours without a report after which a live session counts as stale (the core's `stale_hours`) */
export const STALE_HOURS = 72;
const HOUR = 3_600_000;

export interface VerdictInput {
  status: LedgerStatus;
  openQuestions: number;
  lastAt: Ms;
  ackAt?: Ms;
  archivedAt?: Ms;
  snoozeUntil?: Ms;
}

/**
 * The contract's verdict, first match wins: archived > needs_human > finished (expirable once confirmed, else confirm)
 * > shelved > done → pending_merge > no report for 72 h → stale > active. "Still active" holds off stale until snoozeUntil.
 * The core computes it; the demo backend uses the same rule. (macOS: LedgerVerdict.compute)
 */
export function computeVerdict(s: VerdictInput, now: Ms, staleHours = STALE_HOURS): LedgerVerdict {
  if (s.archivedAt) return "archived";
  if (s.openQuestions > 0) return "needs_human";
  if (s.status === "merged" || s.status === "closed" || s.status === "dropped") return s.ackAt ? "expirable" : "confirm";
  if (s.status === "shelved") return "shelved";
  if (s.status === "done") return "pending_merge";
  if (now - s.lastAt > staleHours * HOUR && !(s.snoozeUntil && s.snoozeUntil > now)) return "stale";
  return "active";
}

/** The order verdicts are shown in (chips, Board, Inbox): what needs a person first, in the Inbox's group order */
export const verdictDisplayOrder: readonly LedgerVerdict[] = ["needs_human", "confirm", "expirable", "pending_merge", "stale", "active", "shelved", "archived"];

/** Icon names the screen maps to its icon set (lucide on Windows, SF Symbols on macOS) */
export type VerdictIcon = "question" | "merge" | "confirm" | "archive" | "stale" | "active" | "shelved" | "archived";

export interface VerdictLook {
  /** English label; the screen translates it */
  label: string;
  /** The design's status tone, independent of the operating system accent. */
  tone: "waiting" | "failed" | "passed" | "info" | "neutral";
  icon: VerdictIcon;
  /** What a person does about it, for tooltips */
  hint: string;
}

const looks: Record<LedgerVerdict, VerdictLook> = {
  needs_human: { label: "Needs you", tone: "waiting", icon: "question", hint: "Answer or dismiss its questions; the session reads the answer with its next report." },
  pending_merge: { label: "Merge pending", tone: "info", icon: "merge", hint: "The work is done: mark it merged, close it or drop it." },
  confirm: { label: "To confirm", tone: "info", icon: "confirm", hint: "The agent finished it. Confirm the outcome, then clean up the conversation." },
  expirable: { label: "Ready to clean up", tone: "passed", icon: "archive", hint: "Finished and confirmed. Clean it up once the conversation is closed." },
  stale: { label: "Stale", tone: "failed", icon: "stale", hint: "No report for 72 hours. Check the conversation, then close it or mark it still active." },
  active: { label: "In progress", tone: "neutral", icon: "active", hint: "Work in progress." },
  shelved: { label: "Shelved", tone: "neutral", icon: "shelved", hint: "Paused research or documents, kept for later. Never turns stale." },
  archived: { label: "Cleaned up", tone: "neutral", icon: "archived", hint: "The conversation is cleaned up. Hidden unless you show cleaned-up sessions." },
};

/**
 * How a verdict looks: label, status tone and icon. Archiving reads "Clean up" on screen, so it stays apart
 * from shelving in every language. (macOS: LedgerVerdict.look)
 */
export const verdictLook = (verdict: LedgerVerdict): VerdictLook => looks[verdict];

/** Board order: verdict display order, then the most recent activity first, then the ID */
export function compareSessions(a: LedgerSession, b: LedgerSession): number {
  return verdictDisplayOrder.indexOf(a.verdict) - verdictDisplayOrder.indexOf(b.verdict) || b.lastAt - a.lastAt || a.id.localeCompare(b.id);
}

/** Finished without a decision still pending: the session's line in the graph ends */
export const isFinished = (status: LedgerStatus) => status === "merged" || status === "closed" || status === "dropped";
