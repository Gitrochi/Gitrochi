import { ipc } from "@/shared/api";
import { dirname, env, joinPath } from "@/shared/config";

/** Keep the last native self-test stage when startup or an awaited operation stalls. */
export async function selfTestProgress(stage: string, checks?: unknown) {
  if (!env.selftest) return;
  await ipc.writeText(joinPath(dirname(env.selftest), "selftest-progress.json"), JSON.stringify({ stage, checks }, null, 2)).catch(() => {});
}

/** Startup failures must produce a failed CI result even before the self-test begins. */
export async function selfTestStartupFailure(error: unknown) {
  if (!env.selftest) return;
  const result = { ok: false, checks: [{ name: "App startup", ok: false, detail: String(error instanceof Error ? error.stack ?? error.message : error) }] };
  await ipc.writeText(joinPath(dirname(env.selftest), "selftest-result.json"), JSON.stringify(result, null, 2)).catch(() => {});
}
