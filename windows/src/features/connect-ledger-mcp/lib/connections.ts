import type { LedgerBrowserStatus, LedgerIntegrationStatus, Ms } from "@/entities/ledger";

/** The five states every connection row shows, Claude Code, Codex and the browser extension alike */
export type ConnectionState = "not_set_up" | "connected" | "no_data" | "repair" | "missing";
export type ConnectionAction = "setup" | "repair" | "remove" | "copy";

/** One row of the Connections list; text is English, the translation key. (macOS: LedgerConnectionLook) */
export interface ConnectionLook {
  state: ConnectionState;
  /** When data from this connection last arrived, for "Connected · last data …" */
  lastDataAt: Ms | null;
  /** One line; `{0}` is the client's name */
  explanation: string;
  actions: ConnectionAction[];
  /** Only the MCP entry is broken, so Repair leaves a person without hooks without them */
  repairsMcp: boolean;
}

const repairText: Record<string, [hook: string, mcp: string]> = {
  outdated_command: ["The hook command is older than this Ledger and cannot write to it.", "The MCP command is older than this Ledger and cannot write to it."],
  missing_command: ["The hook command no longer exists.", "The MCP command no longer exists."],
  other_database: ["The hooks write to a different Ledger database.", "The MCP server uses a different Ledger database."],
};

/** Which command a problem comes from: the hooks unless only the MCP entry has it */
function culprit(status: LedgerIntegrationStatus): "hook" | "mcp" {
  const bad = (c: LedgerIntegrationStatus["hookCommand"]) => !!c && (status.health === "missing_command" ? !c.exists || !c.executable : status.health === "outdated_command" ? c.canWrite === false : c.sameDatabase === false);
  return bad(status.hookCommand) || !bad(status.mcp.command) ? "hook" : "mcp";
}

/**
 * A local agent's row: Repair when the connection cannot deliver, Set up while hooks or the MCP entry are missing,
 * Remove while either exists. The MCP command can be copied once the stable command exists, since it names that file.
 * (macOS: LedgerConnectionLook.agent)
 */
export function agentConnection(status: LedgerIntegrationStatus, stableExists: boolean): ConnectionLook {
  const hooks = status.ownedHookCount > 0;
  // hooks bring activity; only the MCP entry gives the agent the tools to report with
  const reports = status.mcp.registered;
  const lastDataAt = Math.max(status.lastObservedAt ?? 0, status.lastReportAt ?? 0) || null;
  const copy: ConnectionAction[] = stableExists ? ["copy"] : [];
  let state: ConnectionState;
  let explanation: string;
  let repairsMcp = false;
  switch (status.health) {
    case "not_installed":
      state = "not_set_up";
      explanation = "Not connected. Set up installs activity hooks and registers the Ledger tools.";
      break;
    case "missing_command":
    case "outdated_command":
    case "other_database": {
      state = status.health === "missing_command" ? "missing" : "repair";
      const [hook, mcp] = repairText[status.health];
      repairsMcp = culprit(status) === "mcp";
      explanation = repairsMcp ? mcp : hook;
      break;
    }
    case "incomplete":
      state = "repair";
      explanation = "Some activity hooks are missing.";
      break;
    case "no_data_yet":
      state = "no_data";
      explanation = status.hooksDisabled ? "Hooks are turned off in this client's settings." : status.requiresClientTrust ? "Start or restart Codex, then review and trust the Ledger hooks in /hooks." : reports ? "Start or restart {0} to send activity." : "Set up registers the Ledger tools. Then start or restart {0}.";
      break;
    default:
      state = "connected";
      explanation = status.hooksDisabled ? "Hooks are turned off in this client's settings." : !hooks ? "The MCP server is registered. Set up also records activity." : reports ? "Activity and reports reach this Ledger." : "Activity reaches this Ledger, but agents cannot report yet. Set up registers the Ledger tools.";
  }
  const broken = state === "repair" || state === "missing";
  const actions: ConnectionAction[] = [...(broken ? ["repair" as const] : hooks && reports ? [] : ["setup" as const]), ...(hooks || reports ? ["remove" as const] : []), ...copy];
  return { state, lastDataAt: state === "connected" ? lastDataAt : null, explanation, actions, repairsMcp };
}

/** The browser extension's row: its host registration, and when its last question arrived */
export function browserConnection(status: LedgerBrowserStatus): ConnectionLook {
  const look = (state: ConnectionState, explanation: string, actions: ConnectionAction[], lastDataAt: Ms | null = null): ConnectionLook => ({ state, lastDataAt, explanation, actions, repairsMcp: false });
  // A registration whose host moved with the app is repaired, not set up again
  if (!status.installed && status.hostExists === false) return look("missing", "The browser host is missing. Repair registers this copy of Gitrochi.", ["repair", "remove"]);
  if (!status.installed) return look("not_set_up", "Not connected. Load the extension in Chrome and allow it to connect.", ["setup"]);
  const lastDataAt = status.lastDataAt ?? null;
  return lastDataAt
    ? look("connected", "Questions from paired ChatGPT conversations reach this Ledger.", ["remove"], lastDataAt)
    : look("no_data", "Pair a conversation from the extension's popup to send questions.", ["remove"]);
}

/**
 * The MCP registration to copy, naming the stable command. A registration that already exists is removed first, since
 * `mcp add` does not replace one; `;` works in both shells. (macOS: LedgerSetupClient.mcpCommand)
 */
export function mcpCommand(client: LedgerIntegrationStatus["client"], stable: string, registered: boolean, windows = false) {
  const quote = (value: string) => (windows ? `'${value.replace(/'/g, "''")}'` : `'${value.replace(/'/g, "'\\''")}'`);
  const scope = client === "claude" ? "--scope user " : "";
  const add = `${client} mcp add ${scope}gitrochi-ledger -- ${quote(stable)} mcp`;
  return registered ? `${client} mcp remove ${scope}gitrochi-ledger; ${add}` : add;
}
