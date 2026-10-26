import { describe, expect, it } from "vitest";
import { addTab, cornerPane, paneOf, panes, removeTab, selectTab, setRatio, shownIn, splitPane, type TermNode } from "@/entities/terminal/lib/layout";

const ids = (n: TermNode) => panes(n).map((p) => p.sessions.join(","));

describe("terminal panes", () => {
  it("adds tabs to a pane and splits it right, then the right pane down", () => {
    let root = addTab(null, null, "t1");
    root = addTab(root, root.kind === "pane" ? root.id : null, "t2");
    expect(ids(root)).toEqual(["t1,t2"]);
    root = splitPane(root, paneOf(root, "t2")!.id, "row", "t3");
    root = splitPane(root, paneOf(root, "t3")!.id, "column", "t4");
    expect(ids(root)).toEqual(["t1,t2", "t3", "t4"]);
    expect(root.kind === "split" && root.axis).toBe("row");
    expect(root.kind === "split" && root.b.kind === "split" && root.b.axis).toBe("column");
    // the panel's own buttons go to the top-right pane
    expect(cornerPane(root).sessions).toEqual(["t3"]);
  });

  it("a new tab goes to the given pane, or the first one if it is gone", () => {
    let root = addTab(null, null, "t1");
    root = splitPane(root, panes(root)[0].id, "row", "t2");
    root = addTab(root, paneOf(root, "t2")!.id, "t3");
    root = addTab(root, "missing", "t4");
    expect(ids(root)).toEqual(["t1,t4", "t2,t3"]);
  });

  it("closing the last tab of a pane collapses its split", () => {
    let root: TermNode | null = addTab(null, null, "t1");
    root = splitPane(root, panes(root)[0].id, "column", "t2");
    root = splitPane(root, paneOf(root, "t2")!.id, "column", "t3");
    expect(ids(root)).toEqual(["t1", "t2", "t3"]);
    root = removeTab(root, "t2");
    expect(ids(root!)).toEqual(["t1", "t3"]);
    root = removeTab(root!, "t1");
    expect(root?.kind).toBe("pane");
    expect(ids(root!)).toEqual(["t3"]);
    expect(removeTab(root!, "t3")).toBeNull();
  });

  it("keeps a sensible selected tab and shows the focused one", () => {
    let root = addTab(addTab(addTab(null, null, "t1"), null, "t2"), null, "t3");
    root = selectTab(root, "t2");
    const p = panes(root)[0];
    expect(p.selected).toBe("t2");
    expect(shownIn(p, "t3")).toBe("t3");
    expect(shownIn(p, "elsewhere")).toBe("t2");
    root = removeTab(root, "t2")!;
    expect(panes(root)[0].selected).toBe("t3");
  });

  it("clamps the divider", () => {
    let root = addTab(null, null, "t1");
    root = splitPane(root, panes(root)[0].id, "row", "t2");
    const id = root.kind === "split" ? root.id : "";
    expect((setRatio(root, id, 0.99) as { ratio: number }).ratio).toBe(0.85);
    expect((setRatio(root, id, 0.3) as { ratio: number }).ratio).toBe(0.3);
  });
});
