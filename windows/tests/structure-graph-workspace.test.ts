import { afterEach, describe, expect, it, vi } from "vitest";
import { graphWorkspaceLink, structureGraphDocument } from "../src/entities/gitch/model/workspace";
import { gitch } from "../src/entities/gitch/model/gitch";

const html = '<!doctype html><html><head></head><body><script id="graph-data" type="application/json">{}</script></body></html>';
describe("structure graph workspace", () => {
  afterEach(() => vi.restoreAllMocks());
  it("embeds actions as inert escaped JSON in an offline document", () => {
    const actions = JSON.stringify({ schemaVersion: 1, snapshotID: "fixture", actions: [{ kind: "nodes", nodeIDs: ["</script><script>bad()</script>"] }] });
    const result = structureGraphDocument(html, actions);
    expect(result).toContain("connect-src 'none'");
    expect(result).toContain("base-uri 'none'");
    expect(result).toContain('id="graph-actions" type="application/json"');
    expect(result).not.toContain("<script>bad()");
    expect(result).toContain('parent.postMessage({type:"gitrochi-graph-open"');
  });
  it("rejects an unexpected document or oversized action data", () => {
    expect(() => structureGraphDocument("<h1>untrusted</h1>")).toThrow();
    expect(() => structureGraphDocument('<script id="graph-data">{}</script>')).toThrow();
    expect(() => structureGraphDocument(html, JSON.stringify("x".repeat(70_000)))).toThrow();
  });
  it("permits only matching-repository file or commit deep links", () => {
    const make = (extra = "") => "gitrochi://open?repo=C%3A%2Ffixture&view=graph" + extra;
    expect(graphWorkspaceLink(make("&file=src%2Fsafe.ts&line=2"), "C:/fixture")).not.toBeNull();
    expect(graphWorkspaceLink(make("&commit=" + "a".repeat(40)), "C:/fixture")).not.toBeNull();
    for (const url of [make("&file=..%2Fsecret"), make("&file=%2Fabsolute"), make("&file=src%5Cbad"), make("&line=0"), make("&view=terminal"), make("&command=run"), "https://example.com/", make("&commit=HEAD")]) {
      expect(graphWorkspaceLink(url, "C:/fixture")).toBeNull();
    }
    expect(graphWorkspaceLink(make(), "C:/other")).toBeNull();
  });
  it("uses the observed CLI snapshot for team paths and rejects unknown files or versions", async () => {
    const snapshotID = "a".repeat(40);
    const runner = gitch as unknown as { runGraph: (args: string[], repo: string) => Promise<{ status: number; stdout: string; stderr: string }> };
    const response = (schemaVersion = 1) => ({ status: 0, stdout: JSON.stringify({ schemaVersion, snapshotID, nodes: [{ id: "src/a.ts", kind: "file" }, { id: "pkg:npm/react", kind: "package" }] }), stderr: "" });
    const run = vi.spyOn(runner, "runGraph").mockResolvedValue(response());
    expect(JSON.parse(await gitch.graphPathSelection("C:/fixture", ["src/a.ts"]))).toEqual({ schemaVersion: 1, snapshotID, actions: [{ kind: "nodes", nodeIDs: ["src/a.ts"] }] });
    expect(run).toHaveBeenCalledWith(["files", "--json"], "C:/fixture");
    for (const paths of [["unknown.ts"], ["pkg:npm/react"], ["src/a.ts", "src/a.ts"], []]) await expect(gitch.graphPathSelection("C:/fixture", paths)).rejects.toThrow();
    run.mockResolvedValue(response(2));
    await expect(gitch.graphPathSelection("C:/fixture", ["src/a.ts"])).rejects.toThrow();
  });
});
