import { env, isWindows, joinPath } from "@/shared/config";

/**
 * The ledger command bundled with this copy of the app, among its resources. Hooks never name it directly: it moves
 * with the app, so Set up copies it to the stable command. (macOS: LedgerCommandLine.bundled)
 */
export function bundledLedgerCommand(): string | null {
  if (!env.resourceDir) return null;
  const path = joinPath(env.resourceDir, isWindows() ? "gitrochi-ledger.exe" : "gitrochi-ledger");
  return isWindows() ? path.replace(/\//g, "\\") : path;
}
