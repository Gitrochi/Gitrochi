import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import vm from "node:vm";

const source = readFileSync(process.env.GITCH_LAYOUT_SOURCE || new URL("../gitch", import.meta.url), "utf8");
const functions = ["forest", "radialTargets", "treeTargets"].map(name => {
  const fragment = source.match(new RegExp(`  function ${name}\\([\\s\\S]*?(?=\\n  function )`));
  assert.ok(fragment, `The offline graph must contain ${name}`);
  return fragment[0];
}).join("\n");

function layouts(nodes, pairs, boxes) {
  const edges = pairs.map(([source, target]) => ({ s: nodes[source], t: nodes[target] }));
  return vm.runInNewContext(functions + "\n({ treeTargets, radialTargets });", {
    Map, Set, Math, visNodes: nodes, visEdges: edges, box: () => boxes
  });
}

function node(id, index = 0) {
  return { id, label: id.split("/").pop(), kind: "file", r: 4 + index,
    w: 54 + index * 9, h: 22 + index % 3 * 4, lw: 20 + index * 8 };
}

// Captured before replacing recursive traversal: preserve sibling, root and cycle placement.
const expected = {
  dot: {
    treeTargets: [["folder/b.ts",295,0],["folder/deep/c.ts",295,28],["folder/a.ts",173,14],["z.ts",173,56],
      ["root.ts",0,35],["isolated.ts",0,100.8],["other/leaf.ts",173,145.6],["other/root.ts",0,145.6]],
    radialTargets: [["root.ts",66.57395614066074,21.631189606246316],["folder/a.ts",133.14791228132148,-43.26237921249263],
      ["folder/b.ts",123.43490298141936,-169.89356881873897],["folder/deep/c.ts",199.72186842198224,64.89356881873896],
      ["z.ts",0,140],["isolated.ts",-66.57395614066074,21.631189606246327],
      ["other/root.ts",-41.14496766047313,-56.631189606246316],["other/leaf.ts",-82.28993532094626,-113.26237921249263]]
  },
  box: {
    treeTargets: [["folder/b.ts",331.5,0],["folder/deep/c.ts",331.5,42],["folder/a.ts",172.5,21],["z.ts",172.5,84],
      ["root.ts",0,52.5],["isolated.ts",0,151.2],["other/leaf.ts",172.5,218.4],["other/root.ts",0,218.4]],
    radialTargets: [["root.ts",101.30434392618021,32.915776655568344],["folder/a.ts",186.89943039274402,-60.727306149313605],
      ["folder/b.ts",168.41087316703351,-231.7976810378688],["folder/deep/c.ts",272.49451685930785,88.53883564305887],
      ["z.ts",0,196.51769078961985],["isolated.ts",-101.30434392618021,32.91577665556836],
      ["other/root.ts",-62.60952775438836,-86.17462205037826],["other/leaf.ts",-115.51020046071095,-158.98615154412352]]
  }
};

for (const boxes of [false, true]) {
  const shape = boxes ? "box" : "dot";
  test(`${shape} hierarchy layouts preserve the existing small-graph coordinates`, () => {
    const paths = ["root.ts", "z.ts", "folder/a.ts", "folder/b.ts", "folder/deep/c.ts",
      "other/root.ts", "other/leaf.ts", "isolated.ts"];
    const nodes = paths.map(node); nodes[2].kind = "folder";
    const layout = layouts(nodes, [[0,2],[0,1],[2,3],[2,4],[5,6],[6,5]], boxes);
    for (const name of ["treeTargets", "radialTargets"]) {
      const actual = [...layout[name]()];
      assert.equal(actual.length, expected[shape][name].length);
      actual.forEach(([record, coordinates], index) => {
        const [id, x, y] = expected[shape][name][index];
        assert.equal(record.id, id, `${name} traversal order`);
        assert.ok(Math.abs(coordinates[0] - x) < 1e-9, `${name} x for ${id}`);
        assert.ok(Math.abs(coordinates[1] - y) < 1e-9, `${name} y for ${id}`);
      });
    }
  });

  test(`${shape} hierarchy layouts handle 15,000-node dependency chains`, () => {
    const nodes = Array.from({ length: 15000 }, (_, index) => node(`chain/${index}.ts`));
    const pairs = nodes.slice(1).map((_, index) => [index, index + 1]);
    const layout = layouts(nodes, pairs, boxes);
    for (const name of ["treeTargets", "radialTargets"]) {
      const positions = layout[name]();
      assert.equal(positions.size, nodes.length);
      assert.ok([...positions.values()].every(position => position.every(Number.isFinite)), name);
      const first = positions.get(nodes[0]), last = positions.get(nodes.at(-1));
      assert.ok(Math.hypot(...last) > Math.hypot(...first), `${name} keeps dependency depth`);
    }
  });
}

test("empty and isolated hierarchy layouts keep finite coordinates", () => {
  for (const nodes of [[], [node("single.ts")], [node("one.ts"), node("two.ts")]]) {
    const layout = layouts(nodes, [], false);
    for (const name of ["treeTargets", "radialTargets"]) {
      const positions = layout[name]();
      assert.equal(positions.size, nodes.length);
      assert.ok([...positions.values()].every(position => position.every(Number.isFinite)), name);
    }
  }
});
