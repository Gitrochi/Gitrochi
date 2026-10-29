import { useEffect, useRef, useState } from "react";
import { ExternalLink, RefreshCw } from "lucide-react";
import { externalEditors, describe, type ExternalEditor, type ExternalEditorID } from "@/shared/platform";
import { t } from "@/shared/i18n";
import { Button, Spinner } from "@/shared/ui";

export type RepositoryEditorSource = Pick<typeof externalEditors, "list" | "open">;

/** External apps always receive the current working copy, never revision-preview bytes. */
export function CodeExternalEditors({ repo, file, source = externalEditors }: { repo: string; file: string | null; source?: RepositoryEditorSource }) {
  const [editors, setEditors] = useState<ExternalEditor[]>([]), [loading, setLoading] = useState(false), [busy, setBusy] = useState(false), [error, setError] = useState<string | null>(null);
  const host = useRef<HTMLDetailsElement>(null), generation = useRef(0);
  useEffect(() => { ++generation.current; setError(null); setBusy(false); setLoading(false); if (host.current) host.current.open = false; return () => { ++generation.current; }; }, [repo, file, source]);
  const refresh = async () => {
    const token = generation.current; setLoading(true); setError(null);
    try { const values = await source.list(); if (token === generation.current) setEditors(values); }
    catch (cause) { if (token === generation.current) setError(describe(cause)); }
    finally { if (token === generation.current) setLoading(false); }
  };
  const open = async (editor: ExternalEditorID, path?: string) => {
    const token = generation.current; setBusy(true); setError(null);
    try { await source.open(repo, editor, path); if (token === generation.current && host.current) host.current.open = false; }
    catch (cause) { if (token === generation.current) setError(describe(cause)); }
    finally { if (token === generation.current) setBusy(false); }
  };
  const choices = (isFile: boolean) => editors.map((editor) => <button key={editor.id} type="button" disabled={busy || !editor.available || (!isFile && !editor.supportsFolders)} onClick={() => void open(editor.id, isFile ? file ?? undefined : undefined)}><span>{editor.id === "system" ? t("System default") : editor.name}</span>{!editor.available ? <small>{t("Not installed")}</small> : !isFile && !editor.supportsFolders ? <small>{t("Files only")}</small> : null}</button>);
  return <details ref={host} className="code-external-editors" onToggle={(event) => { if (event.currentTarget.open && !editors.length && !loading) void refresh(); }}><summary><ExternalLink size={13}/>{t("Open with…")}</summary><div className="code-editor-menu"><strong>{t("Working copy")}</strong><p>{t("External editors open the current local file, not the revision preview.")}</p>{loading ? <div className="row"><Spinner/>{t("Loading…")}</div> : <>{file && <div className="code-editor-section"><span>{t("Open file in…")}</span>{choices(true)}</div>}<div className="code-editor-section"><span>{t("Open repository in…")}</span>{choices(false)}</div></>}{error && <p className="error-text" role="alert">{error}</p>}<Button size="small" disabled={loading || busy} onClick={() => void refresh()}><RefreshCw size={12}/>{t("Refresh applications")}</Button></div></details>;
}
