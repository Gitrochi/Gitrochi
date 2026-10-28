import { releaseMarkdownLinks } from "@/entities/hosting";
import { Download } from "lucide-react";
import { env } from "@/shared/config";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { updater } from "@/shared/platform";
import { Button, Markdown, Modal, Spinner } from "@/shared/ui";

const mb = (n: number) => (n / 1024 / 1024).toFixed(1);

/** 새 버전 안내 → 받기 → 설치 → 다시 시작 */
export function UpdateDialog() {
  useObserve(updater);
  if (!updater.prompt) return null;
  const u = updater.info;
  const busy = updater.state === "downloading" || updater.state === "installing";
  const close = () => !busy && updater.dismiss();

  if (updater.state === "error" && !u) {
    return (
      <Modal title={t("Couldn't check for updates")} onClose={close} footer={<Button onClick={close}>{t("OK")}</Button>}>
        <div className="modal-message selectable">{updater.error}</div>
      </Modal>
    );
  }
  if (!u) {
    return (
      <Modal title={t("You're up to date")} onClose={close} footer={<Button kind="primary" onClick={close}>{t("OK")}</Button>}>
        <div className="modal-message">{t("Gitrochi {0} is the latest version.", env.version)}</div>
      </Modal>
    );
  }
  const pct = updater.total ? Math.min(100, (updater.downloaded / updater.total) * 100) : null;
  return (
    <Modal
      title={t("Version {0} is out", u.version)}
      width={540}
      onClose={close}
      footer={
        busy ? (
          <span className="row muted">
            <Spinner size={13} /> {updater.state === "installing" ? t("Installing… Gitrochi restarts when done") : t("Downloading…")}
          </span>
        ) : (
          <>
            <Button onClick={() => updater.skip()}>{t("Skip this version")}</Button>
            <Button onClick={close}>{t("Later")}</Button>
            <Button kind="primary" onClick={() => void updater.install()}>
              <Download size={14} /> {" "}{t("Update now")}</Button>
          </>
        )
      }
    >
      <div className="muted">
        {t("Current version {0} → {1}{2}", u.current, u.version, u.date ? ` · ${u.date.slice(0, 10)}` : "")}</div>
      {u.notes && (
        <div className="markdown selectable" style={{ maxHeight: 260, overflow: "auto", border: "1px solid var(--border)", borderRadius: 6, padding: 10, fontSize: 12.5 }}>
          <Markdown text={u.notes} {...releaseMarkdownLinks({provider: "github", remote: "origin", host: "github.com", path: "Gitrochi/Gitrochi"}, `v${u.version}`)}/>
        </div>
      )}
      {busy && (
        <div className="col" style={{ gap: 4 }}>
          <div style={{ height: 6, borderRadius: 99, background: "var(--hover)", overflow: "hidden" }}>
            <div style={{ height: "100%", width: pct === null ? "30%" : `${pct}%`, background: "var(--accent)", transition: "width .2s" }} />
          </div>
          <span className="hint">
            {mb(updater.downloaded)}MB{updater.total ? ` / ${mb(updater.total)}MB` : ""}
          </span>
        </div>
      )}
      {updater.state === "error" && <span className="error-text">{updater.error}</span>}
      <span className="hint">{t("The installer runs only if its Gitrochi signature is valid. The window closes briefly and reopens during installation.")}</span>
    </Modal>
  );
}
