import { describe, expect, it } from "vitest";
import { createWorkContext, parseWorkGraphSnapshot, validateWorkGraphActions, workContextPath, type WorkGraphSnapshot } from "../src/shared/lib/work-context";
import { renderWorkPrompt, workPrompts, workPromptTemplate } from "../src/shared/lib/work-prompts";
import { screenCodeMap } from "../src/shared/lib/screen-code-map";
import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

const input = { repositoryPath: "C:/fixture/workspace", head: "a".repeat(40), scope: "worktree" as const, screenID: "changes", selectedPaths: ["src/b.ts", "src/a.ts"], selectedNodeIDs: ["src/a.ts"] };
const graph: WorkGraphSnapshot = { schemaVersion: 1, id: "snapshot-a", nodeIDs: ["src/a.ts", "src/b.ts", "src/c.ts"], edges: [{ source: "src/a.ts", target: "src/b.ts" }] };
const envelope = (actions: unknown[]) => ({ schemaVersion: 1, snapshotID: graph.id, actions });

describe("selection context", () => {
  it("is stable across time and ordering, and does not serialize the local root", () => {
    const a = createWorkContext({ ...input, observedAt: "first" }), b = createWorkContext({ ...input, selectedPaths: [...input.selectedPaths].reverse(), observedAt: "later" });
    expect(a.fingerprint).toBe(b.fingerprint); expect(JSON.stringify(a)).not.toContain(input.repositoryPath);
    expect(a.fingerprint).toBe("cef08fad");
    expect(a.selectedPaths).toEqual(["src/a.ts", "src/b.ts"]);
    expect(createWorkContext({ ...input, repositoryPath: "C:\\fixture\\workspace" }).fingerprint).toBe(a.fingerprint);
  });
  it("changes for repository, head, selected revision, scope, screen, paths and graph selection", () => {
    const base = createWorkContext(input).fingerprint;
    for (const changed of [{ repositoryPath: "C:/fixture/other" }, { head: "b".repeat(40) }, { revision: "b".repeat(40) }, { scope: "staged" as const }, { screenID: "code" }, { selectedPaths: ["other.ts"] }, { selectedNodeIDs: [] }]) expect(createWorkContext({ ...input, ...changed }).fingerprint).not.toBe(base);
  });
  it("omits secret, escaping and malformed paths", () => {
    const bad = ["../outside", "/outside", "a/../b", "C:/private", ".env", ".env.local", ".git/config", ".aws/config", ".npmrc", ".ssh/id_rsa", "id_ed25519.pub", "secret.key", "a\\b", "a\nb"];
    expect(bad.filter(workContextPath)).toEqual([]);
    expect(createWorkContext({ ...input, selectedPaths: [...bad, "src/safe.ts"] }).selectedPaths).toEqual(["src/safe.ts"]);
  });
});

describe("typed graph actions", () => {
  it("accepts known nodes, directed paths and clear without executing code", () => {
    expect(validateWorkGraphActions(envelope([{ kind: "nodes", nodeIDs: ["src/a.ts", "src/c.ts"] }, { kind: "path", nodeIDs: ["src/a.ts", "src/b.ts"] }, { kind: "clear" }]), graph)?.actions).toHaveLength(3);
  });
  it("rejects stale snapshots, unknown nodes, reverse or disconnected paths and executable properties atomically", () => {
    const invalid = [
      { ...envelope([]), snapshotID: "old" }, { ...envelope([]), schemaVersion: true },
      envelope([{ kind: "nodes", nodeIDs: ["missing.ts"] }]), envelope([{ kind: "path", nodeIDs: ["src/b.ts", "src/a.ts"] }]),
      envelope([{ kind: "path", nodeIDs: ["src/a.ts", "src/c.ts"] }]), envelope([{ kind: "nodes", nodeIDs: ["src/a.ts", "src/a.ts"] }]),
      envelope([{ kind: "clear", command: "anything" }]), envelope([{ kind: "shell", nodeIDs: ["src/a.ts"] }]),
      envelope([{ kind: "nodes", nodeIDs: ["src/a.ts"] }, { kind: "nodes", nodeIDs: ["missing.ts"] }]),
      { ...envelope([]), command: "anything" }, envelope(Array.from({ length: 13 }, () => ({ kind: "clear" }))),
    ];
    for (const value of invalid) expect(validateWorkGraphActions(value, graph)).toBeNull();
  });
  it("validates bounded snapshots before exposing them to AI", () => {
    expect(parseWorkGraphSnapshot(JSON.stringify(graph))).toEqual(graph);
    expect(parseWorkGraphSnapshot("{cut off")).toBeNull();
    expect(parseWorkGraphSnapshot(JSON.stringify({ ...graph, nodeIDs: ["src/a.ts", "src/a.ts"] }))).toBeNull();
    expect(parseWorkGraphSnapshot(JSON.stringify({ ...graph, edges: [{ source: "missing.ts", target: "src/a.ts" }] }))).toBeNull();
  });
});

describe("task starters and maintained screen links", () => {
  it("renders editable tasks with concrete scope and paths without sending anything", () => {
    expect(new Set(workPrompts.map((prompt) => prompt.id)).size).toBe(workPrompts.length);
    expect(workPrompts.length).toBeGreaterThanOrEqual(5);
    for (const prompt of workPrompts) { const text = renderWorkPrompt(prompt.id, createWorkContext(input)); expect(text).toContain("src/a.ts"); expect(text).toContain("worktree"); expect(text).toContain("changes"); }
    expect(renderWorkPrompt("missing", createWorkContext(input))).toBe("");
    const context = createWorkContext(input), instruction = workPromptTemplate(renderWorkPrompt("impact", context), context);
    const next = renderWorkPrompt("impact", { ...context, selectedPaths: ["new.ts"] }, undefined, "Custom instruction: " + instruction);
    expect(next).toContain("Custom instruction"); expect(next).toContain("new.ts"); expect(next).not.toContain("src/a.ts");
  });
  it("maps actual source files on both platforms and mirrors the Swift registry", () => {
    const swift = readFileSync(resolve("../macos/Sources/Core/ScreenCodeMap.swift"), "utf8");
    for (const entry of screenCodeMap) {
      expect(entry.macOS.length).toBeGreaterThan(0); expect(entry.windows.length).toBeGreaterThan(0);
      expect(swift).toContain(`screenID: "${entry.screenID}"`);
      for (const path of [...entry.macOS, ...entry.windows, ...entry.tests]) { expect(existsSync(resolve("..", path)), path).toBe(true); expect(swift, path).toContain(`"${path}"`); }
    }
  });
});
