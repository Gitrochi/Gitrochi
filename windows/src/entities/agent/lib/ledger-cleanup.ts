/**
 * Gitrochi no longer has a Ledger. A person who connected Claude Code or Codex to it still has its hooks and MCP server
 * in those clients' settings, and they run the copy of the ledger command under %APPDATA%\Gitrochi\bin. While that copy
 * exists, this has it take out its own hooks and browser host, has each client drop the MCP server, and deletes the
 * copy once nothing names it any more. The ledger's database is left where it is.
 * Older installs ran the command next to the app, so no copy exists and nothing above runs: `removeLedgerOrphans` then
 * takes the owned hooks out of the clients' settings files and has each client drop the MCP server, every start, until
 * nothing names the Ledger any more.
 * (macOS: Services/LedgerCleanup.swift)
 */

export const ledgerClients = ["claude", "codex"] as const;
export type LedgerClient = (typeof ledgerClients)[number];

/** What the ledger command's `integrate <client> --status` says a client still has */
export interface LedgerRegistration {
  hooks: number;
  mcp: boolean;
}

/** What the cleanup needs from the system; `run` answers null when the program did not start */
export interface LedgerCleanupIO {
  exists: (path: string) => Promise<boolean>;
  run: (program: string, args: string[]) => Promise<{ status: number; stdout: string } | null>;
  /** Where a client's own command is, when it is installed */
  program: (client: LedgerClient) => string | null;
  list: (folder: string) => Promise<string[]>;
  remove: (path: string) => Promise<void>;
}

/** The MCP server name both clients registered */
const SERVER = "gitrochi-ledger";

/** `data` is %APPDATA% on Windows and Application Support on a Mac, where the command has no extension */
export const ledgerStableCommand = (data: string, windows: boolean) => `${data.replace(/\\/g, "/").replace(/\/+$/, "")}/Gitrochi/bin/${windows ? "gitrochi-ledger.exe" : "gitrochi-ledger"}`;
export const ledgerStatusArguments = (client: LedgerClient) => ["--json", "integrate", client, "--status"];
/** Removes only the handlers the ledger command installed; it keeps a backup of the settings next to them */
export const ledgerHookArguments = (client: LedgerClient) => ["integrate", client, "--remove"];
export const ledgerBrowserArguments = ["browser-host", "remove"];
/** The client's own command, as the Ledger's Remove ran it: its settings are its own to rewrite */
export const ledgerMcpArguments = (client: LedgerClient) => ["mcp", "remove", ...(client === "claude" ? ["--scope", "user"] : []), SERVER];

/** Null when the answer is not the status: the settings could not be read, so nothing is known */
export function ledgerRegistration(output: string): LedgerRegistration | null {
  let value: unknown;
  try {
    value = JSON.parse(output);
  } catch {
    return null;
  }
  if (value === null || typeof value !== "object" || Array.isArray(value)) return null;
  const status = value as { ownedHookCount?: unknown; mcp?: { registered?: unknown } | null };
  if (typeof status.ownedHookCount !== "number") return null;
  return { hooks: status.ownedHookCount, mcp: status.mcp?.registered === true };
}

const nothingLeft = (found: LedgerRegistration | null) => !!found && found.hooks === 0 && !found.mcp;

/**
 * The copy goes only when every client is known to have nothing left: a hook whose command is missing fails on every
 * event, so a copy something still names stays, and the next start tries again.
 */
export const ledgerCopyCanGo = (left: (LedgerRegistration | null)[]) => left.every(nothingLeft);

/** True when the copy was deleted */
export async function runLedgerCleanup(stable: string, io: LedgerCleanupIO): Promise<boolean> {
  if (!(await io.exists(stable))) return false;
  const status = async (client: LedgerClient) => {
    const result = await io.run(stable, ledgerStatusArguments(client));
    return result && result.status === 0 ? ledgerRegistration(result.stdout) : null;
  };
  const left: (LedgerRegistration | null)[] = [];
  for (const client of ledgerClients) {
    let found = await status(client);
    if (found && !nothingLeft(found)) {
      if (found.hooks > 0) await io.run(stable, ledgerHookArguments(client));
      const program = found.mcp ? io.program(client) : null;
      if (program) await io.run(program, ledgerMcpArguments(client));
      found = await status(client);
    }
    left.push(found);
  }
  // the Chrome host registration names a command next to the app, not this copy, so its result decides nothing
  await io.run(stable, ledgerBrowserArguments);
  if (!ledgerCopyCanGo(left)) return false;
  await io.remove(stable);
  // the folder held only this command; one with anything else in it stays
  const folder = stable.slice(0, stable.lastIndexOf("/"));
  if ((await io.list(folder)).length === 0) await io.remove(folder);
  return true;
}

// Hooks and servers left without the command

type Json = Record<string, unknown>;
const isObject = (value: unknown): value is Json => value !== null && typeof value === "object" && !Array.isArray(value);

/** The settings file each client keeps its hooks in, under the home folder */
export const ledgerHookFile = (client: LedgerClient, home: string) =>
  `${home.replace(/\\/g, "/").replace(/\/+$/, "")}/${client === "claude" ? ".claude/settings.json" : ".codex/hooks.json"}`;
/** Claude Code's `~/.claude.json`, Codex's `~/.codex/config.toml` */
export const ledgerMcpFile = (client: LedgerClient, home: string) =>
  `${home.replace(/\\/g, "/").replace(/\/+$/, "")}/${client === "claude" ? ".claude.json" : ".codex/config.toml"}`;

/** A handler the Ledger installed: its command runs the ledger command and carries the flag it marked its own with */
export const isLedgerHook = (handler: unknown) =>
  isObject(handler) && typeof handler.command === "string" && handler.command.includes(SERVER) && handler.command.includes("--managed-hook");

/** The settings without the Ledger's handlers; a group or event left empty goes too, and so does an empty `hooks` */
export function withoutLedgerHooks(settings: Json): { settings: Json; removed: number } {
  if (!isObject(settings.hooks)) return { settings, removed: 0 };
  let removed = 0;
  const kept: Json = {};
  for (const [event, value] of Object.entries(settings.hooks)) {
    if (!Array.isArray(value)) {
      kept[event] = value;
      continue;
    }
    const left: unknown[] = [];
    for (const group of value) {
      if (!isObject(group) || !Array.isArray(group.hooks)) {
        left.push(group);
        continue;
      }
      const rest = group.hooks.filter((handler) => !isLedgerHook(handler));
      removed += group.hooks.length - rest.length;
      if (rest.length === group.hooks.length) left.push(group);
      else if (rest.length > 0) left.push({ ...group, hooks: rest });
    }
    if (left.length > 0) kept[event] = left;
  }
  if (removed === 0) return { settings, removed: 0 };
  const result: Json = { ...settings };
  if (Object.keys(kept).length === 0) delete result.hooks;
  else result.hooks = kept;
  return { settings: result, removed };
}

/** Whether a client's user settings still register the MCP server */
export function ledgerMcpRegistered(client: LedgerClient, text: string): boolean {
  if (client === "claude") {
    try {
      const value: unknown = JSON.parse(text);
      return isObject(value) && isObject(value.mcpServers) && SERVER in value.mcpServers;
    } catch {
      return false;
    }
  }
  return text.split(/\r?\n/).some((line) => [`[mcp_servers.${SERVER}]`, `[mcp_servers."${SERVER}"]`].includes(line.trim()));
}

/** What the orphan cleanup needs from the system */
export interface LedgerOrphanIO {
  readText: (path: string) => Promise<string | null>;
  writeText: (path: string, content: string) => Promise<void>;
  run: LedgerCleanupIO["run"];
  program: LedgerCleanupIO["program"];
}

/**
 * Hooks and MCP servers that still name the Ledger once its command is gone. A settings file keeps the text it had next
 * to it and is written only when it has not changed meanwhile. Cheap when there are none: it reads four small files.
 */
export async function removeLedgerOrphans(home: string, io: LedgerOrphanIO): Promise<void> {
  for (const client of ledgerClients) {
    const file = ledgerHookFile(client, home);
    const before = await io.readText(file).catch(() => null);
    let parsed: unknown = null;
    try {
      parsed = before === null ? null : JSON.parse(before);
    } catch {
      parsed = null;
    }
    if (before !== null && isObject(parsed)) {
      const { settings, removed } = withoutLedgerHooks(parsed);
      if (removed > 0 && (await io.readText(file).catch(() => null)) === before) {
        const backup = `${file}.before-ledger-removal`;
        if ((await io.readText(backup).catch(() => null)) === null) await io.writeText(backup, before);
        await io.writeText(file, JSON.stringify(settings, null, 2) + "\n");
      }
    }
    const config = await io.readText(ledgerMcpFile(client, home)).catch(() => null);
    const program = config !== null && ledgerMcpRegistered(client, config) ? io.program(client) : null;
    if (program) await io.run(program, ledgerMcpArguments(client));
  }
}
