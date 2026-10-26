import { type EnvInfo } from "@/shared/api";
import { initEnv, settings } from "@/shared/config";
import { loadLanguage } from "@/shared/i18n";
import { selfTestProgress } from "./selftest-report";

/** Keep application imports behind the bootstrap error handler. */
export async function boot(info: EnvInfo) {
  await initEnv(info);
  await selfTestProgress("Load settings");
  await settings.load();
  await selfTestProgress("Load language");
  await loadLanguage(info.selftest ? "ko" : settings.get<string | null>("language", null));
  await selfTestProgress("Import application");
  const { start } = await import("../start");
  await start();
}
