import { describe, expect, it } from "vitest";
import { agentArguments, bypassMode, skipsPermissions } from "@/entities/agent/lib/arguments";

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
