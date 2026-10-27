import { describe, expect, it } from "vitest";
import { clampLaneOffset, graphColumns, graphFullWidth, graphWidth, LANE_W, LEFT_PAD, laneOffsetForThumb, laneThumb, revealLaneOffset } from "@/widgets/commit-graph/lib/metrics";

describe("graph lane scrolling", () => {
  it("measures every lane while the column stays capped", () => {
    expect(graphFullWidth(10)).toBe(graphWidth(10));
    expect(graphFullWidth(30)).toBe(30 * LANE_W + LEFT_PAD + 16);
    expect(graphFullWidth(30)).toBeGreaterThan(graphWidth(30));
    expect(graphFullWidth(0)).toBe(44);
  });
  it("keeps the offset between 0 and what does not fit", () => {
    expect(clampLaneOffset(-20, 100)).toBe(0);
    expect(clampLaneOffset(40.6, 100)).toBe(41);
    expect(clampLaneOffset(500, 100)).toBe(100);
    expect(clampLaneOffset(30, 0)).toBe(0);
    expect(clampLaneOffset(30, -10)).toBe(0);
  });
  it("moves as little as possible to show a lane's node", () => {
    const visible = 200, overflow = 400;
    expect(revealLaneOffset(0, 3, visible, overflow)).toBe(0);
    expect(revealLaneOffset(100, 2, visible, overflow)).toBe(2 * LANE_W);
    expect(revealLaneOffset(0, 12, visible, overflow)).toBe(LEFT_PAD * 2 + 13 * LANE_W - visible);
    expect(revealLaneOffset(0, 40, visible, overflow)).toBe(overflow);
    expect(revealLaneOffset(150, 0, visible, overflow)).toBe(0);
  });
  it("sizes the thumb by visible over total and places it by the offset", () => {
    expect(laneThumb(0, 300, 300, 288)).toEqual({ size: 288, start: 0 });
    expect(laneThumb(0, 300, 600, 288)).toEqual({ size: 144, start: 0 });
    expect(laneThumb(300, 300, 600, 288)).toEqual({ size: 144, start: 144 });
    expect(laneThumb(150, 300, 600, 288)).toEqual({ size: 144, start: 72 });
    expect(laneThumb(0, 60, 6000, 48).size).toBe(24);
    expect(laneOffsetForThumb(72, 288, 144, 300)).toBe(150);
    expect(laneOffsetForThumb(-10, 288, 144, 300)).toBe(0);
    expect(laneOffsetForThumb(999, 288, 144, 300)).toBe(300);
    expect(laneOffsetForThumb(10, 100, 100, 300)).toBe(0);
  });
});
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
