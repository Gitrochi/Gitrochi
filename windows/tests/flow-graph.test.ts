import { describe, expect, it } from "vitest";
import { fitFlowGraph, flowZoomAnchor, layoutFlowGraph } from "../src/entities/flow/model/graph";

describe("flow dependency layout", () => {
  it("keeps the pointer anchored while zooming and clamps the supported scale", () => {
    expect(flowZoomAnchor(1, 2, { x: 100, y: 50 }, { x: 200, y: 100 })).toEqual({ zoom: 2, x: 400, y: 200 });
    expect(flowZoomAnchor(1, 0.01, { x: 0, y: 0 }, { x: 100, y: 100 })).toEqual({ zoom: 0.25, x: 0, y: 0 });
    expect(flowZoomAnchor(1, 10, { x: 100, y: 100 }, { x: 0, y: 0 }).zoom).toBe(2.5);
    expect(flowZoomAnchor(0.1, 0.08, { x: 0, y: 0 }, { x: 0, y: 0 }).zoom).toBe(0.1);
    expect(flowZoomAnchor(0.1, 0.12, { x: 0, y: 0 }, { x: 0, y: 0 }).zoom).toBe(0.12);
  });

  it("fits every column of a wide pipeline and every row of a tall pipeline below manual zoom limits", () => {
    const wide = layoutFlowGraph(Array.from({ length: 8 }, (_, index) => ({ id: String(index), needs: index ? [String(index - 1)] : [] })));
    const tall = layoutFlowGraph(Array.from({ length: 80 }, (_, index) => ({ id: String(index), needs: [] })));
    for (const graph of [wide, tall]) {
      const scale = fitFlowGraph(graph.width, graph.height, 500, 400);
      expect(scale).toBeLessThan(0.25);
      expect(graph.width * scale).toBeLessThanOrEqual(476);
      expect(graph.height * scale).toBeLessThanOrEqual(376);
    }
  });
  it("places unordered dependencies before fork and join steps", () => {
    const graph = layoutFlowGraph([{ id: "join", needs: ["test", "lint"] }, { id: "test", needs: ["setup"] }, { id: "setup", needs: [] }, { id: "lint", needs: ["setup"] }]);
    const columns = Object.fromEntries(graph.nodes.map((node) => [node.id, node.column]));
    expect(columns).toEqual({ join: 2, test: 1, setup: 0, lint: 1 });
    expect(new Set(graph.nodes.map((node) => `${node.x}:${node.y}`)).size).toBe(4);
    expect(graph.edges).toHaveLength(4);
    expect(graph.unresolved).toEqual([]);
  });

  it("keeps disconnected nodes in input order and gives every node room", () => {
    const nodes = Array.from({ length: 25 }, (_, index) => ({ id: String(index), needs: [] }));
    const graph = layoutFlowGraph(nodes);
    expect(graph.nodes.map((node) => node.row)).toEqual(nodes.map((_, index) => index));
    expect(graph.height).toBeGreaterThan(graph.nodes.at(-1)!.y + 112);
    expect(layoutFlowGraph(nodes)).toEqual(graph);
  });

  it("reports missing dependencies without drawing dangling edges", () => {
    const graph = layoutFlowGraph([{ id: "check", needs: ["missing"] }]);
    expect(graph.missing).toEqual([{ node: "check", dependency: "missing" }]);
    expect(graph.edges).toEqual([]);
    expect(graph.nodes[0].column).toBe(0);
  });

  it("terminates on cycles and puts blocked nodes after valid dependencies", () => {
    const graph = layoutFlowGraph([{ id: "setup", needs: [] }, { id: "a", needs: ["b", "setup"] }, { id: "b", needs: ["a"] }, { id: "after", needs: ["b"] }]);
    expect(graph.unresolved).toEqual(["a", "b", "after"]);
    expect(graph.nodes.slice(1).every((node) => node.column > graph.nodes[0].column)).toBe(true);
    expect(graph.nodes).toHaveLength(4);
  });

  it("deduplicates malformed IDs and repeated edges", () => {
    const graph = layoutFlowGraph([{ id: "a", needs: [] }, { id: "a", needs: ["a"] }, { id: "b", needs: ["a", "a"] }]);
    expect(graph.nodes.map((node) => node.id)).toEqual(["a", "b"]);
    expect(graph.edges).toEqual([{ from: "a", to: "b" }]);
  });
});
