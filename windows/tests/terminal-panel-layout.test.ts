import { describe, expect, it } from "vitest";
import { activity, commandHintShown, commandsFolded, compactBar, railShown, shellBusy, statusLine, tabActivity, tabMark, tabOverflow, tabStripWidth } from "@/entities/terminal/lib/panel-layout";

const idle = { exited: false, busy: false, unseen: false, waiting: false };

describe("terminal tab status marks", () => {
  it("draws a ring while running, a dot for unseen output or a waiting session, a hollow circle when exited, nothing when idle", () => {
    expect(tabMark(idle)).toBe("none");
    expect(tabMark({ ...idle, busy: true })).toBe("ring");
    expect(tabMark({ ...idle, unseen: true })).toBe("dot");
    expect(tabMark({ ...idle, waiting: true })).toBe("dot");
    expect(tabMark({ ...idle, exited: true })).toBe("hollow");
  });

  it("puts what needs the user before the running ring, and the exit before both", () => {
    expect(tabMark({ ...idle, busy: true, unseen: true })).toBe("dot");
    expect(tabMark({ ...idle, busy: true, waiting: true })).toBe("dot");
    expect(tabMark({ exited: true, busy: true, unseen: true, waiting: true })).toBe("hollow");
  });

  it("takes an agent session's status over the shell's process state", () => {
    expect(tabActivity("working", false)).toEqual({ busy: true, waiting: false });
    expect(tabActivity("running", false)).toEqual({ busy: true, waiting: false });
    expect(tabActivity("permission", true)).toEqual({ busy: false, waiting: true });
    expect(tabActivity("waiting", true)).toEqual({ busy: false, waiting: true });
    expect(tabActivity("starting", true)).toEqual({ busy: false, waiting: false });
    // no session, or one that ended while its tab's shell lives on: the shell decides
    expect(tabActivity(null, true)).toEqual({ busy: true, waiting: false });
    expect(tabActivity("ended", false)).toEqual({ busy: false, waiting: false });
  });

  it("names the state for the status line", () => {
    expect(activity(false, false)).toBe("idle");
    expect(activity(false, true)).toBe("running");
    expect(activity(true, true)).toBe("exited");
  });

  it("calls a shell busy only above the child count it has at its prompt", () => {
    expect(shellBusy(0, null)).toBe(false);
    expect(shellBusy(0, 0)).toBe(false);
    expect(shellBusy(1, 0)).toBe(true);
    // a launcher that keeps one child for the whole session
    expect(shellBusy(1, 1)).toBe(false);
    expect(shellBusy(3, 1)).toBe(true);
  });
});

describe("terminal tabs that do not fit", () => {
  it("keeps every tab while each has 120px", () => {
    expect(tabOverflow(3, 0, 360)).toEqual({ visible: [0, 1, 2], hidden: [] });
    expect(tabOverflow(0, null, 360)).toEqual({ visible: [], hidden: [] });
  });

  it("moves the tabs past the width into the » menu, leaving room for its button", () => {
    expect(tabOverflow(8, 0, 420)).toEqual({ visible: [0, 1, 2], hidden: [3, 4, 5, 6, 7] });
    expect(tabOverflow(3, 0, 359)).toEqual({ visible: [0, 1], hidden: [2] });
  });

  it("keeps the selected tab in the bar", () => {
    expect(tabOverflow(8, 6, 420)).toEqual({ visible: [0, 1, 6], hidden: [2, 3, 4, 5, 7] });
    expect(tabOverflow(4, 3, 60)).toEqual({ visible: [3], hidden: [0, 1, 2] });
  });

  it("always shows one tab", () => {
    expect(tabOverflow(2, null, 0)).toEqual({ visible: [0], hidden: [1] });
  });

  it("gives the tabs what the bar's buttons leave", () => {
    expect(tabStripWidth(700, 3)).toBe(700 - 16 - 84 - 8);
    expect(tabStripWidth(40, 3)).toBe(0);
  });
});

describe("terminal panel at narrow sizes", () => {
  it("folds the commands into one menu below 520px", () => {
    expect(commandsFolded(700)).toBe(false);
    expect(commandsFolded(520)).toBe(false);
    expect(commandsFolded(519)).toBe(true);
    expect(commandHintShown(320)).toBe(true);
    expect(commandHintShown(319)).toBe(false);
  });

  it("hides the command rail in a short pane", () => {
    expect(railShown(260)).toBe(true);
    expect(railShown(139)).toBe(false);
  });

  it("drops the branch first, then the shell", () => {
    expect(statusLine(700)).toEqual({ branch: true, shell: true });
    expect(statusLine(559)).toEqual({ branch: false, shell: true });
    expect(statusLine(319)).toEqual({ branch: false, shell: false });
  });

  it("moves the bar's buttons into the actions menu when no tab would fit beside them", () => {
    expect(compactBar(300)).toBe(false);
    expect(compactBar(259)).toBe(true);
  });
});
