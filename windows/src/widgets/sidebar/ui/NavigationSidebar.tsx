import { useEffect, useState } from "react";
import { destinationAvailable, destinationEnabled, destinationShortcut, type WorkspaceDestination } from "@/entities/git";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { tip } from "@/shared/ui";
import { designIcon } from "@/shared/icons";
import "./navigation-sidebar.css";

const titles: Record<WorkspaceDestination, string> = { home: "Home", repository: "Repository", compare: "Compare", rebase: "Rebase", code: "Code", pullRequests: "Pull requests", issues: "Issues", actions: "Actions", releases: "Releases", projects: "Projects", account: "Account", flows: "Flows" };
/** The page name as shown in the sidebar; GitLab repositories use that server's words. (macOS: WorkspaceDestination.title(gitlab:)) */
export const destinationTitle = (page: WorkspaceDestination, gitlab = false) => t(gitlab && page === "pullRequests" ? "Merge requests" : gitlab && page === "actions" ? "Pipelines" : titles[page]);
/** Each page's icon, shared with the page title row */
export const destinationIcons = { home: designIcon("home"), repository: designIcon("repository"), compare: designIcon("compare"), rebase: designIcon("rebase"), code: designIcon("code"), pullRequests: designIcon("pullRequests"), issues: designIcon("issues"), actions: designIcon("actions"), releases: designIcon("releases"), projects: designIcon("projects"), account: designIcon("account"), flows: designIcon("flows") };
const Settings = designIcon("settings");
// the sections of the rail and the redesign's sidebar: Home, then the repository's own pages
const groups: { title: string | null; pages: WorkspaceDestination[] }[] = [
  { title: null, pages: ["home"] },
  { title: "Repository", pages: ["repository", "compare", "rebase", "code"] },
  { title: "GitHub", pages: ["pullRequests", "issues", "actions", "releases", "projects", "account"] },
  { title: "Tools", pages: ["flows"] },
];

/**
 * The window's pages (docs/design.md › App shell, Sidebar): a source list with section titles, a neutral fill for the
 * current page (never the accent, as in the rail). While no repository is open, a page that
 * needs one is disabled and one line under Home says why. Once the repository screen opens, this folds into the 52px icon rail
 * (`compact`), where such a page is dimmed and does nothing but is not disabled, so its tip can say why. The toolbar's
 * sidebar toggle folds and expands it. (macOS: NavigationSidebar.swift, NavigationSidebarRail.swift)
 */
export function NavigationSidebar({ store, openSettings, compact = false }: { store: RepoStore; openSettings: () => void; compact?: boolean }) {
  useObserve(store);
  // holding Ctrl shows every row's shortcut; otherwise a row shows its own on hover
  const [shortcutsShown, setShortcutsShown] = useState(false);
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => setShortcutsShown(e.ctrlKey);
    const onBlur = () => setShortcutsShown(false);
    window.addEventListener("keydown", onKey);
    window.addEventListener("keyup", onKey);
    window.addEventListener("blur", onBlur);
    return () => { window.removeEventListener("keydown", onKey); window.removeEventListener("keyup", onKey); window.removeEventListener("blur", onBlur); };
  }, []);
  const gitlab = store.target?.provider === "gitlab";
  const isBlocked = (page: WorkspaceDestination) => !destinationAvailable(page, !!store.path);
  const row = (page: WorkspaceDestination) => {
    const Icon = destinationIcons[page], selected = store.destination === page;
    const title = destinationTitle(page, gitlab);
    const shortcut = destinationShortcut(page);
    const blocked = isBlocked(page);
    // the list says why under the section; the rail has no room for that, so a blocked icon keeps a tip and the store
    // refuses it
    return <button type="button" key={page} className={`workspace-nav-item${selected ? " selected" : ""}${blocked ? " blocked" : ""}`} aria-label={title} aria-current={selected ? "page" : undefined}
      disabled={blocked && !compact} aria-disabled={blocked && compact ? true : undefined} onClick={() => store.navigate(page)} data-page={page}
      data-tip={!blocked ? tip(title, "", shortcut ?? undefined) : compact ? t("Open a repository to use this page.") : undefined}>
      <Icon size={compact ? 18 : 16} />
      <span className="workspace-nav-copy"><span className="ellipsis">{title}</span></span>
      {shortcut && <span className="workspace-nav-kbd">{shortcut}</span>}
    </button>;
  };
  return <nav className={`workspace-navigation${compact ? " compact" : ""}${shortcutsShown ? " show-shortcuts" : ""}`} aria-label={compact ? t("Collapsed navigation") : t("Workspace navigation")}>
    <div className="workspace-nav-scroll">
      {(() => {
        const anyBlocked = groups.some((group) => group.pages.filter(destinationEnabled).some(isBlocked));
        return groups.map((group, i) => {
        const pages = group.pages.filter(destinationEnabled);
        return <div className="workspace-nav-section" key={i}>
          {group.title && <div className="workspace-nav-group"><span className="ellipsis">{group.title === "GitHub" ? (gitlab ? "GitLab" : "GitHub") : t(group.title)}</span><span /></div>}
          <div className="workspace-nav-card">{pages.map(row)}</div>
          {/* one line under Home says why the dimmed pages can't be opened (a disabled row shows no tip); a line under
              every section repeated it */}
          {!group.title && anyBlocked && <div className="workspace-nav-why">{t("Open a repository to use the dimmed pages")}</div>}
        </div>;
        });
      })()}
    </div>
    <div className="workspace-nav-footer"><button type="button" className="workspace-nav-item" aria-label={t("Settings")} data-tip={tip(t("Settings"), "", "Ctrl+,")} onClick={openSettings}><Settings size={compact ? 18 : 16} /><span className="workspace-nav-copy"><span className="ellipsis">{t("Settings")}</span></span><span className="workspace-nav-kbd">Ctrl+,</span></button></div>
  </nav>;
}
