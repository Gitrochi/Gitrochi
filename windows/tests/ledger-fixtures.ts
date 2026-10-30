import type { LedgerPendingPrompt, LedgerQuestion, LedgerSession } from "@/entities/ledger";

/** Contract objects for the Ledger tests: neutral values, overridden per case */
export const session = (over: Partial<LedgerSession> = {}): LedgerSession => ({
  id: "S1031-01", project: "atlas", title: "Session", kind: "decision", role: "decision", status: "active", verdict: "active",
  touches: [], related: [], links: {}, color: 1, createdAt: 0, lastAt: 0, openQuestions: 0, ...over,
});

export const question = (over: Partial<LedgerQuestion> = {}): LedgerQuestion => ({ id: 1, sessionId: "S1031-01", text: "Which one?", state: "open", createdAt: 0, ...over });

export const prompt = (over: Partial<LedgerPendingPrompt> = {}): LedgerPendingPrompt => ({ id: 1, kind: "stop_question", payload: {}, createdAt: 0, deadline: 1, state: "waiting", ...over });
