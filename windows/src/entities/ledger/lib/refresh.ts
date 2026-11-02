import type { LedgerState } from "../model/types";

/** Recompute time-based verdicts at least once a minute, without reloading on every revision poll. */
export const LEDGER_STATE_MAX_AGE_MS = 60_000;

/** Uses elapsed client time on the backend's clock; a snooze expires on the next regular poll. */
export function ledgerRefreshDue(state: Pick<LedgerState, "now" | "sessions"> | null, readAt: number, now: number): boolean {
  if (!state || now < readAt || now - readAt >= LEDGER_STATE_MAX_AGE_MS) return true;
  const serverNow = state.now + now - readAt;
  return state.sessions.some((s) => s.snoozeUntil != null && s.snoozeUntil > state.now && s.snoozeUntil <= serverNow);
}
