import { describe, expect, it } from "vitest";
import { graphColumns, graphWidth } from "@/widgets/commit-graph/lib/metrics";
import { bodyPreview } from "@/entities/git/lib/parsers";

const msg = (w: number, c: ReturnType<typeof graphColumns>) => w - (c.ref + c.graph + 32 + (c.time ? 90 : 0));

describe("그래프 칸", () => {
  it("넓으면 브랜치·그래프·메시지(+시간)", () => {
    expect(graphColumns(1100, graphWidth(5))).toEqual({ ref: 190, graph: graphWidth(5), time: true });
  });
  it("좁아지면 시간을 숨기고 브랜치 칸을 줄여 메시지 칸을 지킨다", () => {
    const g = graphWidth(7);
    for (const w of [800, 700, 600, 560, 520, 480]) expect(msg(w, graphColumns(w, g))).toBeGreaterThanOrEqual(200);
    expect(graphColumns(600, g).time).toBe(false);
  });
  it("leaves out the columns the user turned off", () => {
    expect(graphColumns(1100, graphWidth(5), new Set(["ref", "time"]))).toEqual({ ref: 0, graph: graphWidth(5), time: false });
    expect(graphColumns(400, graphWidth(5), new Set(["graph"]))).toEqual({ ref: 168, graph: 0, time: false });
  });
  it("아주 좁으면 그래프 칸도 줄이되(레인은 잘림) 너무 작게는 안 줄인다", () => {
    const c = graphColumns(420, graphWidth(14));
    expect(c.ref).toBe(110);
    expect(c.graph).toBeGreaterThanOrEqual(66);
    expect(c.graph).toBeLessThan(graphWidth(14));
  });
});

describe("본문 첫 줄", () => {
  it("꼬리말·빈 줄은 건너뛰고 글머리표는 뗀다", () => {
    expect(bodyPreview("\n- 코드의 화면 글자를 영어로\n- 두 번째\n\nCo-Authored-By: A <a@b.c>")).toBe("코드의 화면 글자를 영어로");
    expect(bodyPreview("Co-Authored-By: A <a@b.c>\nClaude-Session: https://x")).toBe("");
    expect(bodyPreview("")).toBe("");
  });
});
