import { describe, expect, it } from "vitest";
import { shareHeights } from "@/shared/lib/share-heights";

describe("panes sharing a column's height", () => {
  it("gives short panes their height and splits the rest between the long ones", () => {
    expect(shareHeights([2000, 1500, 120, 60], 800, 96)).toEqual([310, 310, 120, 60]);
  });
  it("fits everything when there is room", () => {
    expect(shareHeights([100, 200], 800, 96)).toEqual([100, 200]);
  });
  it("never goes under the floor, even if the column then scrolls", () => {
    expect(shareHeights([500, 500], 100, 96)).toEqual([96, 96]);
  });
  it("a pane shorter than the floor keeps its own height", () => {
    expect(shareHeights([40, 900], 300, 96)).toEqual([40, 260]);
  });
});
