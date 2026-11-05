import { describe, expect, it } from "vitest";
import { type FlowBlock, type FlowModule, type FlowSourceFile, designModules } from "../src/entities/flow/model/design";
import { addCodeModule, addParallelFlowExample, checkedFlowSource, flowModuleSourceLine, portableSourcePath, relatedFlowFiles } from "../src/entities/flow/model/source-authoring";

const module = (patch: Partial<FlowModule> = {}): FlowModule => ({ id: "check", title: "Check", block: "cmd", needs: [], values: {}, source: {}, inherited: false, ...patch });
describe("flow source references and code templates", () => {
  it("finds literal script and module files with the declared working directory", () => {
    expect(relatedFlowFiles(module({ run: "bash ../scripts/check.sh && python 'test suite.py'", source: { cwd: "client" }, values: { file: "settings.yml" } }))).toEqual(["client/settings.yml", "scripts/check.sh", "client/test suite.py"]);
    expect(relatedFlowFiles(module({ values: { file: ".gitch/blocks/local.yml" } }))).toEqual([".gitch/blocks/local.yml"]);
  });

  it("does not reinterpret absolute or dynamic working directories and command substitutions", () => {
    for (const cwd of ["/tmp/project", "C:/project", "${{ env.WORK }}", "../outside"]) expect(relatedFlowFiles(module({ source: { cwd }, run: "bash scripts/check.sh" }))).toEqual([]);
    for (const run of ["bash $SCRIPT/check.sh", "bash $(echo scripts/check.sh)", "bash `echo scripts/check.sh`"]) expect(relatedFlowFiles(module({ run }))).toEqual([]);
    expect(relatedFlowFiles(module({ values: { file: "../../outside.yml" } }))).toEqual([]);
  });

  it("accepts portable Windows relative input while rejecting repository escapes and metadata", () => {
    expect(portableSourcePath(" .\\scripts\\check.sh ")).toBe("scripts/check.sh");
    for (const path of ["C:\\scripts\\check.sh", "\\\\server\\file", "/tmp/code", "scripts/../outside", ".git/config", ".GIT/HEAD", "a\0b"]) expect(() => portableSourcePath(path)).toThrow();
  });

  it("exposes required module settings in inserted code and leaves dependencies independent", () => {
    const block: FlowBlock = { id: "ci.github.workflow", version: "1", title: "Workflow", category: "ci", capabilities: [], envClasses: [], destructive: false, outward: true, inputs: { properties: { connection: { type: "string" }, workflow: { type: "string" } }, required: ["connection", "workflow"] } };
    const result = addCodeModule({ version: 1, flows: { verify: { nodes: { prepare: "echo ready" } } } }, "verify", block);
    const inserted = designModules(result.document, "verify").find((entry) => entry.id === result.id)!;
    expect(inserted.values).toEqual({ connection: "", workflow: "" });
    expect(inserted.needs).toEqual([]);
  });

  it("adds a collision-safe parallel example whose order is explicit source data", () => {
    const first = addParallelFlowExample({ version: 1, defaults: { timeout: "20m" }, flows: {} });
    const second = addParallelFlowExample(first.document);
    expect(second.flow).toBe("parallel-checks-2");
    expect(second.document.defaults).toEqual({ timeout: "20m" });
    expect(designModules(first.document, first.flow).find((entry) => entry.id === "package")?.needs).toEqual(["lint", "tests"]);
  });

  it("locates module source lines without mistaking script text for flow structure", () => {
    const yaml = 'flows:\n  verify:\n    nodes:\n      prepare:\n        run: |\n          flows:\n            verify:\n              nodes:\n                target: ignored\n      "target": {run: echo target}\n';
    expect(flowModuleSourceLine(yaml, "verify", "target")).toBe(10);
  });

  it("allows only explicit missing-file statuses for New file and preserves all other source errors", () => {
    const result: FlowSourceFile = { schemaVersion: 1, path: "new.sh", content: null, fingerprint: null, exists: false, saved: false, diagnostics: [{ severity: "error", code: "SOURCE_NOT_FOUND", message: "missing" }] };
    expect(() => checkedFlowSource(result)).toThrow("missing");
    expect(checkedFlowSource(result, true)).toBe(result);
    expect(checkedFlowSource({ ...result, diagnostics: [{ severity: "error", code: "SOURCE_PARENT_NOT_FOUND", message: "missing parent" }] }, true).exists).toBe(false);
    expect(() => checkedFlowSource({ ...result, diagnostics: [{ severity: "error", code: "SOURCE_PARENT", message: "unsafe parent" }] }, true)).toThrow("unsafe parent");
    expect(() => checkedFlowSource({ ...result, diagnostics: [{ severity: "error", code: "SOURCE_CONFLICT", message: "changed" }] }, true)).toThrow("changed");
  });
});
