import { describe, expect, it } from "vitest";
import { clampLaneOffset, columnWidths, DEFAULT_WIDTHS, graphColumns, graphFullWidth, graphWidth, LANE_W, LEFT_PAD, laneOffsetForThumb, laneThumb, revealLaneOffset, toggleColumn, trailingWidth } from "@/widgets/commit-graph/lib/metrics";

describe("graph lane scrolling", () => {
  it("measures every lane while the column stays capped", () => {
    // up to eight lanes the column shows them all; past that it stays eight lanes wide and scrolls
    expect(graphFullWidth(8)).toBe(graphWidth(8));
    expect(graphWidth(12)).toBe(graphWidth(8));
    expect(graphWidth(6)).toBeLessThan(graphWidth(8));
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

const msg = (w: number, c: ReturnType<typeof graphColumns>) => w - (c.ref + c.graph + 32 + trailingWidth(c));
const both = new Set(["author", "time"]);
const all = new Set(["author", "time", "sha"]);
const none = { author: 0, time: 0, sha: 0 };

describe("그래프 칸", () => {
  it("shows branches, graph and message, without author, time and SHA by default", () => {
    expect(graphColumns(1100, graphWidth(5))).toEqual({ ref: 190, graph: graphWidth(5), ...none });
  });
  it("shows author, time and SHA only when turned on, at their widths", () => {
    expect(graphColumns(1100, graphWidth(5), new Set(), both)).toEqual({ ref: 190, graph: graphWidth(5), author: 120, time: 84, sha: 0 });
    expect(graphColumns(1100, graphWidth(5), new Set(), new Set(["sha"]))).toEqual({ ref: 190, graph: graphWidth(5), author: 0, time: 0, sha: 72 });
    expect(graphColumns(1400, graphWidth(5), new Set(), all, { author: 200, time: 90, sha: 60 })).toMatchObject({ author: 200, time: 90, sha: 60 });
  });
  it("drops SHA, then time, then author, before shrinking the branch column", () => {
    const g = graphWidth(5);
    // the branch column (190), the graph, 32 around the message, 200 for it, the columns and the header's 60 for its menus
    expect(graphColumns(890, g, new Set(), all)).toMatchObject({ ref: 190, author: 120, time: 84, sha: 72 });
    expect(graphColumns(889, g, new Set(), all)).toMatchObject({ ref: 190, author: 120, time: 84, sha: 0 });
    expect(graphColumns(817, g, new Set(), all)).toMatchObject({ ref: 190, author: 120, time: 0, sha: 0 });
    expect(graphColumns(733, g, new Set(), all)).toMatchObject({ ref: 190, ...none });
    expect(graphColumns(500, g, new Set(), all)).toEqual({ ref: 136, graph: g, ...none });
  });
  it("keeps dragged widths inside each column's range and ignores anything else stored", () => {
    expect(columnWidths(undefined)).toEqual(DEFAULT_WIDTHS);
    expect(columnWidths({ author: 500, time: 10, sha: 80, ref: 9 })).toEqual({ author: 320, time: 60, sha: 80 });
    expect(columnWidths({ author: "wide", time: Number.NaN })).toEqual(DEFAULT_WIDTHS);
  });
  it("좁아지면 브랜치 칸을 줄여 메시지 칸을 지킨다", () => {
    const g = graphWidth(7);
    for (const w of [900, 800, 700, 600, 560, 520, 480]) {
      expect(msg(w, graphColumns(w, g))).toBeGreaterThanOrEqual(200);
      expect(msg(w, graphColumns(w, g, new Set(), both))).toBeGreaterThanOrEqual(200);
      expect(msg(w, graphColumns(w, g, new Set(), all))).toBeGreaterThanOrEqual(200);
    }
  });
  it("leaves out the columns the user turned off, ignoring a time column hidden by an older version", () => {
    expect(graphColumns(1100, graphWidth(5), new Set(["ref", "time"]))).toEqual({ ref: 0, graph: graphWidth(5), ...none });
    expect(graphColumns(400, graphWidth(5), new Set(["graph"]))).toEqual({ ref: 168, graph: 0, ...none });
  });
  it("toggles a column id in a settings list", () => {
    expect(toggleColumn([], "author")).toEqual(["author"]);
    expect(toggleColumn(["author", "time"], "author")).toEqual(["time"]);
    expect(toggleColumn(["ref"], "graph")).toEqual(["ref", "graph"]);
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
