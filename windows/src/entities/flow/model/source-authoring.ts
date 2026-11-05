import { t } from "@/shared/i18n";
import type { FlowBlock, FlowDocument, FlowModule, FlowSourceFile } from "./design";
import { addDesignModule, flowObject } from "./design";

/** Literal file hints never evaluate shell expressions or become commands. */
export function relatedFlowFiles(module: FlowModule | undefined): string[] {
  if (!module) return [];
  const cwd = typeof module.source.cwd === "string" ? module.source.cwd : typeof module.values.cwd === "string" ? module.values.cwd : "";
  if (cwd.startsWith("/") || /[\x00-\x1f\\:$`*?<>|;&]/.test(cwd)) return [];
  const resolve = (input: string): string | null => {
    if (!input || /[\x00-\x1f\\:$`*?<>|;&]/.test(input) || input.startsWith("/")) return null;
    const parts: string[] = [];
    for (const part of `${cwd ? cwd + "/" : ""}${input}`.split("/")) {
      if (!part || part === ".") continue;
      if (part === "..") { if (!parts.length) return null; parts.pop(); }
      else { if (part.toLowerCase() === ".git") return null; parts.push(part); }
    }
    return parts.length ? parts.join("/") : null;
  };
  const candidates: string[] = [];
  for (const key of ["file", "script", "config", "dockerfile", "composeFile"]) if (typeof module.values[key] === "string") candidates.push(String(module.values[key]));
  for (const value of [module.run, module.values.undo, module.values.script]) {
    if (typeof value !== "string") continue;
    if (/[$`]/.test(value)) continue;
    const pattern = /"([^"\n]+)"|'([^'\n]+)'|([A-Za-z0-9_./-]+\.(?:sh|bash|zsh|ps1|py|js|mjs|cjs|ts|tsx|rb|go|swift|rs|json|ya?ml|toml|conf|sql|md|html|css))\b/g;
    for (const match of value.matchAll(pattern)) {
      const path = match[1] ?? match[2] ?? match[3];
      if (/\.(?:sh|bash|zsh|ps1|py|js|mjs|cjs|ts|tsx|rb|go|swift|rs|json|ya?ml|toml|conf|sql|md|html|css)$/i.test(path)) candidates.push(path);
    }
  }
  return [...new Set(candidates.map(resolve).filter((path): path is string => path !== null))];
}

export function checkedFlowSource(result: FlowSourceFile, create = false): FlowSourceFile {
  const errors = result.diagnostics.filter((diagnostic) => diagnostic.severity === "error" && !(create && ["SOURCE_NOT_FOUND", "SOURCE_PARENT_NOT_FOUND"].includes(diagnostic.code)));
  if (errors.length) throw new Error(errors.map((diagnostic) => t(diagnostic.message)).join("\n"));
  return result;
}

/** The app accepts ordinary Windows relative spelling while the engine receives portable paths. */
export function portableSourcePath(raw: string): string {
  const value = raw.trim();
  if (/^[\\/]|^[A-Za-z]:/.test(value) || /[\x00-\x1f:]/.test(value)) throw new Error(t("Use a repository-relative path without a drive or network prefix."));
  const parts = value.replace(/\\/g, "/").split("/").filter((part) => part && part !== ".");
  if (!parts.length || parts.some((part) => part === ".." || part.toLowerCase() === ".git")) throw new Error(t("Use a path inside this repository, without .. or .git."));
  return parts.join("/");
}

/** Literal YAML key indentation locates a module without rewriting or evaluating its source. */
export function flowModuleSourceLine(source: string, flow: string, module: string): number | null {
  const stack: { key: string; indent: number }[] = [];
  for (const [index, line] of source.replace(/^\uFEFF/, "").split(/\r?\n/).entries()) {
    const match = /^( *)(?:"((?:[^"\\]|\\.)*)"|'((?:[^']|'')*)'|([^:#][^:]*?)):\s*/.exec(line);
    if (!match) continue;
    let key: string;
    try { key = match[2] !== undefined ? JSON.parse(`"${match[2]}"`) as string : match[3] !== undefined ? match[3].replace(/''/g, "'") : match[4].trim(); } catch { continue; }
    while (stack.length && stack.at(-1)!.indent >= match[1].length) stack.pop();
    stack.push({ key, indent: match[1].length });
    if (stack.length === 4 && stack.map((entry) => entry.key).every((part, position) => part === ["flows", flow, "nodes", module][position])) return index + 1;
  }
  return null;
}

/** Code snippets make required inputs visible and leave dependency order explicitly in source. */
export function addCodeModule(document: FlowDocument, flow: string, block: FlowBlock) {
  const added = addDesignModule(document, flow, block);
  if (block.id === "cmd") return added;
  const node = flowObject(flowObject(flowObject(flowObject(added.document.flows)[flow]).nodes)[added.id]);
  const values = { ...flowObject(node.with) };
  const empty = (type?: string): unknown => type === "object" ? {} : type === "array" ? [] : type === "boolean" ? false : type === "number" || type === "integer" ? 0 : "";
  for (const key of block.inputs.required ?? []) if (!(key in values)) values[key] = block.inputs.properties?.[key]?.default ?? empty(block.inputs.properties?.[key]?.type);
  if (Object.keys(values).length) node.with = values;
  return added;
}

export function addParallelFlowExample(document: FlowDocument): { document: FlowDocument; flow: string } {
  const flows = flowObject(document.flows); let name = "parallel-checks", suffix = 2;
  while (Object.hasOwn(flows, name)) name = `parallel-checks-${suffix++}`;
  return { flow: name, document: { ...document, flows: { ...flows, [name]: { trigger: ["manual"], nodes: {
    prepare: { run: "echo Prepare the workspace" },
    lint: { needs: ["prepare"], run: "echo Replace with your lint command" },
    tests: { needs: ["prepare"], run: "echo Replace with your test command" },
    package: { needs: ["lint", "tests"], run: "echo Replace with your build command" },
  } } } } };
}
