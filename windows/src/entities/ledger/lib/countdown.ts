import type { LedgerPendingPrompt, LedgerPromptAnswer, Ms } from "../model/types";

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
const record = (value: unknown): Record<string, unknown> => (value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : {});

/**
 * The one line a prompt is about. Payloads follow auto-continue's PromptPayload (`question`, `text`, `tool:
 * {name, summary}`, `options`, `questions`, `proposed`); older shapes (`command`, `plan`) still read.
 */
export function promptSummary(prompt: LedgerPendingPrompt): string {
  const p = prompt.payload, tool = record(p.tool);
  return text(p.question) || text(tool.summary) || text(p.command) || (text(tool.name) || text(p.tool)) || text(p.text).split("\n")[0] || text(p.plan).split("\n")[0] || text(p.message);
}

export interface PromptOption {
  label: string;
  recommended: boolean;
}

/** The choices a prompt offers — its own options, else the first AskUserQuestion question's — recommended first */
export function promptOptions(prompt: LedgerPendingPrompt): PromptOption[] {
  const p = prompt.payload;
  const questions = Array.isArray(p.questions) ? p.questions.map(record) : [];
  const raw = Array.isArray(p.options) && p.options.length ? p.options : questions[0] && Array.isArray(questions[0].options) ? questions[0].options : [];
  const options = raw.map((o): PromptOption => (typeof o === "string" ? { label: o.trim(), recommended: false } : { label: text(record(o).label), recommended: record(o).recommended === true })).filter((o) => o.label);
  return [...options.filter((o) => o.recommended), ...options.filter((o) => !o.recommended)];
}

/** An AskUserQuestion prompt is answered per question ({answers: {question: label}}); everything else with text */
export function promptChoice(prompt: LedgerPendingPrompt, label: string): LedgerPromptAnswer {
  const questions = Array.isArray(prompt.payload.questions) ? prompt.payload.questions.map(record) : [];
  const question = text(questions[0]?.question);
  return prompt.kind === "ask_user_question" && question ? { answers: { [question]: label } } : { text: label };
}

export type AnswerKind = "text" | "allow" | "deny" | "approve" | "release" | "hold" | "unknown";

/**
 * An answer in words: what auto-continue proposes or sent (`{type: "reply" | "answers" | "allow" | "approve_plan"}`)
 * or what a person sent (LedgerPromptAnswer). The kind is for the screen to translate; `text` is the agent-facing text.
 */
export function describeAnswer(value: unknown): { kind: AnswerKind; text: string } {
  const a = record(value);
  const answers = Object.values(record(a.answers)).map(text).filter(Boolean).join(", ");
  if (a.type === "allow" || a.decision === "allow") return { kind: "allow", text: "" };
  if (a.decision === "deny" || a.type === "deny") return { kind: "deny", text: text(a.message) };
  if (a.type === "approve_plan") return { kind: "approve", text: "" };
  if (a.release === true) return { kind: "release", text: "" };
  if (a.hold === true) return { kind: "hold", text: "" };
  if (answers) return { kind: "text", text: answers };
  if (text(a.text)) return { kind: "text", text: text(a.text) };
  return { kind: "unknown", text: "" };
}
