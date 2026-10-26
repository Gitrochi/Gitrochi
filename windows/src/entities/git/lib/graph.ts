import { runCore, runCoreAsync } from "@/shared/core";
import { type Commit, type GraphRow, type GraphSegment, WIP_ID } from "../model/types";

type Layout = { rows: GraphRow[]; maxLanes: number };
function request(commits: Commit[]) {
  const ids = new Map<string, number>();
  const id = (key: string) => {
    let n = ids.get(key);
    if (n === undefined) { n = ids.size; ids.set(key, n); }
    return n;
  };
  const size = 1 + commits.reduce((n, c) => n + 3 + c.parents.length, 0);
  const input = new Uint32Array(size);
  input[0] = commits.length;
  let cursor = 1;
  for (const c of commits) {
    input[cursor++] = id(c.id); input[cursor++] = Number(c.id === WIP_ID); input[cursor++] = c.parents.length;
    for (const parent of c.parents) input[cursor++] = id(parent);
  }
  return { op: "graphCompact", input };
}
function decode(data: Uint32Array): Layout {
  const count = data[0], maxLanes = data[1];
  const rows: GraphRow[] = new Array(count);
  let p = 2;
  for (let i = 0; i < count; i++) {
    const column = data[p++], color = data[p++], width = data[p++], size = data[p++];
    const segments: GraphSegment[] = new Array(size);
    for (let j = 0; j < size; j++) segments[j] = { x1: data[p++], y1: data[p++] / 2, x2: data[p++], y2: data[p++] / 2, color: data[p++], dashed: !!data[p++] };
    rows[i] = { column, color, width, segments };
  }
  return { rows, maxLanes };
}
/** Mac과 같은 Rust 배치. JSON 객체를 만들지 않고 연속 정수 버퍼로 전달한다. */
export const layoutGraph = (commits: Commit[]): Layout => decode(runCore(request(commits)));
export const layoutGraphAsync = async (commits: Commit[]): Promise<Layout> => decode(await runCoreAsync(request(commits)));
