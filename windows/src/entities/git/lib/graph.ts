import { type Commit, type GraphRow, type GraphSegment, isPending } from "../model/types";

/**
 * 커밋 목록(자식 → 부모 순)에 레인을 배정해 행마다 그릴 선분을 만든다. (맥 버전 Graph.swift 와 같은 알고리즘)
 *
 * 각 레인은 "다음에 나타날 것으로 기대하는 커밋"을 들고 아래로 내려간다.
 * 커밋이 나타나면 그 커밋을 기다리던 레인들이 노드로 모이고, 노드에서
 * 첫 부모는 같은 레인으로, 나머지 부모(머지)는 다른 레인으로 갈라진다.
 */
export function layoutGraph(commits: Commit[]): { rows: GraphRow[]; maxLanes: number } {
  const lanes: (string | null)[] = [];
  const colors: number[] = [];
  const dashed: boolean[] = [];
  let nextColor = 0;
  const rows: GraphRow[] = [];
  let maxLanes = 1;

  const freeSlot = (excluding?: number) => {
    for (let i = 0; i < lanes.length; i++) if (lanes[i] === null && i !== excluding) return i;
    lanes.push(null);
    colors.push(0);
    dashed.push(false);
    return lanes.length - 1;
  };

  for (const c of commits) {
    const before = lanes.slice();
    const beforeColors = colors.slice();
    const beforeDashed = dashed.slice();

    let col = lanes.indexOf(c.id);
    if (col < 0) {
      col = freeSlot();
      colors[col] = nextColor++;
    }
    const nodeColor = colors[col];
    const segs: GraphSegment[] = [];

    // 위쪽 절반: 이 커밋으로 모이는 선과 그냥 지나가는 선
    before.forEach((expected, i) => {
      if (expected === null) return;
      if (expected === c.id) segs.push({ x1: i, y1: 0, x2: col, y2: 0.5, color: beforeColors[i], dashed: beforeDashed[i] });
      else segs.push({ x1: i, y1: 0, x2: i, y2: 1, color: beforeColors[i], dashed: beforeDashed[i] });
    });
    for (let i = 0; i < lanes.length; i++) if (lanes[i] === c.id) lanes[i] = null;

    // 아래쪽 절반: 부모들로 이어지는 선
    if (c.parents.length) {
      const wip = isPending(c);
      lanes[col] = c.parents[0];
      colors[col] = nodeColor;
      dashed[col] = wip;
      segs.push({ x1: col, y1: 0.5, x2: col, y2: 1, color: nodeColor, dashed: wip });
      for (const p of c.parents.slice(1)) {
        const j = lanes.indexOf(p);
        if (j >= 0) {
          segs.push({ x1: col, y1: 0.5, x2: j, y2: 1, color: colors[j], dashed: false });
        } else {
          const k = freeSlot(col);
          lanes[k] = p;
          colors[k] = nextColor++;
          dashed[k] = false;
          segs.push({ x1: col, y1: 0.5, x2: k, y2: 1, color: colors[k], dashed: false });
        }
      }
    }

    while (lanes.length && lanes[lanes.length - 1] === null) {
      lanes.pop();
      colors.pop();
      dashed.pop();
    }
    const width = Math.max(before.length, lanes.length, col + 1);
    maxLanes = Math.max(maxLanes, width);
    rows.push({ column: col, color: nodeColor, segments: segs, width });
  }
  return { rows, maxLanes };
}
