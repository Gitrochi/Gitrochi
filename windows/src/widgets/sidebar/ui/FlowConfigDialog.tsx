import { Code2, FileUp, Workflow } from "lucide-react";
import { RefreshCw } from "@/shared/icons";
import { type DragEvent, useEffect, useRef, useState } from "react";
import { type FlowAttachment, type FlowBlock, type FlowConnection, type FlowDesignDiagnostic, type FlowDesignInspection, type FlowDocument, type FlowImportSource, type FlowStore, addCodeModule, addParallelFlowExample, checkedDesignYaml, composeDesignProposal, designFlowNames, flowConfigFiles, flowEngine, importedFlowName, listFlowConnections, readFlowImport, readWebFlowImport, saveFlowConfig, scriptFlowExample } from "@/entities/flow";
import { ipc } from "@/shared/api";
import { joinPath } from "@/shared/config";
import { t } from "@/shared/i18n";
import { Button, IconButton, Modal, Spinner } from "@/shared/ui";
import { FlowConnections } from "./FlowConnections";
import { FlowDesigner } from "./FlowDesigner";
import { FlowCodeWorkspace } from "./FlowCodeWorkspace";
import { FlowLinkedFileEditor } from "./FlowLinkedFileEditor";
import { FlowImportPreview } from "./FlowImportPreview";
import "./flow-designer.css";
import "./flow-code.css";

const message = (reason: unknown) => reason instanceof Error ? reason.message : String(reason);
interface ImportPreview { source: FlowImportSource; inspection: FlowDesignInspection; target: string }

/** Code is authoritative; module forms are an optional view of the same complete source. */
export function FlowConfigDialog({ flows, onClose, initialImport, initialFlow, initialNode }: { flows: FlowStore; onClose: () => void; initialImport?: FlowImportSource; initialFlow?: string; initialNode?: string }) {
  const [files, setFiles] = useState<string[]>([]);
  const [file, setFile] = useState(".gitch/flow.yml");
  const [original, setOriginal] = useState<string | null>(null);
  const [draft, setDraft] = useState("");
  const [document, setDocument] = useState<FlowDocument | null>(null);
  const [inspection, setInspection] = useState<FlowDesignInspection | null>(null);
  const [blocks, setBlocks] = useState<FlowBlock[]>([]);
  const [connections, setConnections] = useState<FlowConnection[]>([]);
  const [attachments, setAttachments] = useState<FlowAttachment[]>([]);
  const [visualChanged, setVisualChanged] = useState(false);
  const [tab, setTab] = useState<"modules" | "code">("code");
  const [activeFlow, setActiveFlow] = useState(initialFlow), [activeNode, setActiveNode] = useState(initialNode);
  const [linkedPath, setLinkedPath] = useState<string | null>(null), [codeWarnings, setCodeWarnings] = useState<FlowDesignDiagnostic[]>([]);
  const [loading, setLoading] = useState(true);
  const [checking, setChecking] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [diagnostics, setDiagnostics] = useState<FlowDesignDiagnostic[]>([]);
  const [replaceImport, setReplaceImport] = useState(false);
  const busy = useRef(false);
  const importSequence = useRef(0);
  const [discard, setDiscard] = useState(false);
  const [importPreview, setImportPreview] = useState<ImportPreview | null>(null);
  const [review, setReview] = useState<{ yaml: string; diagnostics: FlowDesignDiagnostic[] } | null>(null);
  const input = useRef<HTMLInputElement>(null);
  const dirty = draft !== (original ?? "") || visualChanged;
  const inspect = async (yaml: string, fileName: string) => {
    const result = await flowEngine.inspectDesign(yaml, flows.repo, fileName);
    setInspection(result); setDiagnostics(result.diagnostics);
    setDocument(result.format === "flow" && result.editable ? result.document : null);
    return result;
  };
  const load = async (next: string) => {
    busy.current = true;
    setLoading(true); setError(null); setFile(next); setImportPreview(null);
    try {
      const text = await ipc.readText(joinPath(flows.repo, next));
      const yaml = text ?? (await flowEngine.proposeInit(flows.repo).catch(() => null))?.yaml ?? scriptFlowExample;
      setOriginal(text); setDraft(yaml); setVisualChanged(false); setAttachments([]); setCodeWarnings([]);
      await inspect(yaml, next);
    } catch (reason) { setError(message(reason)); setDocument(null); }
    finally { busy.current = false; setLoading(false); }
  };
  const previewImport = async (source: FlowImportSource) => {
    if (busy.current) return;
    const ticket = ++importSequence.current;
    busy.current = true;
    setChecking(true); setError(null);
    try {
      const result = await flowEngine.inspectDesign(source.yaml, flows.repo, source.fileName);
      if (ticket === importSequence.current) setImportPreview({ source, inspection: result, target: importedFlowName(source.fileName) });
    } catch (reason) { setError(message(reason)); }
    finally { busy.current = false; setChecking(false); }
  };
  const refreshCatalogue = async () => {
    const [catalogue, configured] = await Promise.all([flowEngine.blocks(flows.repo), listFlowConnections(flows.repo)]);
    setBlocks(catalogue); setConnections(configured);
  };
  useEffect(() => {
    let stale = false;
    void Promise.all([flowConfigFiles(flows.repo), refreshCatalogue()]).then(async ([entries]) => {
      if (stale) return;
      setFiles(entries.length ? entries : [".gitch/flow.yml"]);
      let selectedFile = entries[0] ?? ".gitch/flow.yml";
      if (initialFlow) for (const entry of entries) {
        const text = await ipc.readText(joinPath(flows.repo, entry));
        if (text === null) continue;
        const inspected = await flowEngine.inspectDesign(text, flows.repo, entry);
        if (inspected.document && designFlowNames(inspected.document).includes(initialFlow)) { selectedFile = entry; break; }
      }
      if (stale) return;
      await load(selectedFile);
      if (initialImport && !stale) await previewImport(initialImport);
    }).catch((reason) => { if (!stale) { setError(message(reason)); setLoading(false); } });
    return () => { stale = true; };
  }, [flows.repo]);
  useEffect(() => {
    let disposed = false;
    let unlisten: (() => void) | undefined;
    void ipc.onFileDrop((paths) => {
      if (busy.current || loading) return;
      if (paths.length !== 1) { setError(t("Drop one workflow file at a time.")); return; }
      const ticket = ++importSequence.current;
      void readFlowImport(paths[0]).then((source) => { if (ticket === importSequence.current) return previewImport(source); }).catch((reason) => setError(message(reason)));
    }).then((stop) => { if (disposed) stop(); else unlisten = stop; }).catch(() => {});
    return () => { disposed = true; unlisten?.(); };
  }, [flows.repo, saving, checking, loading]);
  const importWebFile = async (selected: File | undefined) => {
    if (!selected || busy.current) return;
    const ticket = ++importSequence.current;
    if (selected.size > 2 * 1024 * 1024) { setError(t("Choose a UTF-8 workflow file smaller than 2 MB.")); return; }
    const source = await readWebFlowImport(selected);
    if (ticket === importSequence.current) await previewImport(source);
  };
  const pickImport = async () => {
    if (busy.current) return;
    try { const path = await ipc.pickFile(t("Import a workflow file"), flows.repo); if (path) await previewImport(await readFlowImport(path)); }
    catch { input.current?.click(); }
  };
  const drop = (event: DragEvent<HTMLDivElement>) => {
    event.preventDefault(); event.stopPropagation();
    if (busy.current) return;
    if (event.dataTransfer.files.length !== 1) { setError(t("Drop one workflow file at a time.")); return; }
    void importWebFile(event.dataTransfer.files[0]).catch((reason) => setError(message(reason)));
  };
  const useImport = async (confirmed = false) => {
    if (!importPreview || busy.current) return;
    if (dirty && !confirmed) { setReplaceImport(true); return; }
    busy.current = true; setChecking(true);
    try {
      const { target, inspection: imported } = importPreview;
      setError(null);
      if (!/^\.gitch\/flows\/[A-Za-z0-9][A-Za-z0-9_.-]*\.ya?ml$/.test(target)) { setError(t("Choose a new .gitch/flows/*.yml file.")); return; }
      if (await ipc.exists(joinPath(flows.repo, target))) { setError(t("That flow file already exists. Choose a new file name.")); return; }
      const proposed = imported.proposal;
      let yaml = proposed?.yaml ?? imported.yaml;
      let next = proposed?.document ?? imported.document;
      const sources: FlowAttachment[] = [];
      if (imported.format === "compose") {
        let attachment = importedFlowName(importPreview.source.fileName).replace(".gitch/flows/", ".gitch/imports/");
        const stem = attachment.replace(/\.ya?ml$/, "");
        let suffix = 2;
        while (await ipc.exists(joinPath(flows.repo, attachment))) attachment = `${stem}-${suffix++}.yml`;
        next = composeDesignProposal(imported, attachment);
        const rendered = await flowEngine.renderDesign(next, "", flows.repo);
        yaml = checkedDesignYaml(rendered);
        sources.push({ file: attachment, yaml: imported.yaml });
      }
      if (!next) return;
      setFile(target); setFiles((previous) => [...new Set([...previous, target])]); setOriginal(null); setDraft(yaml);
      setAttachments(sources); setDocument(next); setInspection({ ...imported, format: "flow", document: next, editable: true }); setVisualChanged(false); setDiagnostics(imported.diagnostics);
      setTab("code"); setImportPreview(null);
    } finally { busy.current = false; setChecking(false); }
  };
  const changeTab = async (next: "modules" | "code") => {
    if (tab === next || busy.current) return;
    busy.current = true;
    setChecking(true); setError(null);
    try {
      if (next === "code" && document && visualChanged) {
        const rendered = await flowEngine.renderDesign(document, draft, flows.repo);
        setDiagnostics(rendered.diagnostics);
        const yaml = checkedDesignYaml(rendered);
        setDraft(yaml); setVisualChanged(false); setCodeWarnings(rendered.diagnostics);
      } else if (next === "modules") { await inspect(draft, file); setVisualChanged(false); }
      setTab(next);
    } catch (reason) { setError(message(reason)); }
    finally { busy.current = false; setChecking(false); }
  };
  const close = () => { if (saving || checking) return; if (dirty) setDiscard(true); else onClose(); };
  const commit = async (yaml: string) => {
    busy.current = true;
    setSaving(true); setError(null);
    try { await saveFlowConfig(flows.repo, file, original, yaml, attachments); await flows.refresh(); onClose(); }
    catch (reason) { setError(message(reason)); await flows.refresh(); }
    finally { busy.current = false; setSaving(false); }
  };
  const save = async () => {
    if (busy.current) return;
    busy.current = true;
    setChecking(true); setError(null);
    try {
      if (tab === "modules" && document) {
        const rendered = await flowEngine.renderDesign(document, draft, flows.repo);
        setDiagnostics(rendered.diagnostics);
        const yaml = checkedDesignYaml(rendered);
        if (rendered.formattingChanged) { setReview({ yaml, diagnostics: rendered.diagnostics }); return; }
        await commit(yaml);
      } else await commit(draft);
    } catch (reason) { setError(message(reason)); }
    finally { busy.current = false; setChecking(false); }
  };
  const openLinkedFile = (path: string) => {
    if (attachments.some((attachment) => attachment.file === path)) { setError(t("Save this flow before editing its imported source file.")); return; }
    setLinkedPath(path);
  };
  const insertSource = async (transform: (sourceDocument: FlowDocument) => { document: FlowDocument; flow: string; node?: string }) => {
    if (busy.current) return;
    busy.current = true; setChecking(true); setError(null);
    try {
      const current = await flowEngine.inspectDesign(draft, flows.repo, file);
      if (!current.document || !current.editable || current.format !== "flow" || current.diagnostics.some((diagnostic) => diagnostic.severity === "error")) throw new Error(t("Fix the source before inserting module code."));
      const next = transform(current.document);
      const rendered = await flowEngine.renderDesign(next.document, draft, flows.repo);
      const yaml = checkedDesignYaml(rendered);
      setDraft(yaml); setDocument(next.document); setVisualChanged(false); setCodeWarnings(rendered.diagnostics); setActiveFlow(next.flow); setActiveNode(next.node);
    } catch (reason) { setError(message(reason)); }
    finally { busy.current = false; setChecking(false); }
  };
  const insertModule = (flow: string, block: FlowBlock) => insertSource((sourceDocument) => { const next = addCodeModule(sourceDocument, flow, block); return { document: next.document, flow, node: next.id }; });
  const insertExample = () => insertSource((sourceDocument) => { const next = addParallelFlowExample(sourceDocument); return { document: next.document, flow: next.flow, node: "prepare" }; });
  return <>
    <Modal title={t("Flow editor")} width={1280} onClose={close} footer={<>{(saving || checking) && <Spinner size={12} />}<span className="flow-save-note">{t("Changed commands require review before the next run.")}</span><span className="spacer" /><Button disabled={saving || checking} onClick={close}>{t("Cancel")}</Button><Button kind="primary" disabled={loading || saving || checking || !dirty || !!importPreview || !draft.trim() && !visualChanged} onClick={() => void save()}>{t("Validate and save")}</Button></>}>
      <div className="flow-config" onDragOver={(event) => { event.preventDefault(); event.stopPropagation(); }} onDrop={drop}>
        <fieldset className="flow-authoring-lock" disabled={checking || saving || loading}>
        <div className="flow-config-toolbar"><select aria-label={t("Flow configuration file")} value={file} disabled={saving || loading || dirty} onChange={(event) => void load(event.target.value)}>{files.map((entry) => <option key={entry}>{entry}</option>)}</select><span className="spacer" /><FlowConnections repo={flows.repo} /><IconButton small icon={<RefreshCw size={13} />} tip={t("Refresh connections and modules")} onClick={() => void refreshCatalogue().catch((reason) => setError(message(reason)))} /><Button size="small" disabled={saving || checking} onClick={() => void pickImport()}><FileUp size={13} />{t("Import file…")}</Button><input ref={input} type="file" hidden accept=".yml,.yaml,.groovy,Jenkinsfile" onChange={(event) => { void importWebFile(event.target.files?.[0]).catch((reason) => setError(message(reason))); event.target.value = ""; }} /></div>
        {importPreview ? <FlowImportPreview key={importPreview.source.fileName} inspection={importPreview.inspection} fileName={importPreview.source.fileName} target={importPreview.target} onTarget={(target) => setImportPreview({ ...importPreview, target })} onUse={() => void useImport().catch((reason) => setError(message(reason)))} onCancel={() => setImportPreview(null)} /> : <>
          {attachments.length > 0 && <p className="flow-import-attachment-note">{t("The original Compose source will be saved separately. Review relative paths, environment files and volumes at its new location.")}</p>}
          <div className="flow-config-tabs" role="tablist" aria-label={t("Flow editor")}><button role="tab" aria-selected={tab === "code"} onClick={() => void changeTab("code")} disabled={checking || saving}><Code2 size={14} />{t("Code")}</button><button role="tab" aria-selected={tab === "modules"} onClick={() => void changeTab("modules")} disabled={checking || saving}><Workflow size={14} />{t("Modules")}</button><span className="spacer" /><small>{t("Drop a workflow file here to preview its modules.")}</small></div>
          {loading ? <div className="flow-empty"><Spinner /></div> : tab === "code" ? <FlowCodeWorkspace key={file} repo={flows.repo} file={file} source={draft} inspection={inspection} blocks={blocks} initialFlow={activeFlow} initialNode={activeNode} onChange={(text) => { setDraft(text); setVisualChanged(false); setCodeWarnings([]); }} onInspection={(result) => { if (busy.current) return; setInspection(result); setDiagnostics(result.diagnostics); if (result.format === "flow" && result.editable && result.document && !result.diagnostics.some((diagnostic) => diagnostic.severity === "error")) setDocument(result.document); }} onSelection={(flow, node) => { setActiveFlow(flow); setActiveNode(node); }} onInsertModule={insertModule} onInsertExample={insertExample} onSave={() => void save()} onOpenFile={openLinkedFile} /> : document && inspection?.editable ? <FlowDesigner initialFlow={activeFlow} initialNode={activeNode} document={document} blocks={blocks} connections={connections} onChange={(next) => { setDocument(next); setVisualChanged(true); }} /> : <div className="flow-empty"><p>{t("This source cannot be edited as modules. Review its diagnostics or edit Code.")}</p><Button onClick={() => void changeTab("code")}>{t("Code")}</Button></div>}
          {[...codeWarnings, ...diagnostics].length > 0 && <div className="flow-design-diagnostics">{[...codeWarnings, ...diagnostics].filter((diagnostic, index, all) => all.findIndex((entry) => entry.code === diagnostic.code && entry.message === diagnostic.message) === index).map((diagnostic, index) => <p key={index} className={`flow-design-diagnostic ${diagnostic.severity}`}>{t(diagnostic.message)}</p>)}</div>}
        </>}
        </fieldset>
        {error && <div role="alert" className="error-text flow-config-error">{error}</div>}
      </div>
    </Modal>
    {linkedPath !== null && <FlowLinkedFileEditor repo={flows.repo} initialPath={linkedPath} activeFlowFile={file} pendingFiles={attachments.map((attachment) => attachment.file)} onClose={() => setLinkedPath(null)} />}
    {review && <Modal title={t("Review formatting changes")} width={840} onClose={() => setReview(null)} footer={<><Button onClick={() => setReview(null)}>{t("Back to editor")}</Button><Button kind="primary" disabled={saving} onClick={() => { const yaml = review.yaml; setReview(null); void commit(yaml); }}>{t("Save reviewed changes")}</Button></>}><p>{t("The module changes preserve the complete configuration, but YAML formatting and comments may change. Review the generated file before saving.")}</p>{review.diagnostics.map((diagnostic, index) => <p className="muted" key={index}>{t(diagnostic.message)}</p>)}<pre className="flow-generated-yaml mono">{review.yaml}</pre></Modal>}
    {replaceImport && <Modal title={t("Replace the current draft?")} onClose={() => setReplaceImport(false)} footer={<><Button onClick={() => setReplaceImport(false)}>{t("Keep editing")}</Button><Button kind="danger" onClick={() => { setReplaceImport(false); void useImport(true).catch((reason) => setError(message(reason))); }}>{t("Replace draft")}</Button></>}><p>{t("The current unsaved changes will be replaced by the imported modules. The source file stays unchanged.")}</p></Modal>}
    {discard && <Modal title={t("Discard unsaved changes?")} onClose={() => setDiscard(false)} footer={<><Button onClick={() => setDiscard(false)}>{t("Keep editing")}</Button><Button kind="danger" onClick={onClose}>{t("Discard changes")}</Button></>}><p>{t("Your script changes have not been saved.")}</p></Modal>}
  </>;
}
