import { type Ref, useId, useImperativeHandle, useRef } from "react";
import { editAnswerDraft, emptyAnswerDraft, fillsSuggestion, selectAnswerOption, suggestedAnswerDraft, type AnswerDraft, type AnswerQuestion } from "@/entities/ledger";
import { keyLabel } from "@/shared/config";
import { t } from "@/shared/i18n";
import { Button, Spinner } from "@/shared/ui";
import "./ledger-answer-form.css";

/** One explicit confirmation sends the complete editable form. (macOS: LedgerQuestionForm) */
export function LedgerAnswerForm({ questions, drafts, onChange, onSubmit, onCancel, saving = false, disabled = false, autoFocus = false, submitLabel = "Send answer", deliveryHint = false, fieldRef }: {
  questions: readonly AnswerQuestion[];
  drafts: Readonly<Record<string, AnswerDraft>>;
  onChange: (id: string, value: AnswerDraft) => void;
  onSubmit: () => void;
  onCancel?: () => void;
  saving?: boolean;
  disabled?: boolean;
  autoFocus?: boolean;
  submitLabel?: string;
  deliveryHint?: boolean;
  fieldRef?: Ref<HTMLTextAreaElement>;
}) {
  const complete = questions.length > 0 && new Set(questions.map((question) => question.question)).size === questions.length && questions.every((question) => question.question && drafts[question.id]?.text.trim());
  const busy = saving || disabled;
  return (
    <div className="ledger-answer-form" onClick={(event) => event.stopPropagation()}>
      {questions.map((question, index) => <AnswerQuestionField key={question.id} question={question} draft={drafts[question.id] ?? emptyAnswerDraft()} onChange={(draft) => onChange(question.id, draft)} disabled={busy} autoFocus={autoFocus && index === 0} onSubmit={complete && !busy ? onSubmit : undefined} onCancel={onCancel} fieldRef={index === 0 ? fieldRef : undefined} />)}
      <div className="ledger-answer-form-bar">
        <span className="hint grow">{complete ? t("Enter adds a line · {0} saves", keyLabel("Ctrl+Enter")) : t("Answer every question before sending.")}</span>
        {onCancel && <Button size="small" disabled={saving} onClick={onCancel}>{t("Cancel")}</Button>}
        <Button size="small" kind="primary" disabled={!complete || busy} onClick={onSubmit}>
          {saving && <Spinner size={11} />}
          {t(submitLabel)}
        </Button>
      </div>
      {deliveryHint && <span className="hint">{t("The session reads it with its next report.")}</span>}
    </div>
  );
}

function AnswerQuestionField({ question, draft, onChange, disabled, autoFocus, onSubmit, onCancel, fieldRef }: {
  question: AnswerQuestion;
  draft: AnswerDraft;
  onChange: (draft: AnswerDraft) => void;
  disabled: boolean;
  autoFocus: boolean;
  onSubmit?: () => void;
  onCancel?: () => void;
  fieldRef?: Ref<HTMLTextAreaElement>;
}) {
  const id = useId(), field = useRef<HTMLTextAreaElement>(null);
  useImperativeHandle(fieldRef, () => field.current!, []);
  const fill = () => { onChange(suggestedAnswerDraft(question)); field.current?.focus(); };
  return (
    <fieldset className="ledger-answer-question" data-answer-question={question.id}>
      <legend>{question.header || question.question}</legend>
      {question.header && <div className="ledger-answer-question-text selectable">{question.question}</div>}
      {question.options.length > 0 && <>
        <div className="hint">{t(question.multiSelect ? "Choose one or more" : "Choose one")}</div>
        <div className="ledger-answer-choices">
          {question.options.map((option, index) => <label key={option.label} className="ledger-answer-choice">
            <input type={question.multiSelect ? "checkbox" : "radio"} name={id} value={option.label} checked={draft.selected.includes(option.label)} disabled={disabled} onChange={() => onChange(selectAnswerOption(question, draft, option.label))} aria-describedby={option.description ? `${id}-${index}` : undefined} />
            <span>
              <span className="ledger-answer-choice-label">{option.label}{option.recommended && !/\(recommended\)\s*$/i.test(option.label) && <span className="hint">{t("Recommended")}</span>}</span>
              {option.description && <span className="hint" id={`${id}-${index}`}>{option.description}</span>}
            </span>
          </label>)}
        </div>
      </>}
      {question.suggestedAnswer && <div className="ledger-answer-suggestion">
        <span className="hint grow selectable">{question.suggestedAnswer}</span>
        <Button size="small" disabled={disabled} onClick={fill}>{t("Use suggestion")}</Button>
        <span className="ledger-kbd" data-tip={t("Tab fills an empty answer. You can edit it before sending.")}>{t("Tab")}</span>
      </div>}
      <textarea ref={field} className="textarea" rows={2} value={draft.text} placeholder={t("Your answer…")} aria-label={t("Answer to {0}", question.question)} autoFocus={autoFocus} readOnly={disabled}
        onChange={(event) => onChange(editAnswerDraft(draft, event.target.value))}
        onKeyDown={(event) => {
          const composing = event.nativeEvent.isComposing || event.keyCode === 229;
          if (!disabled && fillsSuggestion({ ...event, isComposing: composing }, draft.text, question.suggestedAnswer)) {
            event.preventDefault();
            fill();
          } else if (!composing && !disabled && event.key === "Enter" && (event.ctrlKey || event.metaKey) && onSubmit) {
            event.preventDefault();
            onSubmit();
          } else if (!composing && !disabled && event.key === "Escape" && onCancel) {
            event.preventDefault();
            event.stopPropagation();
            onCancel();
          }
        }} />
      {question.options.length > 0 && <span className="hint">{t("Your answer can include a different choice or more detail.")}</span>}
    </fieldset>
  );
}
