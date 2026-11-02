import { useEffect, useState } from "react";
import type { LedgerStore } from "@/entities/ledger";
import { t } from "@/shared/i18n";
import { Button, Markdown, Modal } from "@/shared/ui";
import "./ledger-notebook.css";

interface Note {
  id: number;
  title: string;
  body: string;
  pinned: boolean;
  createdAt: number;
  updatedAt: number;
}
type Pending = { kind: "select"; note: Note } | { kind: "new" | "close" | "delete" | "reload" };

/** A private Markdown notebook; drafts survive failed or conflicting saves. (macOS: LedgerNotebookSheet) */
export function LedgerNotebook({ store, onClose }: { store: LedgerStore; onClose: () => void }) {
  const [notes, setNotes] = useState<Note[]>([]);
  const [selected, setSelected] = useState<Note | null>(null);
  const [title, setTitle] = useState("");
  const [body, setBody] = useState("");
  const [pinned, setPinned] = useState(false);
  const [query, setQuery] = useState("");
  const [preview, setPreview] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [pending, setPending] = useState<Pending | null>(null);
  const dirty = title !== (selected?.title ?? "") || body !== (selected?.body ?? "") || pinned !== (selected?.pinned ?? false);

  const select = (note: Note | null) => {
    setSelected(note);
    setTitle(note?.title ?? "");
    setBody(note?.body ?? "");
    setPinned(note?.pinned ?? false);
    setError(null);
  };
  const refresh = async () => {
    const result = await store.backend.call("notebook", { action: "list" }) as { notes: Note[] };
    setNotes(result.notes);
    return result.notes;
  };
  useEffect(() => {
    let alive = true;
    setBusy(true);
    void store.backend.call("notebook", { action: "list" }).then((result) => {
      if (!alive) return;
      const rows = (result as { notes: Note[] }).notes;
      setNotes(rows);
      select(rows[0] ?? null);
    }).catch((e: unknown) => { if (alive) setError(e instanceof Error ? e.message : String(e)); })
      .finally(() => { if (alive) setBusy(false); });
    return () => { alive = false; };
  }, [store]);

  const run = async (action: Pending) => {
    setPending(null);
    if (action.kind === "close") { onClose(); return; }
    if (action.kind === "new") { select(null); return; }
    if (action.kind === "select") { select(action.note); return; }
    if (!selected) return;
    setBusy(true);
    setError(null);
    try {
      if (action.kind === "delete") {
        await store.backend.call("notebook", { action: "delete", id: selected.id, expectedUpdatedAt: selected.updatedAt });
        select((await refresh())[0] ?? null);
      } else {
        const result = await store.backend.call("notebook", { action: "get", id: selected.id }) as { note: Note };
        select(result.note);
        await refresh();
      }
    } catch (e) { setError(e instanceof Error ? e.message : String(e)); }
    finally { setBusy(false); }
  };
  const request = (action: Pending) => {
    if (busy) return;
    if (action.kind === "select" && action.note.id === selected?.id) return;
    if (action.kind === "delete" || dirty) setPending(action);
    else void run(action);
  };
  const save = async () => {
    setBusy(true);
    setError(null);
    try {
      const result = await store.backend.call("notebook", {
        action: "save", title, body, pinned,
        ...(selected ? { id: selected.id, expectedUpdatedAt: selected.updatedAt } : {}),
      }) as { note: Note };
      select(result.note);
      await refresh();
    } catch (e) { setError(e instanceof Error ? e.message : String(e)); }
    finally { setBusy(false); }
  };
  const needle = query.trim().normalize("NFC").toLocaleLowerCase();
  const visible = notes.filter((n) => `${n.title}\n${n.body}`.toLocaleLowerCase().includes(needle));

  return <>
    <Modal title={t("Notebook")} width={980} onClose={() => request({ kind: "close" })} footer={<>
      {selected && <Button kind="danger" disabled={busy} onClick={() => request({ kind: "delete" })}>{t("Delete note…")}</Button>}
      <span className="ledger-notebook-footer-space" />
      <Button disabled={busy} onClick={() => request({ kind: "close" })}>{t("Close")}</Button>
      <Button kind={busy || !dirty || !title.trim() ? undefined : "primary"} disabled={busy || !dirty || !title.trim()} onClick={() => void save()}>{t("Save")}</Button>
    </>}>
      <p className="ledger-notebook-caption">{t("Personal notes stay in your notebook and are never sent to agents.")}</p>
      <div className="ledger-notebook">
        <aside className="ledger-notebook-list">
          <div className="ledger-notebook-list-tools">
            <input className="input" aria-label={t("Search notes")} placeholder={t("Search notes")} value={query} onChange={(e) => setQuery(e.target.value)} />
            <Button disabled={busy} onClick={() => request({ kind: "new" })}>{t("New note")}</Button>
          </div>
          <div className="ledger-notebook-rows" role="list" aria-label={t("Notes")}>
            {visible.map((note) => <button key={note.id} role="listitem" className={selected?.id === note.id ? "selected" : ""} disabled={busy} onClick={() => request({ kind: "select", note })}>
              <span className="ledger-notebook-row-title">{note.pinned && <span aria-label={t("Pinned")}>◆ </span>}{note.title}</span>
              <span className="ledger-notebook-row-body">{note.body.split("\n").find((line) => line.trim()) || t("Empty note")}</span>
            </button>)}
            {!visible.length && <div className="ledger-notebook-empty">{query ? t("No notes match your search.") : t("No notes yet. Write your first note.")}</div>}
          </div>
        </aside>
        <section className="ledger-notebook-editor" aria-label={t("Note editor")}>
          <input className="input" aria-label={t("Note title")} placeholder={t("Note title")} maxLength={500} value={title} disabled={busy} onChange={(e) => setTitle(e.target.value)} />
          <div className="ledger-notebook-controls">
            <label><input type="checkbox" checked={pinned} disabled={busy} onChange={(e) => setPinned(e.target.checked)} />{t("Pin note")}</label>
            <label><input type="checkbox" checked={preview} onChange={(e) => setPreview(e.target.checked)} />{t("Preview Markdown")}</label>
            {selected && <Button disabled={busy} onClick={() => request({ kind: "reload" })}>{t("Reload note")}</Button>}
          </div>
          {preview ? <div className="ledger-notebook-preview"><Markdown text={body || t("Empty note")} /></div>
            : <textarea className="input ledger-notebook-body" aria-label={t("Note text")} placeholder={t("Write a note in Markdown…")} maxLength={200000} value={body} disabled={busy} onChange={(e) => setBody(e.target.value)} />}
          {!title.trim() && <p className="ledger-notebook-caption">{t("Give this note a title before saving.")}</p>}
          {error && <div role="alert" className="ledger-notebook-error">{error}</div>}
        </section>
      </div>
    </Modal>
    {pending && <Modal title={pending.kind === "delete" ? t("Delete this note?") : t("Discard unsaved changes?")} onClose={() => setPending(null)} footer={<>
      <Button onClick={() => setPending(null)}>{t("Cancel")}</Button>
      <Button kind={pending.kind === "delete" ? "danger" : "primary"} onClick={() => void run(pending)}>{pending.kind === "delete" ? t("Delete") : t("Discard changes")}</Button>
    </>}><p>{pending.kind === "delete" ? t("This removes the note permanently.") : t("Your draft will be replaced. Save it first to keep your changes.")}</p></Modal>}
  </>;
}
