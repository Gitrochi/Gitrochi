import { describe, expect, it } from "vitest";
import {
  backgroundMenu, type BackgroundMenuItem, menuRecentLimit, menuRunLimit, pendingRunCount, quitWarning, recentToOpen, runLine, trayAction,
  trayItems, upcomingRuns,
} from "../src/app/lib/background-menu";

type Run = Parameters<typeof upcomingRuns>[0][number];
const run = (id: string, runAt: number, extra: Partial<Run> = {}): Run & { id: string } => ({
  id, repoPath: "/work/demo", workflowName: "Deploy", ref: "main", runAt, state: "scheduled", ...extra,
});
const same = (a: string, b: string) => a.replace(/\\/g, "/").toLowerCase() === b.replace(/\\/g, "/").toLowerCase();
const time = (at: number) => `T${at}`;
const titles = (items: BackgroundMenuItem[]) => items.map((item) => ("title" in item ? `${item.kind}:${item.title}` : item.kind));

describe("upcoming runs", () => {
  it("lists only runs still to start, soonest first, up to the limit", () => {
    const runs = [run("c", 30), run("missed", 5, { state: "missed" }), run("a", 10), run("failed", 1, { state: "failed" }), run("b", 20)];
    expect(upcomingRuns(runs).map((r) => r.id)).toEqual(["a", "b", "c"]);
    const many = Array.from({ length: 8 }, (_, i) => run(`r${i}`, 100 - i));
    expect(upcomingRuns(many)).toHaveLength(menuRunLimit);
    expect(upcomingRuns(many)[0].id).toBe("r7");
  });

  it("reads time · repository · workflow (branch), and a pipeline without a workflow name", () => {
    expect(runLine(run("a", 1, { repoPath: "C:\\work\\shop" }), "Nov 18, 12:30 PM")).toBe("Nov 18, 12:30 PM · shop · Deploy (main)");
    expect(runLine(run("b", 1, { workflowName: null, ref: "release" }), "12:30")).toBe("12:30 · demo · Pipeline (release)");
  });

  it("counts the runs quitting would stop", () => {
    expect(pendingRunCount([run("a", 1), run("b", 2, { state: "missed" }), run("c", 3, { state: "failed" }), run("d", 4)])).toBe(2);
  });
});

describe("recent repositories", () => {
  it("leaves out the open ones, whatever their spelling, and keeps the order", () => {
    expect(recentToOpen(["C:\\a", "C:\\b", "C:\\c"], ["c:/B"], same)).toEqual(["C:\\a", "C:\\c"]);
    expect(recentToOpen(Array.from({ length: 9 }, (_, i) => `/r${i}`), [], same)).toHaveLength(menuRecentLimit);
  });
});

describe("the tray menu", () => {
  it("shows one disabled line without scheduled runs, and no repository sections while nothing is open or recent", () => {
    const items = backgroundMenu({ runs: [run("x", 1, { state: "missed" })], time, repositories: [], recents: [], same });
    expect(titles(items)).toEqual(["header:Scheduled runs", "note:No scheduled runs", "separator", "open", "settings", "separator", "quit"]);
  });

  it("lists runs, then open repositories with their terminals under them, then recent ones that are not open", () => {
    const items = backgroundMenu({
      runs: [run("late", 200, { repoPath: "/work/api", workflowName: "Nightly" }), run("soon", 100)],
      time,
      repositories: [
        { path: "/work/demo", name: "demo", terminals: [{ id: "t1", title: "zsh", state: "Idle" }, { id: "t2", title: "claude", state: "Waiting for input" }] },
        { path: "/work/api", name: "api", terminals: [] },
      ],
      recents: ["/work/demo", "/work/docs"],
      same,
    });
    expect(titles(items)).toEqual([
      "header:Scheduled runs", "run:T100 · demo · Deploy (main)", "run:T200 · api · Nightly (main)",
      "separator", "header:Open repositories", "repository:demo", "terminal:zsh — Idle", "terminal:claude — Waiting for input", "repository:api",
      "separator", "header:Recent repositories", "recent:docs",
      "separator", "open", "settings", "separator", "quit",
    ]);
    const terminal = items.find((item) => item.kind === "terminal" && item.id === "t2");
    expect(terminal).toMatchObject({ path: "/work/demo" });
  });

  it("makes tray lines whose ids lead back to the action, with headers disabled and terminals indented", () => {
    const items = backgroundMenu({
      runs: [run("a", 1)], time,
      repositories: [{ path: "C:\\work\\demo", name: "demo", terminals: [{ id: "t1", title: "pwsh", state: "Running" }] }],
      recents: ["C:\\work\\docs"], same,
    });
    const lines = trayItems(items);
    expect(lines[0]).toEqual({ id: null, label: "Scheduled runs", enabled: false });
    expect(lines.filter((line) => line.label === null).every((line) => line.id === null && !line.enabled)).toBe(true);
    const terminal = lines.find((line) => line.label?.trim() === "pwsh — Running")!;
    expect(terminal.label).toMatch(/^ {4}/);
    expect(trayAction(terminal.id!)).toEqual({ kind: "terminal", path: "C:\\work\\demo", id: "t1" });
    const actions = lines.filter((line) => line.enabled).map((line) => trayAction(line.id!));
    expect(actions).toEqual([
      { kind: "run", path: "/work/demo" },
      { kind: "repository", path: "C:\\work\\demo" },
      { kind: "terminal", path: "C:\\work\\demo", id: "t1" },
      { kind: "recent", path: "C:\\work\\docs" },
      { kind: "open" }, { kind: "settings" }, { kind: "quit" },
    ]);
    expect(lines.slice(-4).map((line) => line.label)).toEqual(["Open Gitrochi", "Settings…", null, "Quit Gitrochi"]);
  });

  it("keeps an ampersand in a name from becoming a shortcut", () => {
    const lines = trayItems([{ kind: "repository", title: "R&D", path: "/work/R&D" }]);
    expect(lines[0].label).toBe("R&&D");
    expect(trayAction(lines[0].id!)).toEqual({ kind: "repository", path: "/work/R&D" });
  });

  it("ignores ids it did not make", () => {
    expect(trayAction("quit")).toBeNull();
    expect(trayAction(JSON.stringify({ kind: "terminal", path: "/a" }))).toBeNull();
    expect(trayAction(JSON.stringify({ kind: "delete", path: "/a" }))).toBeNull();
  });
});

describe("quitting", () => {
  it("names what stops, and nothing when nothing would", () => {
    expect(quitWarning(0, 0)).toBeNull();
    expect(quitWarning(2, 1)).toBe("2 scheduled runs won't start. 1 terminal session will end.");
    expect(quitWarning(1, 0)).toBe("1 scheduled run won't start.");
    expect(quitWarning(0, 3)).toBe("3 terminal sessions will end.");
  });
});
