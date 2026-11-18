import { useEffect, useState } from "react";
import { ipc } from "@/shared/api";
import { isWindows, keepRunningInBackground, setKeepRunningInBackground, settings } from "@/shared/config";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Checkbox } from "@/shared/ui";

/** Where opening at login is read and written; the self-test brings its own */
export interface AutostartHost {
  get(): Promise<boolean>;
  set(enabled: boolean): Promise<void>;
}

const registry: AutostartHost = { get: ipc.autostartGet, set: ipc.autostartSet };

/**
 * Startup and background, in Settings › Update: open at login, and keep running in the tray with the window closed.
 * (macOS: Views/Settings/BackgroundSettings.swift)
 */
export function BackgroundSettings({ autostart = registry, showLogin = isWindows() }: { autostart?: AutostartHost; showLogin?: boolean }) {
  useObserve(settings);
  const [login, setLogin] = useState<boolean | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    if (!showLogin) return;
    let live = true;
    autostart.get().then((on) => { if (live) setLogin(on); }, (e) => { if (live) setError(String(e)); });
    return () => { live = false; };
  }, [autostart, showLogin]);
  const changeLogin = async (on: boolean) => {
    setLogin(on);
    try {
      await autostart.set(on);
      setError(null);
    } catch (e) {
      setLogin(!on);
      setError(on ? t("Couldn't add Gitrochi to the startup apps: {0}", String(e)) : t("Couldn't remove Gitrochi from the startup apps: {0}", String(e)));
    }
  };
  return (
    <div className="form-section" data-background-settings>
      <span className="form-section-title">{t("Startup and background")}</span>
      {showLogin && <Checkbox checked={login === true} disabled={login === null} onChange={(on) => void changeLogin(on)} label={t("Open at login")} />}
      {error && <span className="error-text selectable" role="alert">{error}</span>}
      <Checkbox checked={keepRunningInBackground()} onChange={setKeepRunningInBackground} label={t("Keep running in the system tray when the window is closed")} />
      <span className="hint">{t("Scheduled runs still start and terminals keep running while the window is closed. Quit from the tray icon to stop them.")}</span>
    </div>
  );
}
