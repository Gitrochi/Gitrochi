import { useEffect, useState } from "react";
import { type FlowStore, flowConfigFiles, flowEngine, saveFlowConfig, scriptFlowExample } from "@/entities/flow";
import { ipc } from "@/shared/api";
import { joinPath } from "@/shared/config";
import { t } from "@/shared/i18n";
import { Button, Modal, Spinner } from "@/shared/ui";

/** Edits original YAML without translating it into a lossy form or running commands. */
export function FlowConfigDialog({ flows, onClose }: { flows: FlowStore; onClose: () => void }) {
  const [files, setFiles] = useState<string[]>([]);
  const [file, setFile] = useState(".gitch/flow.yml");
  const [original, setOriginal] = useState<string | null>(null);
  const [draft, setDraft] = useState("");
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [discard, setDiscard] = useState(false);
  const dirty = draft !== (original ?? "");
  const load = async (next: string) => {
    setLoading(true); setError(null); setFile(next);
    try {
      const text = await ipc.readText(joinPath(flows.repo, next));
      setOriginal(text);
      if (text !== null) setDraft(text);
      else {
        const proposal = await flowEngine.proposeInit(flows.repo).catch(() => null);
        setDraft(proposal?.yaml || scriptFlowExample);
      }
    } catch (reason) { setError(reason instanceof Error ? reason.message : String(reason)); }
    finally { setLoading(false); }
  };
  useEffect(() => {
    let stale = false;
    void flowConfigFiles(flows.repo).then((entries) => { if (!stale) { setFiles(entries.length ? entries : [".gitch/flow.yml"]); void load(entries[0] ?? ".gitch/flow.yml"); } }).catch((reason) => { if (!stale) { setError(String(reason)); setLoading(false); } });
    return () => { stale = true; };
  }, [flows.repo]);
  const close = () => { if (saving) return; if (dirty) setDiscard(true); else onClose(); };
  const save = async () => {
    setSaving(true); setError(null);
    try { await saveFlowConfig(flows.repo, file, original, draft); await flows.refresh(); onClose(); }
    catch (reason) { setError(reason instanceof Error ? reason.message : String(reason)); await flows.refresh(); }
    finally { setSaving(false); }
  };
  return <>
    <Modal title={t("Configure scripts")} width={860} onClose={close} footer={<>{saving && <Spinner size={12} />}<span className="spacer" /><Button disabled={saving} onClick={close}>{t("Cancel")}</Button><Button kind="primary" disabled={loading || saving || !dirty || !draft.trim()} onClick={() => void save()}>{t("Validate and save")}</Button></>}>
      <div className="flow-config"><p className="muted">{t("Connect script steps with needs. Saving checks the configuration; scripts run only when you start a flow.")}</p><div className="row" style={{ gap: 8 }}><select aria-label={t("Flow configuration file")} value={file} disabled={saving || loading || (dirty && original !== null)} onChange={(event) => void load(event.target.value)}>{files.map((entry) => <option key={entry}>{entry}</option>)}</select><span className="spacer" /><Button disabled={saving || loading} onClick={() => setDraft((value) => value + "\n# Script step example (add under a flow's nodes):\n#   check:\n#     needs: [prepare]\n#     run: |\n#       npm test\n")}>{t("Insert script example")}</Button></div>
        {loading ? <div className="flow-empty"><Spinner /></div> : <textarea className="flow-config-editor mono" aria-label={t("Flow YAML")} spellCheck={false} value={draft} disabled={saving} onChange={(event) => setDraft(event.target.value)} />}
        {error && <div role="alert" className="error-text flow-config-error">{error}</div>}<span className="muted">{t("Changed commands require review before the next run.")}</span>
      </div>
    </Modal>
    {discard && <Modal title={t("Discard unsaved changes?")} onClose={() => setDiscard(false)} footer={<><Button onClick={() => setDiscard(false)}>{t("Keep editing")}</Button><Button kind="danger" onClick={onClose}>{t("Discard changes")}</Button></>}><p>{t("Your script changes have not been saved.")}</p></Modal>}
  </>;
}
