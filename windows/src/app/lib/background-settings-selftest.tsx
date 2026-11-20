import { createRoot } from "react-dom/client";
import { type AutostartHost, BackgroundSettings } from "@/widgets/settings";
import { keepRunningInBackground, settings } from "@/shared/config";

const pause = () => new Promise((resolve) => setTimeout(resolve, 20));
const until = async (check: () => boolean) => {
  for (let attempt = 0; attempt < 100; attempt++) {
    if (check()) return true;
    await pause();
  }
  return false;
};

/**
 * Settings › Update › Startup and background: both toggles show their state and change it, and a failed login change
 * says why and goes back. The login item is a fake, so the runner's registry stays as it was.
 */
export async function backgroundSettingsSelfTest(): Promise<[boolean, string]> {
  const saved = settings.get<unknown>("keepRunningInBackground", undefined);
  const calls: boolean[] = [];
  let fail = false;
  const autostart: AutostartHost = {
    get: async () => false,
    set: async (enabled) => {
      calls.push(enabled);
      if (fail) throw new Error("Access is denied.");
    },
  };
  const host = document.createElement("div");
  host.style.cssText = "position:fixed;left:-10000px;top:0;width:560px";
  document.body.append(host);
  const root = createRoot(host);
  const boxes = () => Array.from(host.querySelectorAll<HTMLInputElement>("input[type=checkbox]"));
  try {
    settings.set("keepRunningInBackground", undefined);
    root.render(<BackgroundSettings autostart={autostart} showLogin />);
    if (!await until(() => boxes().length === 2 && !boxes()[0].disabled)) return [false, "The two startup toggles did not appear"];
    const [login, keep] = boxes();
    if (login.checked) return [false, "Open at login shows on while it is off"];
    if (keep.checked || keepRunningInBackground()) return [false, "Keeping running in the tray is not off by default"];
    login.click();
    if (!await until(() => boxes()[0].checked) || calls.join() !== "true") return [false, "Turning on opening at login did not set it"];
    fail = true;
    boxes()[0].click();
    if (!await until(() => !!host.querySelector("[role=alert]"))) return [false, "A failed login change did not say why"];
    if (!boxes()[0].checked) return [false, "A failed login change did not go back"];
    boxes()[1].click();
    if (!await until(() => boxes()[1].checked) || !keepRunningInBackground()) return [false, "Turning on keeping running did not save it"];
    boxes()[1].click();
    if (!await until(() => !boxes()[1].checked) || keepRunningInBackground()) return [false, "Turning keeping running back off did not save it"];
    return [true, "Open at login and keep running in the tray: default, change, failure and restore"];
  } finally {
    root.unmount();
    host.remove();
    settings.set("keepRunningInBackground", saved);
  }
}
