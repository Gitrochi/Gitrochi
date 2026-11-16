import { describe, expect, it } from "vitest";
import { agentArguments, bypassMode, skipsPermissions } from "@/entities/agent/lib/arguments";
import { sessionMark, sessionNeedsUser, sessionsNeedingUser, sessionWord, tabActivity, tabMark } from "@/entities/terminal/lib/panel-layout";
import { needCaption, worktreePlace } from "../src/widgets/sidebar/lib/agents-panel";

describe("agent arguments", () => {
  it("passes the permission mode and the task", () => {
    expect(agentArguments("claude", "/h.json", "fix it", "plan")).toEqual(["--settings", "/h.json", "--permission-mode", "plan", "fix it"]);
    expect(agentArguments("claude", "/h.json", "", null)).toEqual(["--settings", "/h.json"]);
    expect(agentArguments("codex", "", "fix it", "read-only")).toEqual(["--sandbox", "read-only", "fix it"]);
    expect(agentArguments("gemini", "", "fix it", "auto_edit")).toEqual(["--approval-mode", "auto_edit", "-i", "fix it"]);
  });

  it("skips every permission check in bypass mode", () => {
    expect(agentArguments("claude", "/h.json", "", bypassMode.claude)).toEqual(["--settings", "/h.json", "--permission-mode", "bypassPermissions"]);
    expect(agentArguments("codex", "", "fix it", bypassMode.codex)).toEqual(["--dangerously-bypass-approvals-and-sandbox", "fix it"]);
    expect(agentArguments("gemini", "", "", bypassMode.gemini)).toEqual(["--approval-mode", "yolo"]);
  });

  it("tells which sessions skip permission checks", () => {
    expect(skipsPermissions("claude", "bypassPermissions")).toBe(true);
    expect(skipsPermissions("codex", "bypass")).toBe(true);
    expect(skipsPermissions("gemini", "yolo")).toBe(true);
    expect(skipsPermissions("claude", "auto")).toBe(false);
    expect(skipsPermissions("codex", "workspace-write")).toBe(false);
    expect(skipsPermissions("claude", "")).toBe(false);
    expect(skipsPermissions("gemini", null)).toBe(false);
  });
});

describe("agent sessions in the sidebar", () => {
  const statuses = ["starting", "working", "permission", "waiting", "running", "ended"];
  it("lists under Needs you exactly the sessions that wait for the user", () => {
    expect(statuses.filter(sessionNeedsUser)).toEqual(["permission", "waiting"]);
    const sessions = [
      { id: "a", status: "working", updated: 10 }, { id: "b", status: "waiting", updated: 30 }, { id: "c", status: "permission", updated: 20 },
      { id: "d", status: "ended", updated: 5 }, { id: "e", status: "starting", updated: 1 }, { id: "f", status: "running", updated: 2 },
    ];
    // every waiting session, the one waiting longest first
    expect(sessionsNeedingUser(sessions).map((s) => s.id)).toEqual(["c", "b"]);
    expect(sessionsNeedingUser([])).toEqual([]);
  });
  it("draws the terminal tab's marks: a ring while running, the dot while waiting, hollow when ended, nothing when idle", () => {
    expect(statuses.map(sessionMark)).toEqual(["none", "ring", "dot", "dot", "ring", "hollow"]);
    // the same rule as the tab the session runs in
    for (const status of statuses.filter((s) => s !== "ended")) {
      const { busy, waiting } = tabActivity(status, false);
      expect(sessionMark(status)).toBe(tabMark({ exited: false, busy, unseen: false, waiting }));
    }
  });
  it("says Running for an agent at work, whatever its hooks call it", () => {
    expect(statuses.map(sessionWord)).toEqual(["Idle", "Running", "Needs permission", "Waiting for input", "Running", "Ended"]);
  });
  it("captions a Needs you card with what the session is about, then the agent, the tool and the time", () => {
    expect(needCaption({ task: "Make the test stable\nand fast", folder: "flaky-tests", kind: "Codex", detail: "Edit", ago: "2m ago" })).toBe("Make the test stable\nCodex · Edit · 2m ago");
    expect(needCaption({ task: "  ", folder: "flaky-tests", kind: "Claude Code", detail: null, ago: "20m ago" })).toBe("flaky-tests\nClaude Code · 20m ago");
    const long = needCaption({ task: "x".repeat(200), folder: "f", kind: "Codex", detail: "", ago: "now" }).split("\n")[0];
    expect(long).toHaveLength(80); expect(long.endsWith("…")).toBe(true);
  });
  it("shortens a linked worktree's path to its last folder and keeps the repository's own", () => {
    expect(worktreePlace("~/Projects/desktop", true)).toBe("~/Projects/desktop");
    expect(worktreePlace("~/Projects/desktop-worktrees/ai-lockout", false)).toBe("…/ai-lockout");
    expect(worktreePlace("C:\\work\\desktop-worktrees\\ai-lockout", false)).toBe("…/ai-lockout");
    expect(worktreePlace("desktop", false)).toBe("desktop");
    // a long path of the repository itself loses whole folders from its start, never part of a name
    expect(worktreePlace("/Users/me/Projects/clients/desktop", true)).toBe("…/clients/desktop");
    expect(worktreePlace("C:\\Users\\me\\Projects\\desktop", true)).toBe("…\\me\\Projects\\desktop");
    expect(worktreePlace("/a-folder-name-longer-than-the-sidebar/desktop", true)).toBe("…/desktop");
  });
});
