import { FolderOpen, Globe } from "@/shared/icons";
import { useEffect, useId, useRef, useState } from "react";
import type { LedgerBrowserStatus, LedgerStore } from "@/entities/ledger";
import { ipc } from "@/shared/api";
import { env, isWindows, joinPath } from "@/shared/config";
import { t } from "@/shared/i18n";
import { Button, Modal, Spinner } from "@/shared/ui";
import "./ledger-browser-sheet.css";

/** Host registration is reviewed here; a conversation is paired separately in the extension. */
export function LedgerBrowserSheet({ store, onClose }: { store: LedgerStore; onClose: () => void }) {
  const root = useRef<HTMLDivElement>(null);
  const titleId = useId();
  const [writing, setWriting] = useState(false);
  const [status, setStatus] = useState<LedgerBrowserStatus | null>(null);
  const [extensionId, setExtensionId] = useState("");
  const [busy, setBusy] = useState(false);
  const [confirming, setConfirming] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const valid = /^[a-p]{32}$/.test(extensionId);
  const folder = env.resourceDir ? joinPath(env.resourceDir, "chatgpt-ledger") : "";
  const hostPath = env.resourceDir ? joinPath(env.resourceDir, isWindows() ? "gitrochi-ledger-browser.exe" : "gitrochi-ledger-browser") : "";
  const refresh = async () => {
    setBusy(true); setError(null);
    try {
      const next = await store.backend.call("browser_status", {});
      setStatus(next);
      if (next.extensionId) setExtensionId((current) => current || next.extensionId!);
    } catch (cause) { setError(t(cause instanceof Error ? cause.message : String(cause))); }
    finally { setBusy(false); }
  };
  useEffect(() => { void refresh(); }, [store]);
  useEffect(() => {
    const dialog = root.current?.closest<HTMLElement>("[role='dialog'],[role='alertdialog']");
    const title = dialog?.querySelector<HTMLElement>(".modal-title");
    if (!dialog || !title) return;
    title.id = titleId;
    dialog.setAttribute("aria-labelledby", titleId);
    dialog.setAttribute("aria-modal", "true");
    dialog.setAttribute("role", confirming ? "alertdialog" : "dialog");
    const trap = (event: KeyboardEvent) => {
      if (event.key !== "Tab" || event.defaultPrevented || event.isComposing) return;
      const controls = [...dialog.querySelectorAll<HTMLElement>("button:not(:disabled),input:not(:disabled),summary")].filter((element) => element.tabIndex >= 0 && element.getClientRects().length);
      if (event.shiftKey && document.activeElement === controls[0]) { event.preventDefault(); controls.at(-1)?.focus(); }
      else if (!event.shiftKey && document.activeElement === controls.at(-1)) { event.preventDefault(); controls[0]?.focus(); }
    };
    dialog.addEventListener("keydown", trap);
    return () => dialog.removeEventListener("keydown", trap);
  }, [titleId, confirming]);
  const install = async () => {
    if (!valid || !hostPath || busy) return;
    setBusy(true); setWriting(true); setError(null);
    try { setStatus(await store.backend.call("browser_install", { extensionId, hostPath })); setConfirming(false); }
    catch (cause) { setError(t(cause instanceof Error ? cause.message : String(cause))); }
    finally { setBusy(false); setWriting(false); }
  };
  const remove = async () => {
    if (busy) return;
    setBusy(true); setWriting(true); setError(null);
    try { setStatus(await store.backend.call("browser_remove", {})); }
    catch (cause) { setError(t(cause instanceof Error ? cause.message : String(cause))); }
    finally { setBusy(false); setWriting(false); }
  };
  const showFolder = async () => {
    if (!folder) { setError(t("The bundled browser extension is missing.")); return; }
    try { await ipc.reveal(folder); } catch { setError(t("The bundled browser extension is missing.")); }
  };
  return <Modal title={t(confirming ? "Allow browser connection?" : "ChatGPT browser extension")} width={660} onClose={() => { if (!writing) { if (confirming) setConfirming(false); else onClose(); } }} footer={<>
    {!confirming && <Button disabled={busy} onClick={() => void refresh()}>{t("Refresh")}</Button>}
    <span className="spacer" />
    <Button disabled={writing} onClick={() => confirming ? setConfirming(false) : onClose()}>{t(confirming ? "Cancel" : "Close")}</Button>
    {confirming && <Button kind="primary" disabled={busy || !valid || !hostPath} onClick={() => void install()}>{busy && <Spinner size={12} />}{t("Allow browser connection")}</Button>}
  </>}>
    <div className="ledger-browser-setup" ref={root}>
      {confirming ? <>
        <p>{t("This grants the selected extension access to Ledger project and session names and allows it to add questions and accepted Tab drafts.")}</p>
        <code className="selectable">{extensionId}</code>
        <p className="hint">{t("Only the conversation you select in the extension is synced. Other tabs and conversations are not read.")}</p>
      </> : <>
        <p>{t("Completed ChatGPT questions and choices appear in Ledger. A draft accepted with Tab can be offered as an editable answer.")}</p>
        <p className="hint">{t("The native ChatGPT app and unaccepted predictions are not read.")}</p>
        <ol>
          <li><p>{t("In Chrome at chrome://extensions, enable Developer mode and choose Load unpacked. Select this folder, then enter the extension ID here.")}</p><Button disabled={!folder || busy} onClick={() => void showFolder()}><FolderOpen size={14} />{t("Open extension folder")}</Button></li>
          <li><label className="col"><span>{t("Extension ID")}</span><input className="input" value={extensionId} autoCapitalize="none" autoCorrect="off" spellCheck={false} aria-label={t("Extension ID")} onChange={(event) => setExtensionId(event.target.value.trim())} readOnly={busy} /></label><span className="hint">{t("Enter the 32-letter extension ID shown by Chrome.")}</span><Button kind="primary" disabled={!valid || !hostPath || busy || !status} onClick={() => setConfirming(true)}>{t("Allow browser connection")}</Button></li>
          <li><p>{t("Installation allows this extension to connect locally. Pair a conversation from its popup to start syncing.")}</p></li>
        </ol>
        <p className="hint">{t("Only the conversation you select in the extension is synced. Other tabs and conversations are not read.")}</p>
        <p className="hint">{t("Answers are saved in Ledger. They are not sent back to ChatGPT.")}</p>
        {busy && <Spinner size={14} />}
        {status && <section className="ledger-browser-status" role="status"><div><Globe size={15} /><strong>{t(status.installed ? "Browser host installed" : "Browser host not installed")}</strong></div>
          <details><summary>{t("Connection details")}</summary><code className="selectable">{status.hostName}</code><code className="selectable">{status.manifestPath}</code>{status.hostPath && <code className="selectable">{status.hostPath}</code>}</details>
          {status.installed && <Button disabled={busy} onClick={() => void remove()}>{t("Remove browser connection")}</Button>}
        </section>}
        {!hostPath && <span className="hint">{t("The bundled browser host is missing. Rebuild or reinstall Gitrochi.")}</span>}
      </>}
      {error && <div className="error-text selectable" role="alert">{error}</div>}
    </div>
  </Modal>;
}
