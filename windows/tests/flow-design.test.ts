import { describe, expect, it } from "vitest";
import { type FlowBlock, type FlowDesignInspection, addDesignModule, canDesignDependOn, checkedDesignYaml, composeDesignProposal, designModules, importedDesignModules, importedFlowName, removeDesignModule, updateDesignInput, updateDesignModule } from "../src/entities/flow/model/design";

const block: FlowBlock = { id: "cmd", version: "1", title: "Command", category: "run", capabilities: ["process"], envClasses: [], destructive: false, outward: false, inputs: { type: "object", properties: { run: { type: "string" } }, required: ["run"] } };
const fixture = () => ({ version: 1, defaults: { timeout: "30m" }, services: { db: { use: "docker.run", with: { image: "example/database" } } }, flows: { verify: { trigger: ["manual"], rollback: { scope: "flow" }, nodes: { setup: "echo ready", check: { needs: ["setup"], use: "test.junit", with: { report: "results/*.xml", custom: { retained: true } }, matrix: { runtime: [18, 20] }, retry: { max: 2 }, secrets: { TOKEN: "env:CI_TOKEN" }, outputs: { report: "results/report.xml" } } } } } });

describe("lossless visual flow document editing", () => {
  it("updates one input while retaining advanced fields and the original document", () => {
    const document = fixture(), original = JSON.parse(JSON.stringify(document));
    const changed = updateDesignInput(document, "verify", "check", "report", "new-results/*.xml");
    expect(document).toEqual(original);
    const module = designModules(changed, "verify").find((node) => node.id === "check")!;
    expect(module.values).toEqual({ report: "new-results/*.xml", custom: { retained: true } });
    expect(module.source.matrix).toEqual({ runtime: [18, 20] });
    expect(module.source.retry).toEqual({ max: 2 });
    expect(changed.services).toEqual(document.services);
    expect(changed.defaults).toEqual(document.defaults);
  });

  it("expands command shorthand only when the selected module is edited", () => {
    const changed = updateDesignModule(fixture(), "verify", "setup", { description: "Prepare workspace" });
    expect(designModules(changed, "verify")[0].source).toEqual({ run: "echo ready", description: "Prepare workspace" });
    expect(designModules(updateDesignInput(changed, "verify", "setup", "run", "echo changed"), "verify")[0].run).toBe("echo changed");
  });

  it("shows inherited suite settings without copying them into the node", () => {
    const document = { version: 1, suites: { unit: { use: "test.vitest", with: { cwd: "client", config: { a: true, b: false } } } }, flows: { verify: { nodes: { unit: { suite: "unit", with: { config: { a: false } } } } } } };
    const module = designModules(document, "verify")[0];
    expect(module.inherited).toBe(true);
    expect(module.values).toEqual({ cwd: "client", config: { a: false, b: false } });
    expect(module.source).toEqual({ suite: "unit", with: { config: { a: false } } });
  });

  it("keeps reserved map keys as source data rather than inheriting their settings", () => {
    const document = JSON.parse('{"flows":{"verify":{"nodes":{"check":{"use":"cmd","with":{"__proto__":{"run":"echo data"},"run":"echo actual"}}}}}}');
    const values = designModules(document, "verify")[0].values;
    expect(Object.hasOwn(values, "__proto__")).toBe(true);
    expect(values.run).toBe("echo actual");
    expect(Object.getPrototypeOf(values)).toBe(Object.prototype);
    expect(JSON.stringify(values)).toContain('"__proto__"');
  });

  it("adds unique modules and removes only their dependency references", () => {
    const added = addDesignModule(fixture(), "verify", block), again = addDesignModule(added.document, "verify", block);
    expect([added.id, again.id]).toEqual(["script", "script-2"]);
    const removed = removeDesignModule(again.document, "verify", "setup");
    expect(designModules(removed, "verify").find((node) => node.id === "check")?.needs).toEqual([]);
    expect(designModules(removed, "verify").find((node) => node.id === "check")?.source.outputs).toEqual({ report: "results/report.xml" });
  });

  it("rejects cyclic dependencies including indirect paths and terminates on malformed cycles", () => {
    const document = { flows: { verify: { nodes: { a: { run: "a" }, b: { run: "b", needs: ["a"] }, c: { run: "c", needs: ["b"] } } } } };
    expect(canDesignDependOn(document, "verify", "a", "c")).toBe(false);
    expect(canDesignDependOn(document, "verify", "c", "a")).toBe(true);
    expect(canDesignDependOn(document, "verify", "a", "a")).toBe(false);
    expect(canDesignDependOn({ flows: { x: { nodes: { a: { needs: ["b"] }, b: { needs: ["a"] }, c: {} } } } }, "x", "c", "a")).toBe(true);
  });

  it("blocks render errors before a source editor or save can accept an empty result", () => {
    expect(() => checkedDesignYaml({ schemaVersion: 1, yaml: "", diagnostics: [{ severity: "error", code: "NUMERIC_PRECISION", message: "Keep the original source" }], formattingChanged: true })).toThrow("Keep the original source");
    expect(checkedDesignYaml({ schemaVersion: 1, yaml: "# original\nversion: 1", diagnostics: [], formattingChanged: false })).toBe("# original\nversion: 1");
  });
});

describe("workflow import interpretation", () => {
  const inspection = (format: FlowDesignInspection["format"], document: Record<string, unknown>): FlowDesignInspection => ({ schemaVersion: 1, document, yaml: "# exact source\n", format, diagnostics: [], editable: false, proposal: null });
  it("previews original GitHub dependencies without extracting local commands", () => {
    const nodes = importedDesignModules(inspection("github", { jobs: { lint: { steps: [{ run: "npm run lint" }] }, test: { needs: "lint", steps: [{ uses: "actions/checkout@v4" }] } } }));
    expect(nodes.map((node) => ({ id: node.id, needs: node.needs }))).toEqual([{ id: "lint", needs: [] }, { id: "test", needs: ["lint"] }]);
    expect(nodes.every((node) => node.run === undefined)).toBe(true);
  });

  it("keeps Compose maps intact and proposes a separate deployment with required settings left explicit", () => {
    const source = inspection("compose", { services: { web: { image: "example/web", depends_on: { db: { condition: "service_healthy" } } }, db: { image: "example/db" } }, volumes: { cache: {} } });
    const before = JSON.stringify(source.document);
    expect(importedDesignModules(source)[0].needs).toEqual(["db"]);
    const module = designModules(composeDesignProposal(source, ".gitch/imports/compose.yml"), "compose-deploy")[0];
    expect(module.block).toBe("deploy.compose");
    expect(module.values).toEqual({ file: ".gitch/imports/compose.yml", project: "", service: "db", image: "" });
    expect(JSON.stringify(source.document)).toBe(before);
    expect(importedFlowName("../../workflows/build.yaml")).toBe(".gitch/flows/build.yml");
  });
});
