import type { LedgerQuestionOption } from "../model/types";

/** A pasted question preview; target project and session are always chosen in the app. */
export interface ChatGPTQuestion {
  text: string;
  options: LedgerQuestionOption[];
  multiSelect?: boolean;
  suggestedAnswer?: string;
}

const MAX_BYTES = 64 * 1024;
const MULTIPLE = "Use Paste reports for multiple questions.";
const INVALID_JSON = "Could not read the pasted JSON.";
const record = (value: unknown): Record<string, unknown> | null => value !== null && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : null;
const marked = (label: string) => /[(\[（【]\s*(?:recommended|recommend|suggested|추천|권장|추천안)\s*[)\]）】]\s*$/i.test(label);
const bullet = (line: string): string | null => /^[ \t]*(?:[-*+•]|\d+[.)])(?:[ \t]+|$)(.*?)[ \t]*$/.exec(line)?.[1] ?? null;

function requiredText(value: unknown): string {
  if (typeof value !== "string" || !value.trim()) throw new Error("Question text must be nonempty text.");
  return value.trim();
}

function optionalText(object: Record<string, unknown>, key: string): string | undefined {
  if (!(key in object)) return undefined;
  if (typeof object[key] !== "string") throw new Error("Question descriptions and suggestions must be text.");
  return object[key].trim();
}

function flag(object: Record<string, unknown>, key: string): boolean | undefined {
  if (!(key in object)) return undefined;
  if (typeof object[key] !== "boolean") throw new Error("Question flags must be true or false.");
  return object[key];
}

function option(value: unknown): LedgerQuestionOption {
  const object = typeof value === "string" ? { label: value } : record(value);
  if (!object || typeof object.label !== "string" || !object.label.trim()) throw new Error("Question option labels must be nonempty and distinct.");
  const label = object.label.trim(), description = optionalText(object, "description");
  const recommended = flag(object, "recommended") ?? (marked(label) || marked(description ?? "") ? true : undefined);
  return { label, ...(description !== undefined ? { description } : {}), ...(recommended !== undefined ? { recommended } : {}) };
}

function question(value: unknown): ChatGPTQuestion {
  if (typeof value === "string") return { text: requiredText(value), options: [] };
  const object = record(value);
  if (!object) throw new Error("Question text must be nonempty text.");
  if (("question" in object && object.question !== null) || ("questions" in object && (!Array.isArray(object.questions) || object.questions.length > 0))) throw new Error(MULTIPLE);
  const text = requiredText(object.text);
  if ("options" in object && !Array.isArray(object.options)) throw new Error("Question options must be an array.");
  const choices = ((object.options ?? []) as unknown[]).map(option);
  if (new Set(choices.map((choice) => choice.label.normalize("NFC"))).size !== choices.length) throw new Error("Question option labels must be nonempty and distinct.");
  const multiSelect = flag(object, "multiSelect"), suggestedAnswer = optionalText(object, "suggestedAnswer");
  return { text, options: choices, ...(multiSelect !== undefined ? { multiSelect } : {}), ...(suggestedAnswer !== undefined ? { suggestedAnswer } : {}) };
}

function single(value: unknown): ChatGPTQuestion {
  if (Array.isArray(value)) {
    if (value.length > 1) throw new Error(MULTIPLE);
    return question(value[0]);
  }
  const object = record(value);
  if (object && !("text" in object) && ("question" in object || "questions" in object)) {
    const entries = [
      ...("question" in object && object.question !== null ? [object.question] : []),
      ...("questions" in object ? Array.isArray(object.questions) ? object.questions : [object.questions] : []),
    ];
    if (entries.length > 1) throw new Error(MULTIPLE);
    if (typeof object.question === "string" && ("options" in object || "multiSelect" in object || "suggestedAnswer" in object)) {
      const form: Record<string, unknown> = { ...object, text: object.question };
      delete form.question;
      delete form.questions;
      return question(form);
    }
    return question(entries[0]);
  }
  return question(value);
}

/** Parse only explicitly pasted text; this function never reads a client or saves a report. */
export function parseChatGPTQuestion(raw: string): ChatGPTQuestion {
  if (new TextEncoder().encode(raw).length > MAX_BYTES) throw new Error("Pasted text is limited to 64 KiB.");
  let text = raw.trim();
  if (!text) throw new Error("Paste a question first.");
  let json = /^(?:\{|\[)/.test(text);
  if (/^```(?:ledger|json)?[ \t]*\r?\n/i.test(text)) {
    const fences = text.match(/^```(?:ledger|json)?[ \t]*$/gim) ?? [];
    if (fences.length > 2) throw new Error(MULTIPLE);
    const fenced = /^```(?:ledger|json)?[ \t]*\r?\n([\s\S]*?)\r?\n```[ \t]*$/i.exec(text);
    if (!fenced || fenced[1].includes("```")) throw new Error(INVALID_JSON);
    text = fenced[1].trim();
    json = true;
  }
  if (json) {
    let value: unknown;
    try { value = JSON.parse(text); } catch { throw new Error(INVALID_JSON); }
    return single(value);
  }
  const lines = text.split(/\r?\n/), blocks: { start: number; end: number; labels: string[] }[] = [];
  for (let index = 0; index < lines.length; index++) {
    const label = bullet(lines[index]);
    if (label === null) continue;
    const start = index, labels = [label];
    while (index + 1 < lines.length) {
      const next = bullet(lines[index + 1]);
      if (next === null) break;
      labels.push(next);
      index++;
    }
    blocks.push({ start, end: index + 1, labels });
  }
  if (blocks.length > 1) throw new Error(MULTIPLE);
  const block = blocks[0];
  if (!block || block.start === 0) return { text, options: [] };
  const body = [...lines.slice(0, block.start), ...lines.slice(block.end)].join("\n").trim();
  return question({ text: body, options: block.labels });
}
