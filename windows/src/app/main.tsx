import { invoke } from "@tauri-apps/api/core";
import type { EnvInfo } from "@/shared/api";
import { SelfTestRecorder, selfTestRecorder, setSelfTestRecorder } from "./lib/selftest-report";

// Install these before importing application modules or mounting any React root.
const earlyErrors: unknown[] = [];
const recordError = (error: unknown) => {
  const recorder = selfTestRecorder();
  if (recorder) void recorder.fail(error).catch(console.error);
  else earlyErrors.push(error);
};
const onError = (event: ErrorEvent) => recordError(event.error ?? `${event.message} @ ${event.filename}:${event.lineno}`);
const onRejection = (event: PromiseRejectionEvent) => recordError(event.reason);
window.addEventListener("error", onError);
window.addEventListener("unhandledrejection", onRejection);

async function bootstrap() {
  const info = await invoke<EnvInfo>("env_info");
  if (info.selftest) {
    const parent = info.selftest.replace(/\\/g, "/").replace(/\/+$/, "").replace(/\/[^/]*$/, "");
    const recorder = new SelfTestRecorder((file, content) => invoke("fs_write_text", { path: `${parent}/${file}`, content }), info.os);
    setSelfTestRecorder(recorder);
    await recorder.progress("Environment ready");
    for (const error of earlyErrors) await recorder.fail(error);
  } else {
    window.removeEventListener("error", onError);
    window.removeEventListener("unhandledrejection", onRejection);
    earlyErrors.length = 0;
  }
  const { boot } = await import("./lib/boot");
  await boot(info);
}

void bootstrap().catch((e) => {
  recordError(e);
  const pre = document.createElement("pre");
  pre.style.cssText = "padding:20px;white-space:pre-wrap";
  pre.textContent = `Couldn't start Gitrochi\n\n${String(e?.stack ?? e)}`;
  document.body.replaceChildren(pre);
  // The language table may already be loaded when startup fails later.
  void import("@/shared/i18n").then(({ t }) => {
    pre.textContent = `${t("Couldn't start Gitrochi")}\n\n${String(e?.stack ?? e)}`;
  }).catch(() => {});
  void invoke("app_ready").catch(console.error);
});
