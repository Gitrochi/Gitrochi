/**
 * Gitrochi no longer has a Ledger. A person who connected Claude Code or Codex to it still has its hooks and MCP server
 * in those clients' settings, and they run the copy of the ledger command under %APPDATA%\Gitrochi\bin. While that copy
 * exists, this has it take out its own hooks and browser host, has each client drop the MCP server, and deletes the
 * copy once nothing names it any more. The ledger's database is left where it is.
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
