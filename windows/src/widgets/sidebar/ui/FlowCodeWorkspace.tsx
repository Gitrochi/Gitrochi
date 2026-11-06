import { Code2, FileCode2, FilePlus2 } from "lucide-react";
import { Plus, Search } from "@/shared/icons";
import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { type FlowBlock, type FlowDesignInspection, type FlowDocument, type FlowModule, designFlowNames, designModules, flowEngine, flowModuleSourceLine, relatedFlowFiles } from "@/entities/flow";
import { t } from "@/shared/i18n";
import { Button, CodeEditor, Modal, SourceSplit, Spinner } from "@/shared/ui";
import { FlowBlockEffects } from "./FlowBlockForm";
import { FlowGraph } from "./FlowGraph";
import { FlowBlockIcon, flowBlockKind } from "./FlowState";

interface Props {
  repo: string; file: string; source: string; inspection: FlowDesignInspection | null; blocks: FlowBlock[]; initialFlow?: string; initialNode?: string;
  onChange: (source: string) => void; onInspection: (inspection: FlowDesignInspection) => void; onSelection: (flow: string, node?: string) => void;
  onInsertModule: (flow: string, block: FlowBlock) => Promise<void>; onInsertExample: () => Promise<void>; onSave: () => void; onOpenFile: (path: string) => void;
}

/** Source remains authoritative; readable snapshots drive a live diagram without drawing connections. */
export function FlowCodeWorkspace({ repo, file, source, inspection: initial, blocks, initialFlow, initialNode, onChange, onInspection, onSelection, onInsertModule, onInsertExample, onSave, onOpenFile }: Props) {
  const host = useRef<HTMLDivElement>(null), [layout, setLayout] = useState<"wide" | "compact" | "narrow">("wide");
  const [current, setCurrent] = useState(initial), [lastDocument, setLastDocument] = useState<FlowDocument | null>(initial?.document ?? null), [pending, setPending] = useState(false), [error, setError] = useState("");
  const [chosenFlow, setChosenFlow] = useState(initialFlow ?? ""), [chosenNode, setChosenNode] = useState(initialNode ?? ""), [catalogue, setCatalogue] = useState(false), [search, setSearch] = useState("");
  const [jump, setJump] = useState<{ line: number; request: number } | null>(null);
  const initialJump = useRef<string | null>(null);
  const generation = useRef(0), report = useRef(onInspection); report.current = onInspection;
  useLayoutEffect(() => {
    const element = host.current;
    if (!element) return;
    // Layout containment inside a fieldset can suppress editor descendants after diagnostics change in embedded WebKit.
    const update = () => { const width = element.getBoundingClientRect().width; setLayout(width <= 680 ? "narrow" : width <= 920 ? "compact" : "wide"); };
    update();
    const observer = new ResizeObserver(update); observer.observe(element);
    return () => observer.disconnect();
  }, []);
  useEffect(() => {
    const ticket = ++generation.current; setPending(true); setError("");
    const timer = setTimeout(() => {
      void flowEngine.inspectDesign(source, repo, file).then((result) => {
        if (ticket !== generation.current) return;
        setCurrent(result); report.current(result);
        if (result.format === "flow" && result.editable && result.document && !result.diagnostics.some((diagnostic) => diagnostic.severity === "error")) setLastDocument(result.document);
      }, (reason) => { if (ticket === generation.current) setError(reason instanceof Error ? reason.message : String(reason)); }).finally(() => { if (ticket === generation.current) setPending(false); });
    }, 250);
    return () => { clearTimeout(timer); generation.current++; };
  }, [source, repo, file]);
  useEffect(() => {
    setChosenFlow(initialFlow ?? ""); setChosenNode(initialNode ?? "");
    initialJump.current = null;
  }, [initialFlow, initialNode, repo, file]);
  useEffect(() => {
    if (!initialFlow || !initialNode) return;
    const target = `${repo}:${file}:${initialFlow}:${initialNode}`;
    if (initialJump.current === target) return;
    const line = flowModuleSourceLine(source, initialFlow, initialNode);
    if (line) {
      initialJump.current = target;
      setJump((previous) => ({ line, request: (previous?.request ?? 0) + 1 }));
    }
  }, [source, initialFlow, initialNode, repo, file]);
  const names = lastDocument ? designFlowNames(lastDocument) : [], flow = names.includes(chosenFlow) ? chosenFlow : names[0] ?? "";
  const modules = lastDocument ? designModules(lastDocument, flow) : [], selected = modules.find((module) => module.id === chosenNode) ?? modules[0];
  const matchesSource = current?.yaml === source && current.format === "flow" && current.editable && !current.diagnostics.some((diagnostic) => diagnostic.severity === "error") && !error;
  const state = pending ? t("Updating diagram…") : matchesSource ? t("Diagram follows the parsed source. Run validation when saving.") : t("The diagram shows the last readable source. Fix the source errors to update it.");
  const choose = (name: string, node?: string) => { setChosenFlow(name); setChosenNode(node ?? ""); onSelection(name, node); };
  const preview = <div className={`flow-code-preview ${!matchesSource ? "stale" : ""}`} data-flow-source-current={matchesSource}>
    {modules.length ? <FlowGraph key={flow} fitOnMount nodes={modules} selected={selected?.id ?? null} onSelect={(node) => choose(flow, node)} /> : <div className="flow-empty"><Code2 size={26} /><p>{t("Write a flow definition to see its diagram.")}</p></div>}
    <div className={`flow-code-preview-status ${!matchesSource && !pending ? "warning" : ""}`} role="status">{pending && <Spinner size={11} />}{state}</div>
    <RelatedFiles module={selected} onOpen={onOpenFile} />
  </div>;
  return <div ref={host} className={`flow-code-workspace ${layout}`} data-flow-code-workspace>
    <div className="flow-code-toolbar"><label>{t("Flow")}<select aria-label={t("Editing flow")} value={flow} onChange={(event) => choose(event.target.value)} disabled={!names.length}>{names.map((name) => <option key={name}>{name}</option>)}</select></label><span className="flow-code-guidance">{t("Use needs: [prepare] to define order. The diagram follows your code.")}</span><span className="spacer" /><Button size="small" disabled={!matchesSource || !flow} onClick={() => setCatalogue(true)}><Plus size={12} />{t("Insert module…")}</Button><Button size="small" disabled={!matchesSource} onClick={() => void onInsertExample()}>{t("Parallel checks example")}</Button></div>
    <SourceSplit first={<CodeEditor value={source} onChange={onChange} label={t("Flow YAML")} fileName={file} documentKey={`${repo}:${file}`} onSave={onSave} jumpLine={jump?.line} jumpRequest={jump?.request} />} second={preview} />
    {error && <p className="error-text flow-code-error" role="alert">{error}</p>}
    {catalogue && <Modal title={t("Insert module code")} width={660} onClose={() => setCatalogue(false)} footer={<Button onClick={() => setCatalogue(false)}>{t("Done")}</Button>}><p className="hint">{t("A module inserts code with its required settings. Add needs in the source to connect it to other steps.")}</p><label className="flow-module-search"><Search size={14} /><input aria-label={t("Find modules")} placeholder={t("Find modules")} value={search} onChange={(event) => setSearch(event.target.value)} /></label><div className="flow-code-snippets">{blocks.filter((block) => `${block.id} ${block.title} ${block.category}`.toLowerCase().includes(search.toLowerCase())).map((block) => <button type="button" key={block.id} className={`flow-catalogue-item kind-${flowBlockKind(block.id)}`} data-flow-code-block={block.id} onClick={() => { setCatalogue(false); void onInsertModule(flow, block); }}><span className="flow-node-type"><FlowBlockIcon block={block.id} size={16} /></span><span><strong>{block.title}</strong><code>{block.id}</code><small><FlowBlockEffects block={block} /></small></span><Plus size={13} /></button>)}</div></Modal>}
  </div>;
}

function RelatedFiles({ module, onOpen }: { module?: FlowModule; onOpen: (path: string) => void }) {
  const paths = relatedFlowFiles(module);
  return <section className="flow-related-files"><header><FileCode2 size={13} /><strong>{t("Related files")}</strong><span className="spacer" /><Button size="small" onClick={() => onOpen("")}><FilePlus2 size={12} />{t("Open or create file…")}</Button></header>{paths.length ? <div className="flow-related-paths">{paths.map((path) => <button type="button" key={path} className="mono" onClick={() => onOpen(path)}>{path}</button>)}</div> : <p>{t("Open scripts, module definitions or other text files inside this repository.")}</p>}</section>;
}
