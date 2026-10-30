import { ipc } from "@/shared/api";
import type { LedgerMethod, LedgerMethods } from "../model/types";

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
 * Where Ledger calls go: the crate through the Tauri command `ledger_call` once it exists, the demo until then.
 * (macOS: Services/LedgerBackend.swift)
 */
export interface LedgerBackend {
  /** "demo" makes the page say that it shows demo data */
  readonly kind: "demo" | "native";
  call<M extends LedgerMethod>(method: M, args: LedgerMethods[M]["args"]): Promise<LedgerMethods[M]["result"]>;
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

/** The crate behind the Tauri command (wave 2 adds `ledger_call` to src-tauri) */
export const nativeLedgerBackend: LedgerBackend = {
  kind: "native",
  async call<M extends LedgerMethod>(method: M, args: LedgerMethods[M]["args"]) {
    try {
      return ledgerResult<LedgerMethods[M]["result"]>(await ipc.ledgerCall(method, { ...args }));
    } catch (error) {
      throw ledgerFailure(error);
    }
  },
};
