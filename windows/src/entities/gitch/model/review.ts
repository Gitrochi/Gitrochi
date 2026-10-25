/** CLI가 스테이지 내용과 HEAD를 비교한 결과. 삭제한 파일의 이전 의존 관계도 포함한다. */
export interface GraphReview {
  schemaVersion: 1;
  tool: "gitch graph review";
  scope: "staged";
  stamp: string;
  snapshot: string;
  headSha: string;
  branch: string;
  stale: boolean;
  changed: { path: string; status: string; oldPath?: string; analyzed: boolean }[];
  direct: GraphReviewImpact[];
  indirect: GraphReviewImpact[];
  tests: { path: string; kind: "dependency" | "name"; depth: number; heuristic: boolean }[];
  coverage: { changed: number; analyzed: number; unsupported: number };
  limitations: string[];
}

/** 변경 파일까지의 경로와 추정 여부를 함께 보여 주는 영향 파일. */
export interface GraphReviewImpact {
  path: string;
  depth: number;
  via: string[];
  heuristic: boolean;
}

/** 스테이지와 HEAD가 분석 당시 그대로인지 확인하는 저비용 응답. */
export interface GraphReviewStamp {
  schemaVersion: 1;
  scope: "staged";
  stamp: string;
  headSha: string;
}

const record = (v: unknown): v is Record<string, unknown> => !!v && typeof v === "object" && !Array.isArray(v);
const text = (v: unknown): v is string => typeof v === "string" && v.length > 0;
const count = (v: unknown): v is number => typeof v === "number" && Number.isSafeInteger(v) && v >= 0;
const strings = (v: unknown): v is string[] => Array.isArray(v) && v.every(text);
const impact = (v: unknown): v is GraphReviewImpact => record(v) && text(v.path) && count(v.depth) && strings(v.via) && typeof v.heuristic === "boolean";

/** 잘못된 출력은 분석 실패로 처리한다. 영향이 없는 빈 결과로 보이지 않게 한다. */
export function parseGraphReview(raw: string): GraphReview | null {
  try {
    const o: unknown = JSON.parse(raw);
    if (!record(o) || o.schemaVersion !== 1 || o.tool !== "gitch graph review" || o.scope !== "staged"
      || !text(o.stamp) || !text(o.snapshot) || typeof o.headSha !== "string" || typeof o.branch !== "string" || typeof o.stale !== "boolean"
      || !Array.isArray(o.changed) || !o.changed.every((c) => record(c) && text(c.path) && text(c.status) && typeof c.analyzed === "boolean" && (c.oldPath === undefined || text(c.oldPath)))
      || !Array.isArray(o.direct) || !o.direct.every(impact) || !Array.isArray(o.indirect) || !o.indirect.every(impact)
      || !Array.isArray(o.tests) || !o.tests.every((c) => record(c) && text(c.path) && (c.kind === "dependency" || c.kind === "name") && count(c.depth) && typeof c.heuristic === "boolean")
      || !record(o.coverage) || !count(o.coverage.changed) || !count(o.coverage.analyzed) || !count(o.coverage.unsupported)
      || !Array.isArray(o.limitations) || !o.limitations.every((s) => typeof s === "string")) return null;
    return o as unknown as GraphReview;
  } catch { return null; }
}

/** 다른 범위의 응답을 스테이지 분석의 유효성 확인에 쓰지 않는다. */
export function parseGraphReviewStamp(raw: string): GraphReviewStamp | null {
  try {
    const o: unknown = JSON.parse(raw);
    return record(o) && o.schemaVersion === 1 && o.scope === "staged" && text(o.stamp) && typeof o.headSha === "string" ? o as unknown as GraphReviewStamp : null;
  } catch { return null; }
}
