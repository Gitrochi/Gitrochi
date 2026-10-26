import { env, initEnv, settings } from "@/shared/config";
import { loadLanguage, t } from "@/shared/i18n";
import { ipc } from "@/shared/api";
import { selfTestProgress, selfTestStartupFailure } from "./lib/selftest-progress";
// 화면 언어를 먼저 정하고 나서 앱을 불러온다(앱 모듈의 글자가 그 언어로 읽히게).
// 자체 점검·README 스크린샷은 한국어 화면을 기준으로 한다.
async function boot() {
  await initEnv();
  await selfTestProgress("Loading settings");
  await settings.load();
  await selfTestProgress("Loading language");
  await loadLanguage(env.selftest ? "ko" : settings.get<string | null>("language", null));
  await selfTestProgress("Loading app modules");
  const { start } = await import("./start");
  await start();
}

void boot().catch((e) => {
  const pre = document.createElement("pre");
  pre.style.cssText = "padding:20px;white-space:pre-wrap";
  pre.textContent = `${t("Couldn't start Gitrochi")}\n\n${String(e?.stack ?? e)}`;
  document.body.replaceChildren(pre);
  void selfTestStartupFailure(e);
  void ipc.appReady();
});
