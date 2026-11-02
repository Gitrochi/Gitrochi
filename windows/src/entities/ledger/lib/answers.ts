import type { LedgerPendingPrompt, LedgerPromptAnswer, LedgerQuestion, LedgerQuestionOption } from "../model/types";
import { promptSummary } from "./countdown";

export interface AnswerOption extends LedgerQuestionOption {
  recommended: boolean;
}

export interface AnswerQuestion {
  id: string;
  question: string;
  header?: string;
  multiSelect: boolean;
  options: AnswerOption[];
  suggestedAnswer?: string;
  suggestionLabel?: string;
  localOnly?: boolean;
}

export interface AnswerDraft {
  text: string;
  selected: string[];
}

const text = (value: unknown) => typeof value === "string" ? value.trim() : "";
const record = (value: unknown): Record<string, unknown> => value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
const options = (value: unknown): AnswerOption[] => !Array.isArray(value) ? [] : value.map((item) => {
  const raw = typeof item === "string" ? { label: item } : record(item);
  const label = text(raw.label), description = text(raw.description);
  return { label, ...(description ? { description } : {}), recommended: typeof raw.recommended === "boolean" ? raw.recommended : /\(recommended\)\s*$/i.test(label) };
}).filter((option, index, all) => option.label && all.findIndex((other) => other.label === option.label) === index);

const recommendation = (choices: readonly AnswerOption[], multiSelect: boolean) => {
  const recommended = choices.filter((option) => option.recommended);
  return (multiSelect ? recommended : recommended.slice(0, 1)).map((option) => option.label).join(", ");
};

/** Every question keeps its own choices and suggestion; no first-choice default. (macOS: LedgerQuestionForm) */
export function promptAnswerQuestions(prompt: LedgerPendingPrompt): AnswerQuestion[] {
  const payload = prompt.payload, proposed = record(payload.proposed);
  if (prompt.kind === "ask_user_question" && Array.isArray(payload.questions) && payload.questions.length) {
    const proposedAnswers = record(proposed.answers);
    return payload.questions.map((value, index) => {
      const raw = record(value), question = text(raw.question), choices = options(raw.options), multiSelect = raw.multiSelect === true;
      const suggestedAnswer = text(raw.suggestedAnswer) || text(proposedAnswers[question]) || recommendation(choices, multiSelect);
      return { id: String(index), question, header: text(raw.header) || undefined, options: choices, multiSelect, suggestedAnswer: suggestedAnswer || undefined };
    });
  }
  const choices = options(payload.options), multiSelect = payload.multiSelect === true;
  const suggestedAnswer = text(payload.suggestedAnswer) || text(proposed.text) || recommendation(choices, multiSelect);
  return [{ id: "0", question: promptSummary(prompt), options: choices, multiSelect, suggestedAnswer: suggestedAnswer || undefined }];
}

/** Reported questions use the same editor while keeping the human-answer delivery route. */
export function reportedAnswerQuestion(question: LedgerQuestion): AnswerQuestion {
  const choices = options(question.options), multiSelect = question.multiSelect === true;
  const browserDraft = typeof question.browserDraft === "string" && question.browserDraft.trim() ? question.browserDraft : undefined;
  return { id: String(question.id), question: question.text, options: choices, multiSelect,
    suggestedAnswer: browserDraft ?? (text(question.suggestedAnswer) || recommendation(choices, multiSelect) || undefined),
    ...(browserDraft ? { suggestionLabel: "Browser draft accepted with Tab" } : {}),
    ...(question.browserSourceUrl ? { localOnly: true } : {}) };
}

export const emptyAnswerDraft = (): AnswerDraft => ({ text: "", selected: [] });

/** Selecting fills an editable draft; a person's edits remain the answer that is sent. */
export function selectAnswerOption(question: AnswerQuestion, draft: AnswerDraft, label: string): AnswerDraft {
  if (!question.options.some((option) => option.label === label)) return draft;
  const selected = question.multiSelect
    ? question.options.filter((option) => option.label === label ? !draft.selected.includes(label) : draft.selected.includes(option.label)).map((option) => option.label)
    : [label];
  return { selected, text: selected.join(", ") };
}

/** An edited answer only retains selections when it still equals their composed text. */
export function editAnswerDraft(draft: AnswerDraft, value: string): AnswerDraft {
  return { text: value, selected: value === draft.selected.join(", ") ? draft.selected : [] };
}

/** Filling a suggestion never submits it, and marks only exact matching choices. */
export function suggestedAnswerDraft(question: AnswerQuestion): AnswerDraft {
  const value = question.suggestedAnswer ?? "";
  const exact = question.options.filter((option) => option.label === value).map((option) => option.label);
  const selected = exact.length || !question.multiSelect ? exact
    : question.options.filter((option) => value.split(", ").includes(option.label)).map((option) => option.label);
  return { text: value, selected: selected.join(", ") === value ? selected : [] };
}

/** Empty means untouched: Tab must not replace whitespace, composition or reverse navigation. */
export function fillsSuggestion(key: { key: string; shiftKey?: boolean; ctrlKey?: boolean; metaKey?: boolean; altKey?: boolean; isComposing?: boolean }, value: string, suggestion?: string): boolean {
  return key.key === "Tab" && !key.shiftKey && !key.ctrlKey && !key.metaKey && !key.altKey && !key.isComposing && value === "" && !!suggestion;
}

/** Ask replies are keyed by every question; stop replies retain their text shape. */
export function promptDraftAnswer(prompt: LedgerPendingPrompt, questions: readonly AnswerQuestion[], drafts: Readonly<Record<string, AnswerDraft>>): LedgerPromptAnswer | null {
  if (!questions.length || questions.some((question) => !question.question || !drafts[question.id]?.text.trim())) return null;
  if (prompt.kind === "ask_user_question") {
    if (new Set(questions.map((question) => question.question)).size !== questions.length) return null;
    return { answers: Object.fromEntries(questions.map((question) => [question.question, drafts[question.id].text.trim()])) };
  }
  return { text: drafts[questions[0].id].text.trim() };
}
