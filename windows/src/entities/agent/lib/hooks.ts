/**
 * The hooks file Gitrochi passes with `--settings` to the Claude Code sessions it starts; hooks given this way add to
 * the person's own. Its entries for the Agents panel call the app itself (`--agent-hook`).
 * (macOS: Services/Agents.swift, hooks.json)
 */

/** The events the Agents panel follows */
export const agentHookEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "Notification", "Stop", "SessionEnd"];

export interface HookCommand {
  type: "command";
  command: string;
  timeout: number;
}

export interface HookGroup {
  matcher: string;
  hooks: HookCommand[];
}

/** hooks.json or hooks-wsl.json: the Agents panel's entries */
export function agentHooksJson(agentCommand: (event: string) => string, timeout: number): string {
  const hooks: Record<string, HookGroup[]> = {};
  for (const e of agentHookEvents) hooks[e] = [{ matcher: "", hooks: [{ type: "command", command: agentCommand(e), timeout }] }];
  return JSON.stringify({ hooks }, null, 2);
}
