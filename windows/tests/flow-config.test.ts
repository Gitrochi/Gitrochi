import { beforeEach, describe, expect, it, vi } from "vitest";

const fake = vi.hoisted(() => ({ files: new Map<string, string>(), validate: vi.fn<() => Promise<{ valid: boolean }>>() }));
vi.mock("@/shared/api", () => ({ ipc: {
  exists: async (path: string) => fake.files.has(path),
  readText: async (path: string) => fake.files.get(path) ?? null,
  writeText: async (path: string, content: string) => { fake.files.set(path, content); },
  createText: async (path: string, content: string) => { if (fake.files.has(path)) throw new Error("File exists"); fake.files.set(path, content); },
  remove: async (path: string) => { fake.files.delete(path); },
  list: async (path: string) => [...fake.files.keys()].filter((file) => file.startsWith(path + "/")).map((file) => file.slice(path.length + 1)),
} }));
vi.mock("@/shared/i18n", () => ({ t: (key: string) => key }));
vi.mock("../src/entities/flow/model/engine", () => ({ flowEngine: { validate: fake.validate } }));
import { flowConfigFiles, readWebFlowImport, saveFlowConfig } from "../src/entities/flow/model/config";

const repo = "/tmp/flow-config-fixture", path = repo + "/.gitch/flow.yml";
beforeEach(() => { fake.files.clear(); fake.validate.mockReset(); fake.validate.mockResolvedValue({ valid: true }); });

describe("flow configuration editing", () => {
  it("retains valid UTF-8 source bytes including the BOM and rejects undecodable or binary web imports", async () => {
    const source = "\uFEFFversion: 1\n# retained\n", encoded = new TextEncoder().encode(source);
    const file = { name: "workflow.yml", size: encoded.byteLength, arrayBuffer: async () => encoded.buffer as ArrayBuffer };
    expect(await readWebFlowImport(file)).toEqual({ fileName: "workflow.yml", yaml: source });
    for (const bytes of [new Uint8Array([255, 254]), new Uint8Array([97, 0, 98])]) await expect(readWebFlowImport({ ...file, size: bytes.byteLength, arrayBuffer: async () => bytes.buffer as ArrayBuffer })).rejects.toThrow("UTF-8");
    await expect(readWebFlowImport({ ...file, size: 3 * 1024 * 1024 })).rejects.toThrow("2 MB");
  });
  it("preserves arbitrary YAML and validates before accepting a save", async () => {
    const original = "version: 1\n# retained comment\nflows: {}\n";
    fake.files.set(path, original);
    const draft = original + "# custom command: npm test";
    await saveFlowConfig(repo, ".gitch/flow.yml", original, draft);
    expect(fake.files.get(path)).toBe(draft);
    expect(fake.validate).toHaveBeenCalledWith(repo);
  });

  it("restores the original file when engine validation rejects the draft", async () => {
    fake.files.set(path, "version: 1\n");
    fake.validate.mockRejectedValue(new Error("SPEC-02: bad dependency"));
    await expect(saveFlowConfig(repo, ".gitch/flow.yml", "version: 1\n", "bad: yaml")).rejects.toThrow("SPEC-02");
    expect(fake.files.get(path)).toBe("version: 1\n");
  });

  it("removes only its newly created file after failed validation", async () => {
    fake.validate.mockRejectedValue(new Error("invalid"));
    await expect(saveFlowConfig(repo, ".gitch/flow.yml", null, "bad: yaml")).rejects.toThrow("invalid");
    expect(fake.files.has(path)).toBe(false);
  });

  it("never overwrites a file that changed outside the editor", async () => {
    fake.files.set(path, "external edit");
    await expect(saveFlowConfig(repo, ".gitch/flow.yml", "original", "draft")).rejects.toThrow("changed outside");
    expect(fake.files.get(path)).toBe("external edit");
    expect(fake.validate).not.toHaveBeenCalled();
  });

  it("never rolls back an external edit made during validation", async () => {
    fake.files.set(path, "original");
    fake.validate.mockImplementation(async () => { fake.files.set(path, "external edit"); throw new Error("invalid"); });
    await expect(saveFlowConfig(repo, ".gitch/flow.yml", "original", "draft")).rejects.toThrow("changed during validation");
    expect(fake.files.get(path)).toBe("external edit");
  });

  it("uses the engine's YAML precedence and discovers split files and overlays", async () => {
    for (const file of ["flow.yml", "flow.yaml", "flow.local.yml", "flows/b.yaml", "flows/a.yml", "flows/.hidden.yml", "flows/readme.txt"]) fake.files.set(repo + "/.gitch/" + file, "");
    expect(await flowConfigFiles(repo)).toEqual([".gitch/flow.yml", ".gitch/flows/a.yml", ".gitch/flows/b.yaml", ".gitch/flow.local.yml"]);
  });

  it("rejects paths outside flow configuration and empty drafts", async () => {
    await expect(saveFlowConfig(repo, "../outside.yml", null, "version: 1")).rejects.toThrow("Choose a flow");
    await expect(saveFlowConfig(repo, ".gitch/flows/../flow.yml", null, "version: 1")).rejects.toThrow("Choose a flow");
    await expect(saveFlowConfig(repo, ".gitch/flow.yml", null, "  ")).rejects.toThrow("cannot be empty");
  });

  it("creates separate imported sources only on save and rolls them back with a rejected flow", async () => {
    const attachment = { file: ".gitch/imports/compose.yml", yaml: "services:\n  app: {image: example/app}\n" };
    fake.validate.mockRejectedValue(new Error("project is required"));
    await expect(saveFlowConfig(repo, ".gitch/flows/imported.yml", null, "version: 1\n", [attachment])).rejects.toThrow("project is required");
    expect(fake.files.size).toBe(0);
    fake.validate.mockResolvedValue({ valid: true });
    await saveFlowConfig(repo, ".gitch/flows/imported.yml", null, "version: 1\n", [attachment]);
    expect(fake.files.get(repo + "/" + attachment.file)).toBe(attachment.yaml);
    expect(fake.files.get(repo + "/.gitch/flows/imported.yml")).toBe("version: 1\n");
  });

  it("never overwrites an existing imported source or creates the flow when attachment creation fails", async () => {
    const imported = repo + "/.gitch/imports/compose.yml";
    fake.files.set(imported, "external source");
    await expect(saveFlowConfig(repo, ".gitch/flows/imported.yml", null, "version: 1\n", [{ file: ".gitch/imports/compose.yml", yaml: "new source" }])).rejects.toThrow("File exists");
    expect(fake.files.get(imported)).toBe("external source");
    expect(fake.files.has(repo + "/.gitch/flows/imported.yml")).toBe(false);
    expect(fake.validate).not.toHaveBeenCalled();
  });

  it("keeps an imported source changed by another editor while validation was running", async () => {
    const imported = repo + "/.gitch/imports/compose.yml";
    fake.validate.mockImplementation(async () => { fake.files.set(imported, "external edit"); throw new Error("invalid"); });
    await expect(saveFlowConfig(repo, ".gitch/flows/imported.yml", null, "version: 1\n", [{ file: ".gitch/imports/compose.yml", yaml: "source" }])).rejects.toThrow("invalid");
    expect(fake.files.get(imported)).toBe("external edit");
  });
});
