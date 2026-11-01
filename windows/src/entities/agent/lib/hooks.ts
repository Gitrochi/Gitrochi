/**
 * The hooks file Gitrochi passes with `--settings` to the Claude Code sessions it starts; hooks given this way add to
 * the person's own. Its entries for the Agents panel call the app itself (`--agent-hook`). While the Ledger's Track
 * agents I start is on, the ledger CLI's entries follow them (docs/ledger/DESIGN.md §5, §9.1).
 * (macOS: Services/Agents.swift, hooks.json)
 */

/** The events the Agents panel follows */
export const agentHookEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "Notification", "Stop", "SessionEnd"];

/** The longest wait a person can set for auto-continue (gitrochi-autocontinue's MAX_DELAY_SEC) */
export const LEDGER_MAX_WAIT_SEC = 300;
/** The shortest (MIN_DELAY_SEC) */
export const LEDGER_MIN_WAIT_SEC = 10;
/** Past the wait, the time the hook handler has for its own work (HOOK_TIMEOUT_MARGIN_SEC) */
export const LEDGER_HOOK_MARGIN_SEC = 10;

export interface HookCommand {
  type: "command";
  command: string;
  async?: boolean;
  asyncRewake?: boolean;
  timeout: number;
}

export interface HookGroup {
  matcher: string;
  hooks: HookCommand[];
}

/**
 * The ledger CLI's entries: gitrochi_autocontinue::hook_settings plus SessionStart and SessionEnd for activity. Stop
 * runs in the background (the person can still type) and wakes the agent with exit 2; AskUserQuestion, ExitPlanMode
 * and permission requests wait synchronously; the calls that ran tell an automatic permission answer from one given in
 * the terminal. The handler keeps its own deadline at the session's wait, and the waiting entries' timeout covers the
 * longest wait plus the margin: a person may change a session's wait after the agent read this file.
 */
export function ledgerHookGroups(command: (event: string) => string): [string, HookGroup][] {
  const waiting = LEDGER_MAX_WAIT_SEC + LEDGER_HOOK_MARGIN_SEC;
  const group = (event: string, timeout: number, matcher = "", background = false): [string, HookGroup] => [
    event,
    { matcher, hooks: [{ type: "command", command: command(event), ...(background ? { async: true, asyncRewake: true } : {}), timeout }] },
  ];
  return [
    group("SessionStart", 10),
    group("UserPromptSubmit", 10),
    group("PreToolUse", waiting, "AskUserQuestion|ExitPlanMode"),
    group("PermissionRequest", waiting),
    group("Stop", waiting, "", true),
    group("SessionEnd", 10),
    group("PostToolUse", 10),
    group("PostToolUseFailure", 10),
  ];
}

/**
 * hooks.json or hooks-wsl.json: the Agents panel's entries exactly as they always were, then — with a ledger command —
 * the ledger's, after them in the same events and in two new ones.
 */
export function agentHooksJson(agentCommand: (event: string) => string, timeout: number, ledgerCommand: ((event: string) => string) | null = null): string {
  const hooks: Record<string, HookGroup[]> = {};
  for (const e of agentHookEvents) hooks[e] = [{ matcher: "", hooks: [{ type: "command", command: agentCommand(e), timeout }] }];
  if (ledgerCommand) for (const [event, group] of ledgerHookGroups(ledgerCommand)) (hooks[event] ??= []).push(group);
  return JSON.stringify({ hooks }, null, 2);
}
