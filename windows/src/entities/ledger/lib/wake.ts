import type { LedgerSession, LedgerSettings, LedgerWakeAgents, Ms } from "../model/types";

/** The core's default: off, and a Stop hook that would wait the longest its entry allows (crates/gitrochi-ledger/src/wake.rs) */
export const DEFAULT_WAKE: LedgerWakeAgents = { enabled: false, waitSec: 300 };
export const WAKE_MIN_SEC = 10;
export const WAKE_MAX_SEC = 300;

/** `wakeAgents` as stored, or the default */
export const wakeSetting = (settings: Pick<LedgerSettings, "wakeAgents">): LedgerWakeAgents => settings.wakeAgents ?? DEFAULT_WAKE;

/**
 * Whether the session's agent waits to be woken right now, on the core's clock: an answer or message sent now reaches it
 * at once instead of with its next report. (macOS: LedgerWake in LedgerPresentation.swift)
 */
export const agentWaits = (session: Pick<LedgerSession, "wakeUntil">, now: Ms): boolean => (session.wakeUntil ?? 0) > now;
