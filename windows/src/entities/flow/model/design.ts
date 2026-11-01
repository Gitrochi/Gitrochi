import { t } from "@/shared/i18n";

export type FlowDocument = Record<string, unknown>;
export interface FlowDesignDiagnostic { severity: "error" | "warning" | "info"; code: string; message: string; path?: string; line?: number }
export interface FlowDesignInspection {
  schemaVersion: number;
  document: FlowDocument | null;
  yaml: string;
  format: "flow" | "github" | "gitlab" | "compose" | "jenkins" | "unknown";
  diagnostics: FlowDesignDiagnostic[];
  editable: boolean;
  proposal: { document: FlowDocument; yaml: string } | null;
}
export interface FlowDesignRender { schemaVersion: number; yaml: string; diagnostics: FlowDesignDiagnostic[]; formattingChanged: boolean }
export function checkedDesignYaml(result: FlowDesignRender): string {
  const errors = result.diagnostics.filter((diagnostic) => diagnostic.severity === "error");
  if (errors.length) throw new Error(errors.map((diagnostic) => diagnostic.message).join("\n"));
  return result.yaml;
}
export interface FlowInputSchema {
  type?: string;
  description?: string;
  enum?: unknown[];
  properties?: Record<string, FlowInputSchema>;
  required?: string[];
  items?: FlowInputSchema;
  oneOf?: FlowInputSchema[];
  default?: unknown;
  minimum?: number;
  maximum?: number;
  additionalProperties?: boolean | FlowInputSchema;
}
export interface FlowBlock {
  id: string;
  version: string;
  title: string;
  category: string;
  capabilities: string[];
  envClasses: string[];
  destructive: boolean;
  outward: boolean;
  inputs: FlowInputSchema;
  estimateMs?: number;
}
export interface FlowModule {
  id: string;
  title: string;
  block: string;
  needs: string[];
  run?: string;
  values: Record<string, unknown>;
  source: FlowDocument;
  inherited: boolean;
}

export const flowObject = (value: unknown): FlowDocument => value && typeof value === "object" && !Array.isArray(value) ? value as FlowDocument : {};
const clone = (document: FlowDocument): FlowDocument => JSON.parse(JSON.stringify(document)) as FlowDocument;
const mergeValues = (base: FlowDocument, overrides: FlowDocument): FlowDocument => {
  const result = { ...base };
  for (const [key, value] of Object.entries(overrides)) {
    const merged = value && typeof value === "object" && !Array.isArray(value) ? mergeValues(flowObject(Object.hasOwn(base, key) ? base[key] : undefined), flowObject(value)) : value;
    Object.defineProperty(result, key, { value: merged, enumerable: true, configurable: true, writable: true });
  }
  return result;
};
const needsList = (value: unknown): string[] => typeof value === "string" ? [value] : Array.isArray(value) ? value.filter((item): item is string => typeof item === "string") : [];

/** Read the whole document; edits below replace only the selected path. macOS: FlowDesignerModels.swift. */
export function designFlowNames(document: FlowDocument): string[] { return Object.keys(flowObject(document.flows)); }

export function designModules(document: FlowDocument, flow: string): FlowModule[] {
  const suites = flowObject(document.suites);
  return Object.entries(flowObject(flowObject(flowObject(document.flows)[flow]).nodes)).map(([id, raw]) => {
    const source = typeof raw === "string" ? { run: raw } : flowObject(raw);
    const suite = typeof source.suite === "string" ? flowObject(suites[source.suite]) : {};
    const block = typeof source.use === "string" ? source.use : typeof suite.use === "string" ? suite.use : source.flow ? "flow" : "cmd";
    const values = mergeValues(flowObject(suite.with), flowObject(source.with));
    if (source.run !== undefined) values.run = source.run;
    if (source.undo !== undefined) values.undo = source.undo;
    return { id, title: typeof source.description === "string" ? source.description : id, block, needs: needsList(source.needs), run: typeof values.run === "string" ? values.run : undefined, values, source, inherited: typeof source.suite === "string" || typeof source.flow === "string" };
  });
}

export function updateDesignModule(document: FlowDocument, flow: string, id: string, patch: FlowDocument): FlowDocument {
  const next = clone(document);
  const nodes = flowObject(flowObject(flowObject(next.flows)[flow]).nodes);
  if (!(id in nodes)) throw new Error(t("The selected module no longer exists."));
  const current = typeof nodes[id] === "string" ? { run: nodes[id] } : flowObject(nodes[id]);
  nodes[id] = { ...current, ...patch };
  return next;
}

/** A changed field leaves every unrelated input and advanced node option intact. */
export function updateDesignInput(document: FlowDocument, flow: string, id: string, key: string, value: unknown): FlowDocument {
  const module = designModules(document, flow).find((item) => item.id === id);
  if (!module) throw new Error(t("The selected module no longer exists."));
  const topLevel = module.block === "cmd" && (key === "run" || key === "undo") && (!module.source.use || key in module.source);
  if (topLevel) return updateDesignModule(document, flow, id, { [key]: value });
  return updateDesignModule(document, flow, id, { with: { ...flowObject(module.source.with), [key]: value } });
}

export function addDesignModule(document: FlowDocument, flow: string, block: FlowBlock): { document: FlowDocument; id: string } {
  const next = clone(document);
  const flows = flowObject(next.flows);
  if (!(flow in flows)) throw new Error(t("Choose a flow before adding a module."));
  const definition = flowObject(flows[flow]);
  const nodes = flowObject(definition.nodes);
  const stem = block.id === "cmd" ? "script" : block.id.replace(/[^a-zA-Z0-9_-]+/g, "-");
  let id = stem, suffix = 2;
  while (id in nodes) id = `${stem}-${suffix++}`;
  const inputs: Record<string, unknown> = {};
  for (const [key, schema] of Object.entries(block.inputs.properties ?? {})) if (schema.default !== undefined) inputs[key] = schema.default;
  nodes[id] = block.id === "cmd" ? { run: "echo Replace this command with your script" } : { use: block.id, ...(Object.keys(inputs).length ? { with: inputs } : {}) };
  definition.nodes = nodes;
  flows[flow] = definition;
  next.flows = flows;
  return { document: next, id };
}

/** Remove only this module and its direct dependency references. Other advanced fields are retained. */
export function removeDesignModule(document: FlowDocument, flow: string, id: string): FlowDocument {
  const next = clone(document);
  const nodes = flowObject(flowObject(flowObject(next.flows)[flow]).nodes);
  delete nodes[id];
  for (const [key, raw] of Object.entries(nodes)) {
    if (typeof raw === "string") continue;
    const node = flowObject(raw);
    if (needsList(node.needs).includes(id)) nodes[key] = { ...node, needs: needsList(node.needs).filter((dependency) => dependency !== id) };
  }
  return next;
}

/** A dependency is valid when it cannot lead back to the selected module. */
export function canDesignDependOn(document: FlowDocument, flow: string, id: string, dependency: string): boolean {
  if (id === dependency) return false;
  const nodes = new Map(designModules(document, flow).map((node) => [node.id, node.needs]));
  if (!nodes.has(dependency)) return false;
  const seen = new Set<string>(), queue = [dependency];
  for (let cursor = 0; cursor < queue.length; cursor++) {
    const current = queue[cursor];
    if (current === id) return false;
    if (seen.has(current)) continue;
    seen.add(current);
    queue.push(...(nodes.get(current) ?? []));
  }
  return true;
}

/** Preview external modules without translating arbitrary shell scripts into a local runnable flow. */
export function importedDesignModules(inspection: FlowDesignInspection): { id: string; title: string; block: string; needs: string[]; run?: string }[] {
  const doc = inspection.document ?? {};
  if (inspection.format === "flow") return designModules(doc, designFlowNames(doc)[0] ?? "");
  const entries = inspection.format === "github" ? flowObject(doc.jobs) : inspection.format === "compose" ? flowObject(doc.services) : inspection.format === "gitlab" ? Object.fromEntries(Object.entries(doc).filter(([id, value]) => !id.startsWith(".") && !["stages", "variables", "default", "include", "workflow", "image", "services", "before_script", "after_script", "cache"].includes(id) && typeof value === "object")) : {};
  return Object.entries(entries).map(([id, raw]) => {
    const node = flowObject(raw);
    const dependencies = inspection.format === "compose" ? node.depends_on : node.needs;
    const needs = Array.isArray(dependencies) ? dependencies.flatMap((item) => typeof item === "string" ? [item] : typeof flowObject(item).job === "string" ? [String(flowObject(item).job)] : []) : typeof dependencies === "string" ? [dependencies] : Object.keys(flowObject(dependencies));
    return { id, title: typeof node.name === "string" ? node.name : id, block: inspection.format === "compose" ? "docker.run" : inspection.format === "github" ? "ci.github.workflow" : "ci.gitlab.pipeline", needs };
  });
}

export function importedFlowName(fileName: string): string {
  const stem = fileName.replace(/^.*[/\\]/, "").replace(/\.ya?ml$/i, "").replace(/[^a-zA-Z0-9_-]+/g, "-").replace(/^-+|-+$/g, "");
  return `.gitch/flows/${stem || "imported-flow"}.yml`;
}

/** Compose stays an exact separate source; the wrapper requires explicit deployment settings. */
export function composeDesignProposal(inspection: FlowDesignInspection, attachment: string): FlowDocument {
  const services = Object.keys(flowObject(inspection.document?.services)).sort();
  if (!services.length || inspection.diagnostics.some((diagnostic) => diagnostic.severity === "error")) throw new Error(t("Review the Compose diagnostics before importing."));
  return { version: 1, flows: { "compose-deploy": { trigger: ["manual"], nodes: { deploy: { use: "deploy.compose", with: { file: attachment, project: "", service: services[0], image: "" } } } } } };
}
