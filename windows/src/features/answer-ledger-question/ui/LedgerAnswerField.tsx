import { type Ref, useState } from "react";
import { keyLabel } from "@/shared/config";
import { t } from "@/shared/i18n";
import { Button, Spinner } from "@/shared/ui";
import "./ledger-answer-field.css";

/**
 * Answers a question, or a correction to an automatic reply, in place: Enter is a new line and Ctrl+Enter saves.
 * The text stays when saving fails, and clears once it is saved. The session reads the answer with its next report.
 * (macOS: Views/Ledger/LedgerAnswerField.swift)
 */
export function LedgerAnswerField({ onSubmit, placeholder, submitLabel = "Save answer", onCancel, autoFocus, fieldRef, label }: {
  onSubmit: (text: string) => Promise<boolean>;
  placeholder: string;
  submitLabel?: string;
  onCancel?: () => void;
  autoFocus?: boolean;
  fieldRef?: Ref<HTMLTextAreaElement>;
  /** Accessible name of the field */
  label: string;
}) {
  const [text, setText] = useState("");
  const [saving, setSaving] = useState(false);
  const save = async () => {
    if (!text.trim() || saving) return;
    setSaving(true);
    try {
      if (await onSubmit(text)) setText("");
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
        readOnly={saving}
        onChange={(e) => setText(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) {
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
        <Button size="small" kind="primary" disabled={!text.trim() || saving} onClick={() => void save()} tip={`${t(submitLabel)}|${t("The session reads it with its next report.")}|Ctrl+Enter`}>
          {saving && <Spinner size={11} />}
          {t(submitLabel)}
        </Button>
      </div>
    </div>
  );
}
