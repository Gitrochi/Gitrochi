import { CopyPlus, Download, FolderOpen, TriangleAlert } from "lucide-react";
import type { RepoStore } from "@/entities/repo";
import { ipc } from "@/shared/api";
import icon from "@/shared/assets/icon.png";
import { basename, displayPath, recents, removeRecent, settings } from "@/shared/config";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { tools } from "@/shared/platform";
import { Button, showContextMenu } from "@/shared/ui";
import { WorkspacePlanningDashboard } from "./WorkspacePlanningDashboard";
import { RemoteRepositorySearch } from "./RemoteRepositorySearch";
import "./workspace-panels.css";

/** Home: open, clone or create a repository, the recent list and a search of repositories on a server (macOS: WelcomeView) */
export function WorkspaceHomePanel({ store, openSettings }: { store: RepoStore; openSettings?: () => void }) {
  useObserve(settings);
  useObserve(tools);
  const gitMissing = !tools.path("git");
  const list = recents();
  return (
    <div className="workspace-home">
      <WorkspacePlanningDashboard store={store} />
    <div className="welcome">
      <div className="welcome-main">
        <img src={icon} width={112} height={112} alt="" />
        <div style={{ fontSize: 28, fontWeight: 700 }}>Gitrochi</div>
        <div className="muted">{t("An app for viewing and working with Git repositories as a graph")}</div>
        {gitMissing && (
          <div className="card" style={{ maxWidth: 420, borderColor: "var(--orange)" }}>
            <span className="row" style={{ color: "var(--orange)", fontWeight: 600 }}>
              <TriangleAlert size={15} /> {" "}{t("Couldn't find git")}</span>
            <span className="muted">{t("Gitrochi uses the git installed on this PC. Install Git for Windows, or locate git.exe if you already have it.")}</span>
            <div className="row">
              <Button kind="primary" onClick={() => void ipc.openUrl("https://git-scm.com/download/win")}>
                {t("Get Git for Windows")}</Button>
              <Button
                onClick={() =>
                  void ipc.pickFile(t("Choose git.exe")).then((p) => {
                    if (p)
                      tools.setCustom("git", p).catch((e) => {
                        store.errorMessage = String(e instanceof Error ? e.message : e);
                        store.changed();
                      });
                  })
                }
              >
                {t("Locate git.exe…")}</Button>
            </div>
          </div>
        )}
        <div className="card" style={{ maxWidth: 420, textAlign: "left", gap: 8 }}>
          <strong>{t("New here? Start with your Git account")}</strong>
          <span className="hint">{t("Gitrochi includes gitch for Git accounts and code graphs. Add your account, register an SSH key, and learn the app's tools step by step.")}</span>
          <Button onClick={() => window.dispatchEvent(new CustomEvent("gitrochi-open-settings", { detail: "cli" }))}>{t("Get started with Git accounts…")}</Button>
        </div>
        <div className="col" style={{ gap: 8, marginTop: 8 }}>
          <Button kind="primary" size="large" style={{ width: 240 }} onClick={() => void store.pickAndOpen()}>
            <FolderOpen size={15} /> {" "}{t("Open repository…")}</Button>
          <Button size="large" style={{ width: 240 }} onClick={() => store.openSheet({ kind: "clone" })}>
            <Download size={15} /> {" "}{t("Clone repository…")}</Button>
          <Button size="large" style={{ width: 240 }} onClick={() => void store.pickAndInit()}>
            <CopyPlus size={15} /> {" "}{t("Create new repository…")}</Button>
        </div>
      </div>
      <div className="welcome-recents">
        <div style={{ fontWeight: 600, padding: 16 }}>{t("Recent repositories")}</div>
        {list.length === 0 ? (
          <div className="muted" style={{ padding: "0 16px 12px" }}>
            {t("No repositories opened yet")}</div>
        ) : (
          <div className="col welcome-recent-list" style={{ gap: 2 }}>
            {list.map((p) => (
              <div
                key={p}
                className="recent-item"
                onClick={() => void store.openOrReport(p)}
                onContextMenu={(e) =>
                  showContextMenu(e, [
                    { label: t("Show in Explorer"), onClick: () => void ipc.reveal(p) },
                    { label: t("Remove from list"), onClick: () => removeRecent(p) },
                  ])
                }
              >
                <div style={{ fontWeight: 500 }}>{basename(p)}</div>
                <div className="muted ellipsis" style={{ fontSize: 11.5, direction: "rtl", textAlign: "left" }}>
                  <bdi>{displayPath(p)}</bdi>
                </div>
              </div>
            ))}
          </div>
        )}
        <RemoteRepositorySearch store={store} openSettings={openSettings} />
      </div>
    </div>
    </div>
  );
}
