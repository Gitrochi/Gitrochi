import { Plus, Search } from "lucide-react";
import { useState } from "react";
import { type FlowBlock, type FlowConnection, type FlowDocument, addDesignModule, designFlowNames, designModules, flowObject, removeDesignModule } from "@/entities/flow";
import { t } from "@/shared/i18n";
import { Button } from "@/shared/ui";
import { FlowBlockEffects, FlowBlockForm } from "./FlowBlockForm";
import { FlowGraph } from "./FlowGraph";
import { FlowBlockIcon, flowBlockKind } from "./FlowState";

/** The default authoring surface edits modules while retaining the complete source document. */
export function FlowDesigner({ document, blocks, connections, onChange, initialFlow, initialNode }: { document: FlowDocument; blocks: FlowBlock[]; connections: FlowConnection[]; onChange: (document: FlowDocument) => void; initialFlow?: string; initialNode?: string }) {
  const names = designFlowNames(document);
  const [chosenFlow, setChosenFlow] = useState(initialFlow ?? names[0] ?? "");
  const flow = names.includes(chosenFlow) ? chosenFlow : names[0] ?? "";
  const modules = designModules(document, flow);
  const [chosenModule, setChosenModule] = useState<string | null>(initialNode ?? modules[0]?.id ?? null);
  const selected = modules.find((module) => module.id === chosenModule) ?? modules[0];
  const [catalogue, setCatalogue] = useState(false);
  const [search, setSearch] = useState("");
  const [category, setCategory] = useState("all");
  const shown = blocks.filter((block) => (category === "all" || block.category === category) && `${block.id} ${block.title} ${block.category} ${block.capabilities.join(" ")}`.toLowerCase().includes(search.toLowerCase()));
  const addFlow = () => {
    const flows = flowObject(document.flows);
    let name = "new-flow", suffix = 2;
    while (name in flows) name = `new-flow-${suffix++}`;
    onChange({ ...document, flows: { ...flows, [name]: { trigger: ["manual"], nodes: {} } } });
    setChosenFlow(name); setChosenModule(null); setCatalogue(true);
  };
  const add = (block: FlowBlock) => {
    if (!flow) return;
    const next = addDesignModule(document, flow, block);
    onChange(next.document); setChosenModule(next.id);
  };
  return <div className="flow-designer" data-flow-designer>
    <div className="flow-designer-toolbar"><label>{t("Flow")}<select aria-label={t("Editing flow")} value={flow} onChange={(event) => { setChosenFlow(event.target.value); setChosenModule(null); }}>{names.map((name) => <option key={name}>{name}</option>)}</select></label><Button size="small" onClick={addFlow}><Plus size={12} />{t("Add flow")}</Button><span className="spacer" /><Button size="small" className={catalogue ? "on" : ""} onClick={() => setCatalogue((value) => !value)}><Plus size={12} />{t("Add module")}</Button></div>
    <div className="flow-designer-body">
      {catalogue && <aside className="flow-module-library"><h3>{t("Module library")}</h3><label className="flow-module-search"><Search size={13} /><input aria-label={t("Find modules")} placeholder={t("Find modules")} value={search} onChange={(event) => setSearch(event.target.value)} /></label><select aria-label={t("Module category")} value={category} onChange={(event) => setCategory(event.target.value)}><option value="all">{t("All modules")}</option>{[...new Set(blocks.map((block) => block.category))].map((value) => <option key={value}>{value}</option>)}</select><div className="flow-module-catalogue">{shown.map((block) => <button key={block.id} className={`flow-catalogue-item kind-${flowBlockKind(block.id)}`} disabled={!flow} onClick={() => add(block)} data-flow-add-block={block.id}><span className="flow-node-type"><FlowBlockIcon block={block.id} size={15} /></span><span><strong>{block.title}</strong><code>{block.id}</code><small><FlowBlockEffects block={block} /></small></span><Plus size={12} /></button>)}</div></aside>}
      <div className="flow-designer-canvas">{flow ? <FlowGraph fitOnMount key={flow} nodes={modules} selected={selected?.id ?? null} onSelect={setChosenModule} /> : <div className="flow-empty"><p>{t("Add a flow, then connect the modules it needs.")}</p><Button onClick={addFlow}>{t("Add flow")}</Button></div>}</div>
      {selected && <FlowBlockForm key={selected.id} document={document} flow={flow} module={selected} block={blocks.find((block) => block.id === selected.block)} connections={connections} onChange={onChange} onRemove={() => { onChange(removeDesignModule(document, flow, selected.id)); setChosenModule(null); }} />}
    </div>
  </div>;
}
