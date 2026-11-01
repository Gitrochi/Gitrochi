import { Plus, ShieldCheck, Trash2, TriangleAlert } from "lucide-react";
import { useState } from "react";
import { type FlowBlock, type FlowConnection, type FlowDocument, type FlowInputSchema, type FlowModule, canDesignDependOn, designModules, flowObject, updateDesignInput, updateDesignModule } from "@/entities/flow";
import { t } from "@/shared/i18n";
import { Button, IconButton } from "@/shared/ui";
import { FlowBlockIcon, flowBlockKind } from "./FlowState";

const fieldCaption = (name: string) => ({
  run: t("Command"), undo: t("Undo command"), connection: t("Connection"), workflow: t("Workflow"), job: t("Job"), repo: t("Repository"), ref: t("Branch or tag"), report: t("Report file"), image: t("Container image"), file: t("Configuration file"), timeout: t("Timeout"), poll: t("Poll interval"), trigger: t("Trigger request"), status: t("Status request"), logs: t("Log request"), cancel: t("Cancel request"), pointer: t("Status field path"), url: t("URL"), method: t("Method"), headers: t("Headers"), body: t("Body"), project: t("Project"), service: t("Service"), host: t("Host"), args: t("Arguments"), cwd: t("Working directory"), parameters: t("Parameters"), inputs: t("Inputs"),
}[name] ?? name);

const capabilityTitle = (capability: string) => ({
  process: t("Runs a process"), docker: t("Uses Docker"), network: t("Uses the network"), secrets: t("Reads saved credentials"), ssh: t("Uses SSH"), "ci-api": t("Uses remote CI"), outward: t("Acts outside this computer"),
}[capability] ?? capability);

/** Schema-backed module inputs keep unedited values and advanced options in the original document. */
export function FlowBlockForm({ document, flow, module, block, connections, onChange, onRemove }: { document: FlowDocument; flow: string; module: FlowModule; block?: FlowBlock; connections: FlowConnection[]; onChange: (document: FlowDocument) => void; onRemove: () => void }) {
  const modules = designModules(document, flow);
  const fields = block?.inputs.properties ?? {};
  const patch = (values: FlowDocument) => onChange(updateDesignModule(document, flow, module.id, values));
  const output = module.block.startsWith("test.") ? t("Test results, verdicts and captured output.") : module.block === "docker.build" ? t("Container image and image identifier.") : module.block.startsWith("ci.") ? t("Remote run status, logs and verdict.") : t("Status, verdicts and captured output.");
  const outputs = Object.entries(flowObject(module.source.outputs));
  return <aside className="flow-module-form" data-flow-module-form={module.id}>
    <div className={`flow-inspector-heading kind-${flowBlockKind(module.block)}`}><span className="flow-node-type"><FlowBlockIcon block={module.block} size={19} /></span><div><h3>{module.id}</h3><span className="flow-step-block mono">{module.block}</span></div><IconButton small icon={<Trash2 size={14} />} aria-label={t("Remove module")} tip={t("Remove module")} onClick={onRemove} /></div>
    {block && <div className="flow-module-effects"><strong>{block.title}</strong><div>{block.capabilities.map((capability) => <span key={capability}>{capabilityTitle(capability)}</span>)}</div>{(block.outward || block.destructive) && <p><TriangleAlert size={12} />{block.destructive ? t("May change or remove resources. Review before running.") : t("This module acts outside this computer.")}</p>}</div>}
    <label className="flow-form-field"><span>{t("Description")}</span><input aria-label={t("Module description")} value={typeof module.source.description === "string" ? module.source.description : ""} onChange={(event) => patch({ description: event.target.value })} /></label>
    <fieldset className="flow-dependencies"><legend>{t("Depends on")}</legend>{modules.filter((node) => node.id !== module.id).map((node) => {
      const checked = module.needs.includes(node.id), allowed = checked || canDesignDependOn(document, flow, module.id, node.id);
      return <label key={node.id} data-tip={allowed ? undefined : t("This dependency would create a cycle.")}><input type="checkbox" checked={checked} disabled={!allowed} onChange={(event) => patch({ needs: event.target.checked ? [...module.needs, node.id] : module.needs.filter((id) => id !== node.id) })} /><span>{node.id}</span></label>;
    })}{modules.length < 2 && <span className="muted">{t("Add another module to connect steps.")}</span>}</fieldset>
    <div className="flow-module-inputs"><h4>{t("Module settings")}</h4>{module.inherited && <p className="muted">{t("These settings are inherited. Open Advanced YAML to edit the suite or referenced flow.")}</p>}<fieldset disabled={module.inherited} className="flow-inherited-inputs">{Object.entries(fields).map(([name, schema]) => <FlowSchemaField key={name} name={name} schema={schema} required={block?.inputs.required?.includes(name)} value={module.values[name]} connections={connections} onChange={(value) => onChange(updateDesignInput(document, flow, module.id, name, value))} />)}{!Object.keys(fields).length && <p className="muted">{t("This module keeps its existing advanced settings. Use Advanced YAML to edit unsupported fields.")}</p>}</fieldset></div>
    <section className="flow-module-produces"><h4><ShieldCheck size={12} />{t("Produces")}</h4><p>{output}</p>{typeof module.values.report === "string" && <code>{module.values.report}</code>}{outputs.map(([name, value]) => <p className="mono" key={name}>{name}: {typeof value === "string" ? value : JSON.stringify(value)}</p>)}</section>
    <details className="flow-module-options"><summary>{t("Step options")}</summary>{["cwd", "timeout", "executor", "if"].map((name) => <label key={name} className="flow-form-field"><span>{name}</span><input aria-label={name} className="mono" value={typeof module.source[name] === "string" ? String(module.source[name]) : ""} onChange={(event) => patch({ [name]: event.target.value || undefined })} /></label>)}</details>
  </aside>;
}

const inferredType = (value: unknown) => Array.isArray(value) ? "array" : value !== null && typeof value === "object" ? "object" : typeof value === "boolean" ? "boolean" : typeof value === "number" ? "number" : "string";
const emptyValue = (type?: string): unknown => type === "object" ? {} : type === "array" ? [] : type === "boolean" ? false : type === "number" || type === "integer" ? 0 : "";

/** Nested schemas and open-ended maps use ordinary fields instead of requiring JSON knowledge. */
function FlowSchemaField({ name, schema, value, onChange, required = false, connections = [], depth = 0 }: { name: string; schema: FlowInputSchema; value: unknown; onChange: (value: unknown) => void; required?: boolean; connections?: FlowConnection[]; depth?: number }) {
  const [newKey, setNewKey] = useState("");
  const variants = schema.oneOf;
  const currentType = inferredType(value);
  const variant = variants?.find((option) => option.type === currentType) ?? variants?.[0];
  const effective = variant ?? schema;
  const type = effective.type ?? currentType;
  const props = effective.properties ?? {};
  const object = flowObject(value);
  const keys = [...new Set([...Object.keys(props), ...Object.keys(object)])];
  const defaultSchema = typeof effective.additionalProperties === "object" ? effective.additionalProperties : {};
  let control;
  if (depth > 7) control = <p className="muted">{t("Advanced value preserved. Open Advanced YAML to edit it.")}</p>;
  else if (name === "connection") control = <><select aria-label={name} value={typeof value === "string" ? value : ""} onChange={(event) => onChange(event.target.value)}><option value="">{t("Choose a configured connection")}</option>{typeof value === "string" && value && !connections.some((connection) => connection.name === value) && <option value={value}>{value}</option>}{connections.map((connection) => <option key={connection.name} value={connection.name}>{connection.name} · {connection.kind}</option>)}</select><small className={connections.some((connection) => connection.name === value) ? "flow-connection-ok" : "muted"}>{connections.some((connection) => connection.name === value) ? t("Configured connection") : t("Manage connections in Connected CI.")}</small></>;
  else if (effective.enum) control = <select aria-label={name} value={value === undefined ? effective.default === undefined ? "" : JSON.stringify(effective.default) : JSON.stringify(value)} onChange={(event) => onChange(event.target.value ? JSON.parse(event.target.value) : undefined)}><option value="">{t("Choose…")}</option>{effective.enum.map((option) => <option key={JSON.stringify(option)} value={JSON.stringify(option)}>{String(option)}</option>)}</select>;
  else if (type === "boolean") control = <label className="flow-schema-switch"><input type="checkbox" aria-label={name} checked={value === true} onChange={(event) => onChange(event.target.checked)} /><span>{value === true ? t("Enabled") : t("Disabled")}</span></label>;
  else if (type === "object") control = <div className="flow-schema-object">{keys.map((key) => <div className="flow-schema-property" key={key}><FlowSchemaField name={key} schema={props[key] ?? defaultSchema} value={object[key]} required={effective.required?.includes(key)} connections={connections} depth={depth + 1} onChange={(next) => onChange({ ...object, [key]: next })} />{!(key in props) && <IconButton small icon={<Trash2 size={12} />} tip={t("Remove setting")} onClick={() => { const next = { ...object }; delete next[key]; onChange(next); }} />}</div>)}{effective.additionalProperties !== false && <div className="flow-schema-add"><input aria-label={t("Setting name")} placeholder={t("Setting name")} value={newKey} onChange={(event) => setNewKey(event.target.value)} /><IconButton small icon={<Plus size={13} />} aria-label={t("Add setting")} tip={t("Add setting")} disabled={!newKey.trim() || newKey in object} onClick={() => { onChange({ ...object, [newKey.trim()]: emptyValue(defaultSchema.type) }); setNewKey(""); }} /></div>}</div>;
  else if (type === "array") {
    const array = Array.isArray(value) ? value : [];
    control = <div className="flow-schema-array">{array.map((item, index) => <div className="flow-schema-property" key={index}><FlowSchemaField name={String(index + 1)} schema={effective.items ?? {}} value={item} depth={depth + 1} connections={connections} onChange={(next) => onChange(array.map((previous, position) => position === index ? next : previous))} /><IconButton small icon={<Trash2 size={12} />} tip={t("Remove item")} onClick={() => onChange(array.filter((_, position) => position !== index))} /></div>)}<Button size="small" onClick={() => onChange([...array, emptyValue(effective.items?.type)])}><Plus size={12} />{t("Add item")}</Button></div>;
  } else if (type === "integer" || type === "number") control = <input type="number" aria-label={name} step={type === "integer" ? 1 : "any"} min={effective.minimum} max={effective.maximum} value={typeof value === "number" ? value : ""} onChange={(event) => onChange(event.target.value === "" ? undefined : Number(event.target.value))} />;
  else if (["run", "undo", "script", "body", "query"].includes(name) || typeof value === "string" && value.includes("\n")) control = <textarea aria-label={name} className="mono" rows={name === "run" ? 5 : 3} spellCheck={false} value={typeof value === "string" ? value : ""} onChange={(event) => onChange(event.target.value)} />;
  else control = <input aria-label={name} value={typeof value === "string" ? value : ""} onChange={(event) => onChange(event.target.value)} />;
  return <div className="flow-form-field"><span className="flow-schema-label"><span>{fieldCaption(name)}</span><code className="flow-schema-key">{name}</code>{required && <span aria-hidden="true">*</span>}{variants && <select aria-label={t("Value type")} value={variant?.type ?? "string"} onChange={(event) => onChange(emptyValue(event.target.value))}>{variants.map((option) => <option key={option.type} value={option.type}>{option.type === "object" ? t("Settings") : option.type === "array" ? t("List") : t("Text")}</option>)}</select>}</span>{control}{schema.description && <small>{schema.description}</small>}</div>;
}

/** Block effects are also shown before a module is added from the catalogue. */
export function FlowBlockEffects({ block }: { block: FlowBlock }) { return <span>{block.capabilities.map(capabilityTitle).join(" · ")}</span>; }
