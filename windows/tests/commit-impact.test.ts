import { afterEach, describe, expect, it, vi } from "vitest";
import { gitch, type GraphReview, parseGraphReview, parseGraphReviewStamp } from "@/entities/gitch";

const review = (): GraphReview => ({
  schemaVersion: 1, tool: "gitch graph review", scope: "staged", stamp: "index-and-head", snapshot: "tree", headSha: "head", branch: "feature/a", stale: false,
  changed: [{ path: "src/core.ts", status: "M", analyzed: true }, { path: "new.ts", oldPath: "old.ts", status: "R", analyzed: true }],
  direct: [{ path: "src/view.ts", depth: 1, via: ["src/core.ts"], heuristic: false }],
  indirect: [{ path: "src/app.ts", depth: 2, via: ["src/view.ts"], heuristic: true }],
  tests: [{ path: "test/core.test.ts", kind: "dependency", depth: 1, heuristic: false }, { path: "new.test.ts", kind: "name", depth: 0, heuristic: true }],
  coverage: { changed: 2, analyzed: 2, unsupported: 0 }, limitations: ["Static references only"],
});

afterEach(() => vi.restoreAllMocks());

describe("커밋할 변경의 영향 분석", () => {
  it("staged 범위와 이름 추정·의존 테스트 후보를 구별해서 읽는다", () => {
    expect(parseGraphReview(JSON.stringify(review()))).toEqual(review());
    expect(parseGraphReviewStamp('{"schemaVersion":1,"scope":"staged","stamp":"a","headSha":""}')).toEqual({ schemaVersion: 1, scope: "staged", stamp: "a", headSha: "" });
  });

  it("다른 범위나 손상된 결과를 영향 없음으로 처리하지 않는다", () => {
    for (const change of [
      { scope: "worktree" }, { schemaVersion: 2 }, { stale: "false" }, { stamp: "" }, { direct: [null] },
      { tests: [{ path: "test.ts", kind: "passed", depth: 1, heuristic: false }] },
      { coverage: { changed: 2, analyzed: -1, unsupported: 0 } }, { limitations: [false] },
    ]) expect(parseGraphReview(JSON.stringify({ ...review(), ...change }))).toBeNull();
    for (const raw of ["not json", "null", "{}", "[]"]) expect(parseGraphReview(raw)).toBeNull();
    expect(parseGraphReviewStamp('{"schemaVersion":1,"scope":"worktree","stamp":"a","headSha":"head"}')).toBeNull();
  });

  it("staged 삭제/이름변경과 미지원 파일, 분석 중 변경된 결과를 보존한다", () => {
    const result = { ...review(), stale: true, changed: [{ path: "payload.bin", status: "D", analyzed: false }], coverage: { changed: 1, analyzed: 0, unsupported: 1 } };
    expect(parseGraphReview(JSON.stringify(result))).toEqual(result);
    const empty = { ...review(), changed: [], direct: [], indirect: [], tests: [], coverage: { changed: 0, analyzed: 0, unsupported: 0 } };
    expect(parseGraphReview(JSON.stringify(empty))).toEqual(empty);
  });

  it("요약·유효성·그래프가 모두 review 명령을 사용하며 worktree 감시는 시작하지 않는다", async () => {
    const runner = gitch as unknown as { runGraph: (args: string[], repo: string) => Promise<{ status: number; stdout: string; stderr: string }> };
    const run = vi.spyOn(runner, "runGraph");
    run.mockResolvedValueOnce({ status: 0, stdout: JSON.stringify(review()), stderr: "" });
    expect(await gitch.commitReview("C:/repo")).toEqual(review());
    expect(run).toHaveBeenLastCalledWith(["review", "--json"], "C:/repo");
    run.mockResolvedValueOnce({ status: 0, stdout: '{"schemaVersion":1,"scope":"staged","stamp":"a","headSha":"head"}', stderr: "" });
    expect(await gitch.commitReviewStamp("C:/repo")).toBe("a");
    expect(run).toHaveBeenLastCalledWith(["review", "--stamp", "--json"], "C:/repo");
    run.mockResolvedValueOnce({ status: 0, stdout: "GRAPH_FILE=x NODES=3 EDGES=2", stderr: "" });
    const page = await gitch.commitReviewGraph("C:/repo");
    expect(page.nodes).toBe(3);
    expect(page.liveUrl).toBeUndefined();
    expect(run).toHaveBeenLastCalledWith(["review", "--format", "html", "--out", page.file, "--no-open"], "C:/repo");
    expect(run).toHaveBeenCalledTimes(3);
  });
});
