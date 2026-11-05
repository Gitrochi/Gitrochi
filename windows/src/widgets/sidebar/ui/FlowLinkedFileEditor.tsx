import { FilePlus2, FolderOpen, RefreshCw } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { type FlowSourceFile, checkedFlowSource, flowEngine, portableSourcePath } from "@/entities/flow";
import { t } from "@/shared/i18n";
import { Button, CodeEditor, IconButton, Modal, Spinner } from "@/shared/ui";

/** Related files save independently, through the engine's boundary and fingerprint checks. */
export function FlowLinkedFileEditor({ repo, initialPath, activeFlowFile, pendingFiles = [], onClose }: { repo: string; initialPath: string; activeFlowFile: string; pendingFiles?: string[]; onClose: () => void }) {
  const [path, setPath] = useState(initialPath), [snapshot, setSnapshot] = useState<FlowSourceFile | null>(null), [draft, setDraft] = useState("");
  const [creating, setCreating] = useState(false);
  const [busy, setBusy] = useState(false), [error, setError] = useState(""), [saved, setSaved] = useState(false), [version, setVersion] = useState(0);
  const [pending, setPending] = useState<{ path?: string; create?: boolean; close?: boolean } | null>(null);
  const request = useRef(0);
  const dirty = snapshot !== null && (draft !== (snapshot.content ?? "") || !snapshot.exists);
  const load = async (target: string, create = false) => {
    if (!target.trim()) { setError(t("Enter a repository-relative file path.")); return; }
    try { target = portableSourcePath(target); } catch (reason) { setError(reason instanceof Error ? reason.message : String(reason)); return; }
    if (pendingFiles.some((file) => file.toLowerCase() === target.toLowerCase())) { setError(t("Save this flow before editing its imported source file.")); return; }
    if (target.toLowerCase() === activeFlowFile.toLowerCase()) { setError(t("Edit the active flow file in Code.")); return; }
    const ticket = ++request.current; setBusy(true); setError(""); setSaved(false);
    try {
      const result = checkedFlowSource(await flowEngine.sourceFile(repo, target.trim()), create);
      if (ticket !== request.current) return;
      if (create && result.exists) throw new Error(t("That file already exists. Open it instead."));
      if (!create && (result.content === null || !result.exists)) throw new Error(t("The file could not be opened."));
      setSnapshot(result); setCreating(create); setPath(result.path); setDraft(result.content ?? ""); setVersion((value) => value + 1);
    } catch (reason) { if (ticket === request.current) setError(reason instanceof Error ? reason.message : String(reason)); }
    finally { if (ticket === request.current) setBusy(false); }
  };
  useEffect(() => { if (initialPath) void load(initialPath); return () => { request.current++; }; }, []);
  const navigate = (next: { path?: string; create?: boolean; close?: boolean }) => {
    if (busy) return;
    if (dirty) setPending(next);
    else if (next.close) onClose();
    else void load(next.path ?? path, next.create);
  };
  const save = async () => {
    if (busy || !snapshot || !dirty) return;
    setBusy(true); setError(""); setSaved(false);
    try {
      const result = checkedFlowSource(await flowEngine.saveSourceFile(repo, snapshot.path, draft, snapshot.fingerprint, creating));
      if (!result.saved || result.content === null || !result.fingerprint) throw new Error(t("The file was not saved. Your draft is still available."));
      setSnapshot(result); setDraft(result.content); setCreating(false); setSaved(true);
    } catch (reason) { setError(reason instanceof Error ? reason.message : String(reason)); }
    finally { setBusy(false); }
  };
  return <>
    <Modal title={t("Edit repository file")} width={1040} onClose={() => navigate({ close: true })} footer={<>{busy && <Spinner size={12} />}<span className="flow-file-save-note">{t("File saves are independent of the flow draft. Canceling the flow editor keeps saved file changes.")}</span><span className="spacer" />{saved && <span className="flow-file-saved" role="status">{t("File saved")}</span>}<Button disabled={busy} onClick={() => navigate({ close: true })}>{t("Done")}</Button><Button kind="primary" disabled={busy || !snapshot || !dirty} onClick={() => void save()}>{t("Save file")}</Button></>}>
      <div className="flow-file-editor" data-flow-file-editor><div className="flow-file-path"><input className="mono" aria-label={t("Repository file path")} placeholder={t("e.g. scripts/check.sh or .gitch/blocks/check.yml")} value={path} disabled={busy} onChange={(event) => setPath(event.target.value)} onKeyDown={(event) => { if (event.key === "Enter") { event.preventDefault(); navigate({ path }); } }} /><Button size="small" disabled={busy} onClick={() => navigate({ path })}><FolderOpen size={13} />{t("Open file")}</Button><Button size="small" disabled={busy} onClick={() => navigate({ path, create: true })}><FilePlus2 size={13} />{t("New file")}</Button><IconButton small icon={<RefreshCw size={13} />} tip={t("Reload file")} disabled={busy || !snapshot?.exists} onClick={() => navigate({ path: snapshot?.path })} /></div>
      {snapshot ? <CodeEditor value={draft} onChange={(text) => { setDraft(text); setSaved(false); }} label={t("Repository file code")} fileName={snapshot.path} documentKey={`${repo}:${snapshot.path}:${version}`} onSave={() => void save()} readOnly={busy} /> : <div className="flow-empty">{busy ? <Spinner /> : <p>{t("Open an existing text file or choose New file. Paths stay inside this repository.")}</p>}</div>}
      {error && <p className="flow-file-error error-text" role="alert">{error}</p>}</div>
    </Modal>
    {pending && <Modal title={t("Discard changes to this file?")} onClose={() => setPending(null)} footer={<><Button onClick={() => setPending(null)}>{t("Keep editing")}</Button><Button kind="danger" onClick={() => { const next = pending; setPending(null); if (next.close) onClose(); else void load(next.path ?? path, next.create); }}>{t("Discard changes")}</Button></>}><p>{t("This file has unsaved edits. Save it or discard the draft before opening another file.")}</p></Modal>}
  </>;
}
