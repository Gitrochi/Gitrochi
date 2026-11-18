import { ipc } from "@/shared/api";
import icon from "@/shared/assets/icon.png";
import { env, settings } from "@/shared/config";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { updater } from "@/shared/platform";
import { Button, Checkbox, Spinner } from "@/shared/ui";
import { BackgroundSettings } from "./BackgroundSettings";

/** 버전과 자동 업데이트 */
export function AboutSettings() {
  useObserve(updater);
  useObserve(settings);
  const status =
    updater.state === "checking"
      ? t("Checking…")
      : updater.state === "available"
        ? t("Version {0} is available", updater.info?.version)
        : updater.state === "none"
          ? t("You're up to date")
          : updater.state === "error"
            ? t("Check failed: {0}", updater.error)
            : "";
  return (
    <div className="col" style={{ gap: 14 }}>
      <div className="form-section">
        <div className="row">
          <img src={icon} width={48} height={48} alt="" />
          <div className="col grow">
            <span style={{ fontSize: 16, fontWeight: 600 }}>Gitrochi {env.version}</span>
            <span className="hint">{t("An app for viewing and working with Git repositories as a graph · MIT")}</span>
          </div>
          <button className="link" onClick={() => void ipc.openUrl("https://github.com/Gitrochi/Gitrochi/releases")}>
            {t("Release notes")}</button>
        </div>
      </div>
      <div className="form-section">
        <span className="form-section-title">{t("Automatic updates")}</span>
        <Checkbox checked={updater.autoCheck} onChange={(v) => updater.setAutoCheck(v)} label={t("Check for new versions at launch and once a day")} />
        <div className="row">
          <Button disabled={updater.state === "checking" || updater.state === "downloading"} onClick={() => void updater.check(true)}>
            {t("Check now")}</Button>
          {updater.state === "checking" && <Spinner />}
          <span className="hint grow">{status}</span>
        </div>
        <span className="hint">{t("Tells you when a new version is available; click to download, install and restart. The installer runs only if its Gitrochi signature is valid.")}</span>
      </div>
      <BackgroundSettings />
    </div>
  );
}
