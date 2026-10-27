

export const LANE_W = 22;
export const ROW_H = 30;
export const LEFT_PAD = 6;
/** Room between the last lane's avatar and the message bar; the lane band runs through it */
const RIGHT_PAD = 16;
const MAX_LANES = 16;
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

/** 그래프 행의 칸: 브랜치·태그, 그래프, 커밋 메시지(제목 + 본문 첫 줄 + 오른쪽 끝에 시간) */
export interface GraphColumns {
  ref: number;
  graph: number;
  /** 오른쪽 끝의 시간 */
  time: boolean;
}

const MESSAGE_MIN = 200;
const REF_MIN = 110;
const GRAPH_MIN = 66;

/** The columns the user can turn off (settings graphHiddenColumns); the message column always shows */
export type GraphColumnId = "ref" | "graph" | "time";

/** 좁으면 시간을 숨기고, 브랜치 칸, 그래프 칸(오른쪽 레인은 잘림) 순으로 줄여 메시지 칸을 지킨다. A column turned off has width 0. */
export function graphColumns(width: number, graph: number, hidden: ReadonlySet<string> = new Set()): GraphColumns {
  const c: GraphColumns = { ref: hidden.has("ref") ? 0 : REF_W, graph: hidden.has("graph") ? 0 : graph, time: !hidden.has("time") };
  // 메시지 앞 막대·여백 20, 행 오른쪽 여백 12, 시간 칸 90
  const short = () => MESSAGE_MIN - (width - (c.ref + c.graph + 32 + (c.time ? 90 : 0)));
  if (short() > 0) c.time = false;
  if (short() > 0 && c.ref > 0) c.ref = Math.max(REF_MIN, c.ref - short());
  if (short() > 0 && c.graph > 0) c.graph = Math.max(Math.min(graph, GRAPH_MIN), c.graph - short());
  return c;
}
