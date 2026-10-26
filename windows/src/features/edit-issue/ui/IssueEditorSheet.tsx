import { useState } from "react";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { describe } from "@/shared/platform";
import { Button, Modal, Spinner } from "@/shared/ui";

/** A new issue, or an edit of one (number): title and a Markdown description (macOS: IssueEditorSheet.swift) */
export function IssueEditorSheet({ store, close, number, title: initialTitle, body: initialBody }: { store: RepoStore; close: () => void; number?: number; title: string; body: string }) {
  const [title, setTitle] = useState(initialTitle);
  const [body, setBody] = useState(initialBody);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const save = async () => {
    if (!title.trim() || saving) return;
    setSaving(true); setError(null);
    try { await store.saveIssue(title, body, number); close(); }
    catch (e) { setError(describe(e)); setSaving(false); }
  };
  return (
    <Modal
      title={number ? t("Edit issue #{0}", number) : t("New issue")}
      width={560}
      onClose={() => { if (!saving) close(); }}
      footer={<>
        {saving && <Spinner size={14} />}
        <span className="spacer" />
        <Button disabled={saving} onClick={close}>{t("Cancel")}</Button>
        <Button kind="primary" disabled={!title.trim() || saving} onClick={() => void save()}>{t("Save")}</Button>
      </>}
    >
      <input className="input" autoFocus aria-label={t("Title")} placeholder={t("Title")} value={title} disabled={saving} onChange={(e) => setTitle(e.target.value)} />
      <label className="col hint" style={{ gap: 4 }}>
        {t("Description (Markdown)")}
        <textarea
          className="textarea"
          rows={10}
          aria-label={t("Description")}
          value={body}
          disabled={saving}
          onChange={(e) => setBody(e.target.value)}
          onKeyDown={(e) => { if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) { e.preventDefault(); void save(); } }}
        />
      </label>
      {error && <div role="alert" className="error-text selectable">{error}</div>}
    </Modal>
  );
}
