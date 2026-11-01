/**
 * What a started agent gets besides its command: its ID for the Agents panel's hooks and, while the Ledger tracks it,
 * the ledger session and the Ledger's MCP server. Without a ledger session both are exactly what they always were.
 * (macOS: Services/Agents.swift)
 */

/** The environment of a started agent; WSL launches pass the same names on through WSLENV */
export function launchEnv(agentId: string, ledgerSession: string | null): Record<string, string> {
  return ledgerSession ? { GITROCHI_AGENT_ID: agentId, GITROCHI_LEDGER_SESSION: ledgerSession } : { GITROCHI_AGENT_ID: agentId };
}

/** Claude Code's `--mcp-config` takes several values, so it goes first: the `--settings` after it ends the list */
export function launchArguments(args: string[], mcpConfig: string | null): string[] {
  return mcpConfig ? ["--mcp-config", mcpConfig, ...args] : args;
}
