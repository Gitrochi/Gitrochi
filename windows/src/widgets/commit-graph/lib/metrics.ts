

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

/** 좁으면 시간을 숨기고, 브랜치 칸, 그래프 칸(오른쪽 레인은 잘림) 순으로 줄여 메시지 칸을 지킨다 */
export function graphColumns(width: number, graph: number): GraphColumns {
  const c: GraphColumns = { ref: REF_W, graph, time: true };
  // 메시지 앞 막대·여백 20, 행 오른쪽 여백 12, 시간 칸 90
  const short = () => MESSAGE_MIN - (width - (c.ref + c.graph + 32 + (c.time ? 90 : 0)));
  if (short() > 0) c.time = false;
  if (short() > 0) c.ref = Math.max(REF_MIN, c.ref - short());
  if (short() > 0) c.graph = Math.max(Math.min(graph, GRAPH_MIN), c.graph - short());
  return c;
}
