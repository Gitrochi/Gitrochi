import { ledgerStableCommand, removeLedgerOrphans, runLedgerCleanup } from "@/entities/agent";
import { ipc } from "@/shared/api";
import { env, isWindows } from "@/shared/config";
import { tools } from "@/shared/platform";

/**
 * Unregisters what the removed Ledger left in Claude Code and Codex, once the tools are found (runLedgerCleanup).
 * Then takes out what is left without that copy. (macOS: AppDelegate.cleanUpLedger)
 */
export async function startLedgerCleanup() {
  // from the home folder, as the Ledger ran the clients: a user-level change must not depend on the app's folder
  const run = (program: string, args: string[]) => ipc.run(program, args, { cwd: env.home, timeoutMs: 30_000 }).catch(() => null);
  // a client inside WSL keeps its settings there, where the Ledger never wrote
  const program = (client: "claude" | "codex") => tools.path(client);
  try {
    await runLedgerCleanup(ledgerStableCommand(env.appData, isWindows()), { exists: ipc.exists, run, program, list: ipc.list, remove: ipc.remove });
  } catch {
    // the copy stays, so the next start tries again
  }
  try {
    // hooks that ran the command next to an older app have no copy to take them out
    await removeLedgerOrphans(env.home, { readText: ipc.readText, writeText: ipc.writeText, run, program });
  } catch {
    // the next start tries again
  }
}
