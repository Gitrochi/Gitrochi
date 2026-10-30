import type { LedgerPendingPrompt, Ms } from "../model/types";

export type CountdownTone = "none" | "calm" | "soon" | "urgent" | "due";

export interface Countdown {
  /** "0:45", "12:03", "1:02:03"; empty when the prompt has no automatic answer */
  text: string;
  /** Milliseconds left (0 once due) */
  left: Ms;
  tone: CountdownTone;
}

const pad = (n: number) => String(n).padStart(2, "0");

/**
 * Time left before a waiting prompt is answered automatically. Seconds round up, so "0:01" shows until the deadline
 * itself; a deadline of 0 means no automatic answer. (macOS: LedgerCountdown.make)
 */
export function countdown(deadline: Ms, now: Ms): Countdown {
  if (!deadline) return { text: "", left: Infinity, tone: "none" };
  const left = Math.max(0, deadline - now);
  const total = Math.ceil(left / 1000);
  const h = Math.floor(total / 3600), m = Math.floor((total % 3600) / 60), s = total % 60;
  const text = h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${m}:${pad(s)}`;
  const tone: CountdownTone = left <= 0 ? "due" : left <= 10_000 ? "urgent" : left <= 30_000 ? "soon" : "calm";
  return { text, left, tone };
}

/** The backend's clock, estimated from the `now` of the last state and how long ago it was read */
export const serverNow = (stateNow: Ms, readAt: Ms, clientNow: Ms) => stateNow + Math.max(0, clientNow - readAt);

/** Waiting prompts, the one answered soonest first; prompts without an automatic answer go last */
export function waitingPrompts(prompts: readonly LedgerPendingPrompt[]): LedgerPendingPrompt[] {
  const due = (p: LedgerPendingPrompt) => p.deadline || Infinity;
  return prompts.filter((p) => p.state === "waiting").sort((a, b) => due(a) - due(b) || a.createdAt - b.createdAt || a.id - b.id);
}

/** Which answers a prompt offers: permission and plan prompts are allowed or denied, questions are answered */
export function promptActions(kind: LedgerPendingPrompt["kind"]): { reply: boolean; allow: boolean } {
  return kind === "permission" || kind === "exit_plan_mode" ? { reply: false, allow: true } : { reply: true, allow: false };
}

const text = (value: unknown) => (typeof value === "string" ? value.trim() : "");

/** The one line a prompt is about: its question, the command or tool it wants to run, or its plan */
export function promptSummary(prompt: LedgerPendingPrompt): string {
  const p = prompt.payload;
  return text(p.question) || text(p.command) || (text(p.tool) && `${text(p.tool)}${text(p.input) ? ` · ${text(p.input)}` : ""}`) || text(p.plan).split("\n")[0] || text(p.message);
}

/** The options an AskUserQuestion prompt offers, recommended first as the agent listed them */
export function promptOptions(prompt: LedgerPendingPrompt): string[] {
  const options = prompt.payload.options;
  return Array.isArray(options) ? options.map(text).filter(Boolean) : [];
}
