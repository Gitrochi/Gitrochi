

export const LANE_W = 22;
export const ROW_H = 30;
export const LEFT_PAD = 6;
/** Room between the last lane's avatar and the message bar; the lane band runs through it */
const RIGHT_PAD = 16;
// Eight lanes wide at most; more lanes scroll sideways inside the column (macOS: GraphMetrics.maxVisibleLanes)
const MAX_LANES = 8;
/** The filter and column menus at the header's right end; rows keep this much room when right-hand columns show (macOS: headerToolsWidth) */
export const HEADER_TOOLS_W = 60;
/** 왼쪽 브랜치·태그 칸 너비 */
export const REF_W = 190;
/** 커밋 동그라미(프로필) 지름 */
export const AVATAR = 20;

export const graphWidth = (lanes: number) => Math.max(44, Math.min(lanes, MAX_LANES) * LANE_W + LEFT_PAD + RIGHT_PAD);

/** The width every lane needs, without the visible-lane cap; what does not fit the column scrolls sideways */
export const graphFullWidth = (lanes: number) => Math.max(44, lanes * LANE_W + LEFT_PAD + RIGHT_PAD);

/** A lane scroll offset kept between 0 and the width that does not fit */
export const clampLaneOffset = (offset: number, overflow: number) => Math.min(Math.max(0, Math.round(offset)), Math.max(0, Math.round(overflow)));

/** The offset that brings a lane's node into a column of the given width, moving as little as possible */
export function revealLaneOffset(offset: number, lane: number, visible: number, overflow: number): number {
  const start = LANE_W * lane, end = LEFT_PAD * 2 + LANE_W * (lane + 1);
  const next = start < offset ? start : end > offset + visible ? end - visible : offset;
  return clampLaneOffset(next, overflow);
}

/** The lane scrollbar's thumb in a track: its length (visible/total, at least 24px) and where it starts */
export function laneThumb(offset: number, visible: number, total: number, track: number): { size: number; start: number } {
  const overflow = total - visible;
  if (overflow <= 0 || track <= 0) return { size: Math.max(0, track), start: 0 };
  const size = Math.min(track, Math.max(24, Math.round((track * visible) / total)));
  return { size, start: track > size ? Math.round(((track - size) * clampLaneOffset(offset, overflow)) / overflow) : 0 };
}

/** The offset for a thumb moved to a start position in its track */
export const laneOffsetForThumb = (start: number, track: number, size: number, overflow: number) =>
  track > size ? clampLaneOffset((start / (track - size)) * overflow, overflow) : 0;

/** A graph row's columns: branches and tags, the graph, the message (subject + first body line), and the optional author, time and SHA at the right end */
export interface GraphColumns {
  ref: number;
  graph: number;
  /** The optional columns' widths; 0 when off or left out for room */
  author: number;
  time: number;
  sha: number;
}

const MESSAGE_MIN = 200;
const REF_MIN = 110;
const GRAPH_MIN = 66;

/** The columns the user can turn off (settings graphHiddenColumns); the message column always shows */
export type GraphColumnId = "ref" | "graph";
/** The columns the user can turn on (settings graphShownColumns), so they stay off until chosen; in this order after the message */
export type OptionalColumnId = "author" | "time" | "sha";
export const OPTIONAL_COLUMNS: OptionalColumnId[] = ["author", "time", "sha"];
/** Widths the user can drag the optional columns to (settings graphColumnWidths) (macOS: GraphMetrics.defaultWidths, widthRange) */
export type ColumnWidths = Record<OptionalColumnId, number>;
export const DEFAULT_WIDTHS: ColumnWidths = { author: 120, time: 84, sha: 72 };
const WIDTH_RANGE: Record<OptionalColumnId, [number, number]> = { author: [60, 320], time: [60, 220], sha: [50, 140] };
/** A width kept inside the column's range */
export const clampColumnWidth = (id: OptionalColumnId, width: number) => Math.round(Math.min(Math.max(width, WIDTH_RANGE[id][0]), WIDTH_RANGE[id][1]));

/** The stored widths over the defaults, each kept inside its range; anything else stored is ignored */
export function columnWidths(stored: unknown): ColumnWidths {
  const widths = { ...DEFAULT_WIDTHS };
  if (stored && typeof stored === "object")
    for (const id of OPTIONAL_COLUMNS) {
      const value = (stored as Record<string, unknown>)[id];
      if (typeof value === "number" && Number.isFinite(value)) widths[id] = clampColumnWidth(id, value);
    }
  return widths;
}

/**
 * On narrow widths the SHA, the time and then the author drop out, then the branch and graph columns shrink (the right lanes are cut off),
 * so the message keeps its room. A column turned off has width 0; the optional ones show only when turned on.
 */
export function graphColumns(width: number, graph: number, hidden: ReadonlySet<string> = new Set(), shown: ReadonlySet<string> = new Set(), widths: ColumnWidths = DEFAULT_WIDTHS): GraphColumns {
  const optional = (id: OptionalColumnId) => (shown.has(id) ? widths[id] : 0);
  const c: GraphColumns = { ref: hidden.has("ref") ? 0 : REF_W, graph: hidden.has("graph") ? 0 : graph, author: optional("author"), time: optional("time"), sha: optional("sha") };
  // 20 for the bar and space before the message, 12 at the row's right end, the optional columns and the header's menus above them
  const short = () => MESSAGE_MIN - (width - (c.ref + c.graph + 32 + trailingWidth(c)));
  if (short() > 0) c.sha = 0;
  if (short() > 0) c.time = 0;
  if (short() > 0) c.author = 0;
  if (short() > 0 && c.ref > 0) c.ref = Math.max(REF_MIN, c.ref - short());
  if (short() > 0 && c.graph > 0) c.graph = Math.max(Math.min(graph, GRAPH_MIN), c.graph - short());
  return c;
}

/** The room the optional columns take at the row's right end, with the header's menus above them when any shows */
export function trailingWidth(c: GraphColumns) {
  const columns = c.author + c.time + c.sha;
  return columns > 0 ? columns + HEADER_TOOLS_W : 0;
}

/** A column list with one id added or removed, for the hidden and the shown column settings */
export const toggleColumn = <T extends string>(list: readonly T[], id: T): T[] => (list.includes(id) ? list.filter((x) => x !== id) : [...list, id]);
