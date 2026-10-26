import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import vm from "node:vm";

const script = readFileSync(process.env.GITCH_ARCHITECTURE_SOURCE || new URL("../gitch", import.meta.url), "utf8");
const fragment = script.match(/\/\/ BEGIN architecture metrics\n([\s\S]*?)\/\/ END architecture metrics/);
assert.ok(fragment, "The offline graph must contain the architecture metrics implementation");
const architectureMetrics = vm.runInNewContext(fragment[1] + "\narchitectureMetrics;", { Set, Map });
const files = (...paths) => paths.map(path => ({ id: path, path, kind: "file" }));
const edge = (source, target, data = {}) => ({ source, target, kind: "import", ...data });
const group = (result, id) => result.groupMap.get(id);

// Different evidence kinds for the same directed file pair describe one dependency.
test("counts internal and boundary dependencies without duplicate evidence or weights", () => {
  const nodes = [...files("a/one.ts", "a/two.ts", "b/one.ts", "c/one.ts", "isolated.ts"), { id: "npm:x", kind: "package" }];
  const result = architectureMetrics({ nodes, depth: 1, edges: [
    edge("a/one.ts", "a/two.ts"), edge("a/one.ts", "a/two.ts", { kind: "type-ref", heuristic: true, weight: 40 }),
    edge("a/one.ts", "b/one.ts"), edge("a/two.ts", "b/one.ts"), edge("c/one.ts", "a/one.ts"),
    edge("a/one.ts", "a/one.ts"), edge("a/one.ts", "npm:x"),
    edge("a/two.ts", "c/one.ts", { kind: "contains" }), edge("b/one.ts", "c/one.ts", { kind: "cochange" })
  ] });
  assert.equal(result.totals.dependencies, 4); assert.equal(result.totals.inferred, 0);
  assert.equal(result.totals.boundary, 3); assert.equal(result.totals.internal, 1);
  const a = group(result, "a");
  assert.equal(a.fileCount, 2); assert.equal(a.internalCount, 1); assert.equal(a.density, 0.5);
  assert.equal(a.outgoingCount, 2); assert.equal(a.efferent, 1); assert.equal(a.afferent, 1);
  assert.equal(a.internalShare, 1 / 3); assert.equal(a.instability, 0.5);
  assert.equal(result.boundaryPairs[0].count, 2);
  assert.equal(group(result, ".").internalShare, null); assert.equal(group(result, ".").density, null);
  assert.equal(group(result, ".").instability, null);
  assert.equal(group(result, "b").instability, 0); assert.equal(group(result, "c").instability, 1);
});

test("inference exclusion includes checked guesses and retains independent verified evidence", () => {
  const nodes = files("a/one.ts", "b/one.ts", "c/one.ts");
  const edges = [edge("a/one.ts", "b/one.ts", { heuristic: true, checked: true }),
    edge("a/one.ts", "b/one.ts", { kind: "ref" }), edge("b/one.ts", "c/one.ts", { confidence: "heuristic" })];
  const full = architectureMetrics({ nodes, edges, depth: 1 });
  const verified = architectureMetrics({ nodes, edges, depth: 1, includeInferred: false });
  assert.equal(full.totals.dependencies, 2); assert.equal(full.totals.inferred, 1);
  assert.equal(verified.totals.dependencies, 1); assert.equal(verified.edges[0].inferred, false);
  assert.equal(group(verified, "c").instability, null);
});

test("scope and visible IDs describe an induced subgraph without sibling-prefix collisions", () => {
  const nodes = files("src/a/one.ts", "src/a/nested/two.ts", "src/abc/one.ts", "tests/one.ts");
  const edges = [edge(nodes[0].id, nodes[1].id), edge(nodes[0].id, nodes[2].id), edge(nodes[3].id, nodes[0].id)];
  const scoped = architectureMetrics({ nodes, edges, scope: "src/a/", depth: 3 });
  assert.equal(scoped.totals.files, 2); assert.equal(scoped.totals.dependencies, 1);
  assert.equal(scoped.totals.boundary, 1); assert.equal(group(scoped, "src/a").efferent, 1);
  const filtered = architectureMetrics({ nodes, edges, visibleIds: new Set([nodes[0].id, nodes[2].id]), depth: 2 });
  assert.equal(filtered.totals.files, 2); assert.equal(filtered.totals.dependencies, 1);
  assert.equal(group(filtered, "src/a").density, null);
  const disconnected = architectureMetrics({ nodes, edges, includeNode: n => n.id.startsWith("src/a/"), includeEdge: () => false });
  assert.equal(group(disconnected, "src/a").density, 0); assert.equal(group(disconnected, "src/a").internalShare, null);
});

test("reports directed group cycles separately from internal file cycles", () => {
  const nodes = files("a/one.ts", "a/two.ts", "b/one.ts", "c/one.ts", "d/one.ts");
  const edges = [edge(nodes[0].id, nodes[1].id), edge(nodes[1].id, nodes[0].id), edge(nodes[0].id, nodes[2].id),
    edge(nodes[2].id, nodes[3].id), edge(nodes[3].id, nodes[0].id), edge(nodes[3].id, nodes[4].id)];
  const result = architectureMetrics({ nodes, edges, depth: 1 });
  assert.equal(result.cycles.length, 1); assert.equal(Array.from(result.cycles[0]).join(","), "a,b,c");
  assert.equal(group(result, "a").cycleIndex, 0); assert.equal(group(result, "d").cycleIndex, null);
  assert.equal(group(result, "a").density, 1);
});

test("supports graph wrappers and does not mutate input graph records", () => {
  const data = files("a/one.ts", "b/two.ts").map(n => Object.freeze(n));
  const nodes = data.map(d => Object.freeze({ id: d.id, d, kind: d.kind }));
  const edges = [Object.freeze({ s: nodes[0], t: nodes[1], d: Object.freeze({ kind: "ref", heuristic: true }), kind: "ref", h: true })];
  assert.equal(architectureMetrics({ nodes, edges }).totals.dependencies, 1);
  assert.equal(architectureMetrics({ nodes, edges, includeInferred: false }).totals.dependencies, 0);
});

test("manifest path grouping uses deepest unique owner and flags ambiguous membership", () => {
  const nodes = files("packages/a/one.ts", "packages/a/deep/two.ts", "shared/one.swift", "other/one.ts");
  const modules = [{ id: "a", kind: "module", path: "packages/a", local: true },
    { id: "nested", kind: "module", path: "packages/a/deep", local: true },
    { id: "sharedA", kind: "module", path: "shared", local: true }, { id: "sharedB", kind: "module", path: "shared", local: true },
    { id: "remote", kind: "module", path: ".", local: false }];
  const result = architectureMetrics({ nodes, modules, mode: "modules" });
  assert.equal(group(result, "module:a").fileCount, 1); assert.equal(group(result, "module:nested").fileCount, 1);
  assert.equal(group(result, "folder:shared").fileCount, 1); assert.equal(group(result, "folder:other").fileCount, 1);
  assert.equal(result.excluded.ambiguousFiles, 1); assert.equal(result.excluded.unassignedFiles, 1);
});

test("iterative graph analysis handles long group chains without stack overflow", () => {
  const nodes = Array.from({ length: 15000 }, (_, n) => ({ id: `g${n}/file.ts`, kind: "file" }));
  const edges = nodes.slice(1).map((n, i) => edge(nodes[i].id, n.id));
  const result = architectureMetrics({ nodes, edges, depth: 1 });
  assert.equal(result.totals.files, 15000); assert.equal(result.totals.boundary, 14999); assert.equal(result.cycles.length, 0);
});


test("invalid scopes and external file records cannot expand the measured repository", () => {
  const nodes = [...files("src/one.ts", "src/two.ts"), { id: "external.ts", kind: "file", local: false },
    { id: "outside.ts", kind: "file", outside: true }];
  const edges = [edge("src/one.ts", "src/two.ts"), edge("src/one.ts", "external.ts"), edge("src/one.ts", "outside.ts")];
  assert.equal(architectureMetrics({ nodes, edges }).totals.files, 2);
  assert.equal(architectureMetrics({ nodes, edges }).totals.dependencies, 1);
  assert.equal(architectureMetrics({ nodes, edges, scope: "../other" }).totals.files, 0);
  assert.equal(architectureMetrics({ nodes, edges, scope: "/absolute" }).totals.dependencies, 0);
});
