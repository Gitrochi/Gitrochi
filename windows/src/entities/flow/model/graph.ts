/** Bounded dependency layout, mirrored by macOS FlowGraphLayout.swift. */
export function layoutFlowGraph(nodes: readonly { id: string; needs: readonly string[] }[]) {
  const seen = new Set<string>();
  const unique = nodes.filter((node) => { if (seen.has(node.id)) return false; seen.add(node.id); return true; });
  const known = new Set(unique.map((node) => node.id));
  const levels = new Map<string, number>();
  const indegree = new Map<string, number>();
  const dependants = new Map<string, string[]>();
  const dependencies = new Map<string, string[]>();
  for (const node of unique) {
    const needs = [...new Set(node.needs)].filter((id) => known.has(id));
    dependencies.set(node.id, needs);
    indegree.set(node.id, needs.length);
    for (const id of needs) {
      const children = dependants.get(id) ?? [];
      children.push(node.id);
      dependants.set(id, children);
    }
  }
  const queue = unique.filter((node) => indegree.get(node.id) === 0).map((node) => node.id);
  let maxLevel = -1;
  for (let cursor = 0; cursor < queue.length; cursor++) {
    const id = queue[cursor];
    const level = (dependencies.get(id) ?? []).reduce((max, dependency) => Math.max(max, levels.get(dependency) ?? -1), -1) + 1;
    levels.set(id, level);
    maxLevel = Math.max(maxLevel, level);
    for (const child of dependants.get(id) ?? []) {
      const count = (indegree.get(child) ?? 1) - 1;
      indegree.set(child, count);
      if (count === 0) queue.push(child);
    }
  }
  const remaining = unique.filter((node) => !levels.has(node.id));
  for (const node of remaining) levels.set(node.id, maxLevel + 1);
  const columns = new Map<number, number>();
  let width = 500, height = 260;
  const positioned = unique.map((node) => {
    const column = levels.get(node.id) ?? 0;
    const row = columns.get(column) ?? 0;
    columns.set(column, row + 1);
    const x = 32 + column * 284, y = 32 + row * 148;
    width = Math.max(width, x + 260);
    height = Math.max(height, y + 142);
    return { id: node.id, column, row, x, y };
  });
  return {
    nodes: positioned,
    edges: unique.flatMap((node) => (dependencies.get(node.id) ?? []).map((from) => ({ from, to: node.id }))),
    unresolved: remaining.map((node) => node.id),
    missing: unique.flatMap((node) => node.needs.filter((id) => !known.has(id)).map((id) => ({ node: node.id, dependency: id }))),
    width,
    height,
  };
}

/** Keep the content under the pointer fixed while the canvas scale changes. */
export function flowZoomAnchor(oldZoom: number, nextZoom: number, scroll: { x: number; y: number }, pointer: { x: number; y: number }) {
  const zoom = Math.max(Math.min(0.25, oldZoom), Math.min(2.5, nextZoom));
  return { zoom, x: Math.max(0, (scroll.x + pointer.x) / oldZoom * zoom - pointer.x), y: Math.max(0, (scroll.y + pointer.y) / oldZoom * zoom - pointer.y) };
}

/** Overview fitting has no manual-zoom floor, so wide and tall pipelines remain complete. */
export function fitFlowGraph(width: number, height: number, viewportWidth: number, viewportHeight: number): number {
  return Math.max(0.001, Math.min(1, (viewportWidth - 24) / Math.max(1, width), (viewportHeight - 24) / Math.max(1, height)));
}
