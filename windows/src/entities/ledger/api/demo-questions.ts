import type { LedgerQuestion, LedgerQuestionOption } from "../model/types";
import { LedgerError } from "./backend";

type QuestionFields = Pick<LedgerQuestion, "text" | "options" | "multiSelect" | "suggestedAnswer">;
const invalid = (message: string): never => { throw new LedgerError("INVALID_ARGUMENT", message); };
const record = (value: unknown): Record<string, unknown> | null => value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : null;
const marked = (value: string) => /[([（【]\s*recommended(?:\s*:[^\])）】]*)?\s*[\])）】]/i.test(value);

function optionalText(raw: Record<string, unknown>, key: string): string | undefined {
  if (raw[key] == null) return undefined;
  if (typeof raw[key] !== "string") return invalid(`Question ${key} must be text`);
  return raw[key].trim() || undefined;
}

function parse(value: unknown): QuestionFields {
  if (typeof value === "string") return value.trim() ? { text: value.trim() } : invalid("Question text is empty");
  const raw = record(value);
  if (!raw) return invalid("A question must be text or an object with text");
  const text = optionalText(raw, "text") || invalid("Question text is empty");
  if (raw.multiSelect !== undefined && typeof raw.multiSelect !== "boolean") return invalid("Question multiSelect must be true or false");
  if (raw.options !== undefined && !Array.isArray(raw.options)) return invalid("Question options must be an array");
  const options: LedgerQuestionOption[] = [];
  for (const option of (raw.options as unknown[] | undefined) ?? []) {
    const item = typeof option === "string" ? { label: option } : record(option);
    if (!item) return invalid("Question options must have a label");
    const label = optionalText(item, "label") || invalid("Question option label is empty");
    if (options.some((previous) => previous.label === label)) return invalid("Question option labels must be distinct");
    if (item.recommended !== undefined && typeof item.recommended !== "boolean") return invalid("Question recommended must be true or false");
    const description = optionalText(item, "description");
    options.push({ label, ...(description ? { description } : {}), recommended: typeof item.recommended === "boolean" ? item.recommended : marked(label) || marked(description ?? "") });
  }
  const suggestedAnswer = optionalText(raw, "suggestedAnswer");
  return { text, ...(options.length ? { options } : {}), ...(raw.multiSelect ? { multiSelect: true } : {}), ...(suggestedAnswer ? { suggestedAnswer } : {}) };
}

/** Mirrors the core's additive reported-question metadata and summary fallback. */
export function demoReportQuestions(report: Record<string, unknown>): QuestionFields[] {
  const list = report.questions;
  const questions = list == null ? [] : (Array.isArray(list) ? list : [list])
    .filter((value) => !(typeof value === "string" && !value.trim()))
    .map((value) => parse(typeof value === "number" && Array.isArray(list) ? String(value) : value));
  if (report.event === "question" && (report.question != null || !questions.length)) {
    const explicit = report.question ?? report.summary;
    questions.unshift(parse(explicit));
  }
  return questions;
}
