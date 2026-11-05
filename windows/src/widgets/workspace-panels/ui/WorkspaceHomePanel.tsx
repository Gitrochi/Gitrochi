import { useEffect, useState } from "react";
import { ArrowDownToLine, Folder, GitBranch, Plus, Search, TriangleAlert } from "lucide-react";
import { parseStatus, type WorkingStatus } from "@/entities/git";
import type { RepoStore } from "@/entities/repo";
import { ipc } from "@/shared/api";
import { basename, displayPath, recentOpened, recents, removeRecent, settings } from "@/shared/config";
import { language, t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { git, tools } from "@/shared/platform";
import { Button, showContextMenu, StatusPill } from "@/shared/ui";
import { homeChanged, homeMatches, homeOpened, homeSync } from "../model/home";
import { WorkspacePlanningDashboard } from "./WorkspacePlanningDashboard";
import "./workspace-panels.css";

/**
 * Home, as the redesign's Home board draws it: repositories first (open, clone or create one, the one opened last and
 * the recent ones), then the few tasks due today. (macOS: WorkspaceHomePanel)
 */
export function WorkspaceHomePanel({ store, repositoryOnly = false }: { store: RepoStore; openSettings?: () => void; repositoryOnly?: boolean }) {
  useObserve(settings);
  useObserve(tools);
  const gitMissing = !tools.path("git");
  const list = recents();
  const [filter, setFilter] = useState("");
  // Branch, sync state and changed files of each recent repository, read when Home appears
  const [states, setStates] = useState<Record<string, WorkingStatus>>({});
  const paths = list.join("\n");
  useEffect(() => {
    let current = true;
    void Promise.all(list.map(async (path) => {
      try {
        const result = await git(["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"], path);
        return [path, parseStatus(result.stdout)] as const;
      } catch {
        return null;
      }
    })).then((read) => {
      if (current) setStates(Object.fromEntries(read.filter((entry) => entry !== null)));
    });
    return () => { current = false; };
  }, [paths, gitMissing]);
  const filtering = !!filter.trim();
  // The list under the card; while filtering, every repository that matches, the last opened one too
  const listed = filtering ? list.filter((path) => homeMatches(path, filter)) : list.slice(1);
  const last = filtering ? undefined : list[0];
  const open = (path: string) => (path === store.path ? store.navigate("repository") : void store.openOrReport(path));
  const menu = (event: React.MouseEvent, path: string) =>
    showContextMenu(event, [
      { label: t("Show in Explorer"), onClick: () => void ipc.reveal(path) },
      ...(path === store.path ? [] : [{ label: t("Remove from list"), onClick: () => removeRecent(path) }]),
    ]);
  const lastState = last ? states[last] : undefined;
  return (
    <div className="workspace-home">
      <main className="home-page">
        <section className="home-section" aria-labelledby="home-repositories-title">
          {repositoryOnly && <p className="workspace-repository-required">{t("Open a repository to use this page.")}</p>}
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
          <h2 id="home-repositories-title">{t("Repositories")}</h2>
          <div className="home-actions">
            <Button onClick={() => void store.pickAndOpen()}><Folder size={14} />{t("Open…")}</Button>
            <Button onClick={() => store.openSheet({ kind: "clone" })}><ArrowDownToLine size={14} />{t("Clone…")}</Button>
            <Button onClick={() => void store.pickAndInit()}><Plus size={13} />{t("New repository…")}</Button>
            <label className="home-filter">
              <Search size={13} />
              <input aria-label={t("Filter repositories")} placeholder={t("Filter repositories")} value={filter} onChange={(event) => setFilter(event.target.value)} />
            </label>
          </div>
          {last && (
            <section className="home-last" aria-label={t("Last opened repository")} onContextMenu={(event) => menu(event, last)}>
              <div className="home-last-main">
                <Folder size={28} strokeWidth={1.4} />
                <div className="home-last-text">
                  <span className="home-cap">{t("Last opened")}</span>
                  <span className="home-last-name ellipsis">{basename(last)}</span>
                  <span className="home-path ellipsis">{displayPath(last)}</span>
                  {lastState && (
                    <span className="home-pills">
                      <StatusPill tone="neutral" icon={<GitBranch />}>{lastState.branch ?? t("Detached HEAD")}</StatusPill>
                      {lastState.ahead > 0 && <StatusPill tone="neutral">{t("{0} not pushed", lastState.ahead)}</StatusPill>}
                      {lastState.behind > 0 && <StatusPill tone="neutral">{t("{0} to pull", lastState.behind)}</StatusPill>}
                      {homeChanged(lastState) > 0 && <StatusPill tone="neutral">{t("{0} changed files", homeChanged(lastState))}</StatusPill>}
                    </span>
                  )}
                </div>
              </div>
              <Button kind="primary" onClick={() => open(last)}>{t("Open repository")}</Button>
            </section>
          )}
          {listed.length > 0 ? (
            <div className="home-recent">
              <span className="home-recent-title">{t("Recent")}</span>
              <div className="home-list">
                {listed.map((path) => {
                  const state = states[path], opened = recentOpened(path);
                  return (
                    <button key={path} className="home-row" onClick={() => open(path)} onContextMenu={(event) => menu(event, path)}>
                      <Folder size={16} strokeWidth={1.5} />
                      <span className="home-row-text">
                        <span className="home-row-top">
                          <span className="home-row-name ellipsis">{basename(path)}</span>
                          {opened != null && <span className="home-cap">{homeOpened(opened, Date.now(), language)}</span>}
                        </span>
                        <span className="home-row-facts">
                          <span className="home-path ellipsis">{displayPath(path)}</span>
                          {state && <>
                            <span aria-hidden className="home-dot">·</span>
                            <span className="ellipsis">{state.branch ?? t("Detached HEAD")}</span>
                            <span aria-hidden className="home-dot">·</span>
                            <span className="home-sync">{homeSync(state.ahead, state.behind)}</span>
                          </>}
                        </span>
                      </span>
                    </button>
                  );
                })}
              </div>
            </div>
          ) : (!list.length || filtering) && <span className="home-cap">{t("No repositories opened yet")}</span>}
        </section>
        {!repositoryOnly && <WorkspacePlanningDashboard store={store} todayOnly />}
      </main>
    </div>
  );
}
