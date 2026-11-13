import { ledgerStableCommand, runLedgerCleanup } from "@/entities/agent";
import { ipc } from "@/shared/api";
import { env, isWindows } from "@/shared/config";
import { tools } from "@/shared/platform";

/**
 * Unregisters what the removed Ledger left in Claude Code and Codex, once the tools are found (runLedgerCleanup).
 * Does nothing once the ledger command's copy is gone. (macOS: AppDelegate.cleanUpLedger)
 */
export async function startLedgerCleanup() {
  try {
    await runLedgerCleanup(ledgerStableCommand(env.appData, isWindows()), {
      exists: ipc.exists,
      // from the home folder, as the Ledger ran the clients: a user-level change must not depend on the app's folder
      run: (program, args) => ipc.run(program, args, { cwd: env.home, timeoutMs: 30_000 }).catch(() => null),
      // a client inside WSL keeps its settings there, where the Ledger never wrote
      program: (client) => tools.path(client),
      list: ipc.list,
      remove: ipc.remove,
    });
  } catch {
    // the copy stays, so the next start tries again
  }
}
