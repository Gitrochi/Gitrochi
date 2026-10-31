import { ipc } from "@/shared/api";
import type { LedgerHumanRequest, LedgerMethod, LedgerMethods, Ms } from "../model/types";

/** An error the backend answered with `{"error": {code, message}}` (macOS: LedgerBackendError) */
export class LedgerError extends Error {
  constructor(
    readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "LedgerError";
  }
}

/**
 * Where Ledger calls go: the crate through the Tauri command `ledger_call`, or the demo (GITROCHI_LEDGER_DEMO, the
 * tests and the self-test). (macOS: Services/LedgerBackend.swift)
 */
export interface LedgerBackend {
  /** "demo" makes the page say that it shows demo data */
  readonly kind: "demo" | "native";
  call<M extends LedgerMethod>(method: M, args: LedgerMethods[M]["args"]): Promise<LedgerMethods[M]["result"]>;
  /** Whether a person's operation can be carried out at `now`; Undo is offered only for what can be taken back */
  canRun?(request: LedgerHumanRequest, now: Ms): boolean;
}

const isRecord = (value: unknown): value is Record<string, unknown> => !!value && typeof value === "object" && !Array.isArray(value);

/** An answer, or the LedgerError it carries */
export function ledgerResult<T>(value: unknown): T {
  if (isRecord(value) && isRecord(value.error)) throw new LedgerError(String(value.error.code ?? "ERROR"), String(value.error.message ?? ""));
  return value as T;
}

/** A rejected call as a LedgerError; the command's error string may itself be the `{error}` JSON */
export function ledgerFailure(error: unknown): LedgerError {
  if (error instanceof LedgerError) return error;
  const text = error instanceof Error ? error.message : String(error);
  try {
    ledgerResult(JSON.parse(text));
  } catch (parsed) {
    if (parsed instanceof LedgerError) return parsed;
  }
  return new LedgerError("BACKEND", text);
}

/**
 * The core takes a snooze only when it ends in the future, so ending one — what Undo sends after Still active when no
 * snooze ran before (`until` 0 or a time that has passed) — has no call there yet.
 */
export const nativeCanRun = (request: LedgerHumanRequest, now: Ms) => !(request.action === "snooze" && request.until !== undefined && request.until <= now);

/**
 * The crate behind the Tauri command: the contract's methods and arguments as they are, answered as the core answers
 * them, with `{"error"}` and a failed command both as a LedgerError.
 */
export const nativeLedgerBackend: LedgerBackend = {
  kind: "native",
  async call<M extends LedgerMethod>(method: M, args: LedgerMethods[M]["args"]) {
    try {
      return ledgerResult<LedgerMethods[M]["result"]>(await ipc.ledgerCall(method, { ...args }));
    } catch (error) {
      throw ledgerFailure(error);
    }
  },
  canRun: nativeCanRun,
};
