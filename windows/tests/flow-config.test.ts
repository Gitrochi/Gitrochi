import { beforeEach, describe, expect, it, vi } from "vitest";

const fake = vi.hoisted(() => ({ files: new Map<string, string>(), validate: vi.fn<() => Promise<{ valid: boolean }>>() }));
vi.mock("@/shared/api", () => ({ ipc: {
  exists: async (path: string) => fake.files.has(path),
  readText: async (path: string) => fake.files.get(path) ?? null,
  writeText: async (path: string, content: string) => { fake.files.set(path, content); },
  remove: async (path: string) => { fake.files.delete(path); },
  list: async (path: string) => [...fake.files.keys()].filter((file) => file.startsWith(path + "/")).map((file) => file.slice(path.length + 1)),
} }));
vi.mock("@/shared/i18n", () => ({ t: (key: string) => key }));
vi.mock("../src/entities/flow/model/engine", () => ({ flowEngine: { validate: fake.validate } }));
import { flowConfigFiles, saveFlowConfig } from "../src/entities/flow/model/config";

const repo = "/tmp/flow-config-fixture", path = repo + "/.gitch/flow.yml";
beforeEach(() => { fake.files.clear(); fake.validate.mockReset(); fake.validate.mockResolvedValue({ valid: true }); });

describe("flow configuration editing", () => {
  it("preserves arbitrary YAML and validates before accepting a save", async () => {
    const original = "version: 1\n# retained comment\nflows: {}\n";
    fake.files.set(path, original);
    const draft = original + "# custom command: npm test";
    await saveFlowConfig(repo, ".gitch/flow.yml", original, draft);
    expect(fake.files.get(path)).toBe(draft + "\n");
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
});
