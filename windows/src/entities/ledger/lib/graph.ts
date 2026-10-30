import type { LedgerGraph, LedgerGraphEdge, LedgerGraphNode } from "../model/types";

// The commit graph's metrics, so both graphs read alike (widgets/commit-graph/lib/metrics.ts; macOS: GraphMetrics)
export const GRAPH_LANE_W = 22;
export const GRAPH_ROW_H = 30;
export const GRAPH_LEFT_PAD = 6;
const GRAPH_RIGHT_PAD = 16;

export interface PlacedNode {
  node: LedgerGraphNode;
  row: number;
  x: number;
  y: number;
}

export interface PlacedPath {
  /** SVG path data */
  d: string;
  /** Lane palette index (shared/lib laneColor) */
  color: number;
  dashed: boolean;
  /** Vertical extent, to draw only what is on screen */
  top: number;
  bottom: number;
  kind: LedgerGraphEdge["kind"] | "tail";
}

export interface GraphPlot {
  nodes: PlacedNode[];
  paths: PlacedPath[];
  width: number;
  height: number;
  /** Node id → placed node */
  byId: Map<string, PlacedNode>;
}

export const laneX = (lane: number) => GRAPH_LEFT_PAD + GRAPH_LANE_W * (lane + 0.5);
export const rowY = (row: number) => GRAPH_ROW_H * row + GRAPH_ROW_H / 2;
export const graphPlotWidth = (lanes: number) => Math.max(44, lanes * GRAPH_LANE_W + GRAPH_LEFT_PAD + GRAPH_RIGHT_PAD);

const curve = (ax: number, ay: number, bx: number, by: number) => {
  const mid = (ay + by) / 2;
  return `C${ax},${mid} ${bx},${mid} ${bx},${by}`;
};

/**
 * The path of one edge, in the commit graph's style: same lane is a straight line; a branch leaves its baseline with a
 * curve into the session's lane and then rises straight; a merge rises in the session's lane and curves into the trunk
 * in the last row. Hand-offs, and joins that point back in time, are one direct curve.
 */
export function edgePath(a: PlacedNode, b: PlacedNode, kind: LedgerGraphEdge["kind"]): string {
  const { x: ax, y: ay } = a, { x: bx, y: by } = b;
  if (ax === bx) return `M${ax},${ay}L${bx},${by}`;
  const rises = by < ay - GRAPH_ROW_H;
  if (kind === "branch" && rises) return `M${ax},${ay}${curve(ax, ay, bx, ay - GRAPH_ROW_H)}L${bx},${by}`;
  if (kind === "merge" && rises) return `M${ax},${ay}L${ax},${by + GRAPH_ROW_H}${curve(ax, by + GRAPH_ROW_H, bx, by)}`;
  return `M${ax},${ay}${curve(ax, ay, bx, by)}`;
}

/** Newest first; at the same time the trunk comes first, then by lane and id, so the order never flickers */
const rowOrder = (a: LedgerGraphNode, b: LedgerGraphNode) => b.ts - a.ts || a.lane - b.lane || a.id.localeCompare(b.id);

/**
 * Rows and paths for a contract `Graph`: one row per node, newest on top, lane 0 the baseline trunk. A session whose
 * newest node is neither an end nor a merge is still open, so its lane continues upward as a dashed tail.
 * (macOS: LedgerGraphLayout.plot)
 */
export function plotLedgerGraph(graph: LedgerGraph): GraphPlot {
  const nodes = [...graph.nodes].sort(rowOrder).map((node, row) => ({ node, row, x: laneX(node.lane), y: rowY(row) }));
  const byId = new Map(nodes.map((p) => [p.node.id, p]));
  const paths: PlacedPath[] = [];
  for (const edge of graph.edges) {
    const a = byId.get(edge.from), b = byId.get(edge.to);
    if (!a || !b) continue;
    paths.push({ d: edgePath(a, b, edge.kind), color: edge.color, dashed: edge.kind === "handoff", top: Math.min(a.y, b.y), bottom: Math.max(a.y, b.y), kind: edge.kind });
  }
  const newest = new Map<string, PlacedNode>();
  for (const p of nodes) if (p.node.sessionId && !newest.has(p.node.sessionId)) newest.set(p.node.sessionId, p);
  for (const p of newest.values()) {
    if (p.node.kind === "end" || p.node.kind === "merge" || p.row === 0) continue;
    paths.push({ d: `M${p.x},${p.y}L${p.x},0`, color: p.node.color, dashed: true, top: 0, bottom: p.y, kind: "tail" });
  }
  let lanes = Math.max(graph.lanes, 1);
  for (const p of nodes) lanes = Math.max(lanes, p.node.lane + 1);
  return { nodes, paths, width: graphPlotWidth(lanes), height: nodes.length * GRAPH_ROW_H, byId };
}

/** Rows to draw for a scroll position, with some rows above and below so scrolling never shows a gap */
export function visibleRows(scrollTop: number, viewport: number, count: number, rowHeight = GRAPH_ROW_H, overscan = 10): { first: number; last: number } {
  const first = Math.max(0, Math.floor(scrollTop / rowHeight) - overscan);
  const last = Math.min(count, Math.ceil((scrollTop + viewport) / rowHeight) + overscan);
  return { first, last: Math.max(first, last) };
}

/** The paths that cross a vertical band of the plot */
export const pathsInBand = (paths: readonly PlacedPath[], top: number, bottom: number) => paths.filter((p) => p.bottom >= top && p.top <= bottom);
