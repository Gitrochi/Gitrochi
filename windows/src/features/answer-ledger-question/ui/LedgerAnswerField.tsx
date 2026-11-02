import { type Ref, useState } from "react";
import { emptyAnswerDraft, reportedAnswerQuestion, type LedgerQuestion } from "@/entities/ledger";
import { ipc } from "@/shared/api";
import { keyLabel } from "@/shared/config";
import { t } from "@/shared/i18n";
import { Button, Spinner } from "@/shared/ui";
import { LedgerAnswerForm } from "./LedgerAnswerForm";
import "./ledger-answer-field.css";

/**
 * Answers a question, or a correction to an automatic reply, in place: Enter is a new line and Ctrl+Enter saves.
 * The text stays when saving fails, and clears once it is saved. The session reads the answer with its next report.
 * (macOS: Views/Ledger/LedgerAnswerField.swift)
 */
interface AnswerFieldProps {
  onSubmit: (text: string) => Promise<boolean>;
  placeholder: string;
  submitLabel?: string;
  onCancel?: () => void;
  autoFocus?: boolean;
  fieldRef?: Ref<HTMLTextAreaElement>;
  /** Accessible name of the field */
  label: string;
  question?: LedgerQuestion;
  disabled?: boolean;
  initialText?: string;
  onDraftChange?: (text: string) => void;
}

export function LedgerAnswerField(props: AnswerFieldProps) {
  return props.question && (props.question.options !== undefined || props.question.suggestedAnswer !== undefined || props.question.browserDraft !== undefined || props.question.multiSelect)
    ? <StructuredAnswerField {...props} question={props.question} />
    : <PlainAnswerField {...props} />;
}

function StructuredAnswerField({ question, onSubmit, onCancel, autoFocus, fieldRef, disabled, initialText, onDraftChange }: AnswerFieldProps & { question: LedgerQuestion }) {
  const [draft, setDraft] = useState(() => ({ ...emptyAnswerDraft(), text: initialText ?? "" }));
  const [saving, setSaving] = useState(false);
  const item = reportedAnswerQuestion(question);
  const save = async () => {
    if (!draft.text.trim() || saving || disabled) return;
    setSaving(true);
    try { if (await onSubmit(draft.text)) { setDraft(emptyAnswerDraft()); onDraftChange?.(""); } } finally { setSaving(false); }
  };
  let source: string | undefined;
  try { const url = new URL(question.browserSourceUrl ?? ""); if (url.protocol === "https:" && url.hostname === "chatgpt.com" && !url.username && !url.password && !url.port) source = url.href; } catch { /* A source label never opens an unvalidated destination. */ }
  return <>
    {item.localOnly && <div className="ledger-answer-browser-source"><span className="hint">{t("Answers are saved in Ledger. They are not sent back to ChatGPT.")}</span>{source && <Button size="small" onClick={() => void ipc.openUrl(source!)}>{t("Source conversation")}</Button>}</div>}
    <LedgerAnswerForm questions={[item]} drafts={{ [item.id]: draft }} onChange={(_, value) => { setDraft(value); onDraftChange?.(value.text); }} onSubmit={() => void save()} onCancel={onCancel} autoFocus={autoFocus} fieldRef={fieldRef} disabled={disabled} saving={saving} submitLabel={item.localOnly ? "Save answer" : "Send answer"} deliveryHint={!item.localOnly} />
  </>;
}

function PlainAnswerField({ onSubmit, placeholder, submitLabel = "Save answer", onCancel, autoFocus, fieldRef, label, disabled, initialText, onDraftChange }: AnswerFieldProps) {
  const [text, setText] = useState(initialText ?? "");
  const [saving, setSaving] = useState(false);
  const save = async () => {
    if (!text.trim() || saving || disabled) return;
    setSaving(true);
    try {
      if (await onSubmit(text)) { setText(""); onDraftChange?.(""); }
    } finally {
      setSaving(false);
    }
  };
  const shortcut = keyLabel("Ctrl+Enter");
  return (
    <div className="ledger-answer" onClick={(e) => e.stopPropagation()}>
      <textarea
        ref={fieldRef}
        className="textarea"
        rows={2}
        value={text}
        placeholder={placeholder}
        aria-label={label}
        autoFocus={autoFocus}
        // read-only rather than disabled: a disabled field loses focus, and a failed save should leave the person in it
        readOnly={saving || disabled}
        onChange={(e) => { setText(e.target.value); onDraftChange?.(e.target.value); }}
        onKeyDown={(e) => {
          if (!e.nativeEvent.isComposing && e.keyCode !== 229 && e.key === "Enter" && (e.ctrlKey || e.metaKey)) {
            e.preventDefault();
            void save();
          } else if (e.key === "Escape" && onCancel) {
            e.preventDefault();
            e.stopPropagation();
            onCancel();
          }
        }}
      />
      <div className="ledger-answer-bar">
        <span className="hint">{t("Enter adds a line · {0} saves", shortcut)}</span>
        {onCancel && <Button size="small" onClick={onCancel}>{t("Cancel")}</Button>}
        <Button size="small" kind="primary" disabled={!text.trim() || saving || disabled} onClick={() => void save()} tip={`${t(submitLabel)}|${t("The session reads it with its next report.")}|Ctrl+Enter`}>
          {saving && <Spinner size={11} />}
          {t(submitLabel)}
        </Button>
      </div>
    </div>
  );
}
