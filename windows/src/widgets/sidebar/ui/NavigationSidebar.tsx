import { useEffect, useState } from "react";
import { Blocks, CircleDot, Code2, FolderGit2, GitCompareArrows, GitPullRequest, Home, ListChecks, ListOrdered, PlayCircle, Settings, Tag, UserRound, Waypoints } from "lucide-react";
import { destinationEnabled, destinationShortcut, repositoryDestinations, type WorkspaceDestination } from "@/entities/git";
import { openedLedgerStore } from "@/entities/ledger";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { Observable, useObserve } from "@/shared/lib";
import { tip } from "@/shared/ui";
import "./navigation-sidebar.css";

const titles: Record<WorkspaceDestination, string> = { home: "Home", repository: "Repository", compare: "Compare", rebase: "Rebase", code: "Code", pullRequests: "Pull requests", issues: "Issues", actions: "Actions", releases: "Releases", projects: "Projects", account: "Account", flows: "Flows", ledger: "Ledger" };
/** The page name as shown in the sidebar; GitLab repositories use that server's words. (macOS: WorkspaceDestination.title(gitlab:)) */
export const destinationTitle = (page: WorkspaceDestination, gitlab = false) => t(gitlab && page === "pullRequests" ? "Merge requests" : gitlab && page === "actions" ? "Pipelines" : titles[page]);
/** Each page's icon, shared with the page title row */
export const destinationIcons = { home: Home, repository: FolderGit2, compare: GitCompareArrows, rebase: ListOrdered, code: Code2, pullRequests: GitPullRequest, issues: CircleDot, actions: PlayCircle, releases: Tag, projects: Blocks, account: UserRound, flows: Waypoints, ledger: ListChecks };
// the sections of the rail and the redesign's sidebar: Home, then the repository's own pages
/** Stands in for the Ledger while nothing has opened it; it never changes */
const unopened = new Observable();

const groups: { title: string | null; pages: WorkspaceDestination[] }[] = [
  { title: null, pages: ["home"] },
  { title: "Repository", pages: ["repository", "compare", "rebase", "code"] },
  { title: "GitHub", pages: ["pullRequests", "issues", "actions", "releases", "projects", "account"] },
  { title: "Tools", pages: ["flows", "ledger"] },
];

/**
 * The window's pages (docs/design.md › App shell, Sidebar): a source list with section titles, a neutral fill for the
 * current page (never the accent, as in the rail) and only Ledger's count. While no repository is open, a page that
 * needs one is disabled and its section says why. Once the repository screen opens, this folds into the 52px icon rail
 * (`compact`), where such a page is dimmed but stays enabled so its tip says why. The toolbar's sidebar toggle folds
 * and expands it. (macOS: NavigationSidebar.swift, NavigationSidebarRail.swift)
 */
export function NavigationSidebar({ store, openSettings, compact = false }: { store: RepoStore; openSettings: () => void; compact?: boolean }) {
  useObserve(store);
  // only read the Ledger once something has opened it; the page list must not be what opens it
  const ledger = openedLedgerStore();
  useObserve(ledger ?? unopened);
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
  const needsRepository = (page: WorkspaceDestination) => !store.path && repositoryDestinations.has(page);
  const row = (page: WorkspaceDestination) => {
    const Icon = destinationIcons[page], selected = store.destination === page;
    const title = destinationTitle(page, gitlab);
    const shortcut = destinationShortcut(page);
    // only Ledger counts something
    const count = page === "ledger" ? (ledger?.state?.attention.total ?? 0) : 0;
    const blocked = needsRepository(page);
    return <button type="button" key={page} className={`workspace-nav-item${selected ? " selected" : ""}${blocked ? " blocked" : ""}`} aria-label={title} aria-current={selected ? "page" : undefined}
      disabled={blocked && !compact} onClick={() => store.navigate(page)} data-page={page}
      data-tip={blocked ? t("Open a repository to use this page.") : tip(count > 0 ? `${title} (${count})` : title, "", shortcut ?? undefined)}>
      <Icon size={compact ? 18 : 16} strokeWidth={1.5} />
      <span className="workspace-nav-copy"><span className="ellipsis">{title}</span></span>
      {count > 0 && <span className="workspace-nav-badge">{count > 999 ? "999+" : count}</span>}
      {shortcut && <span className="workspace-nav-kbd">{shortcut}</span>}
    </button>;
  };
  return <nav className={`workspace-navigation${compact ? " compact" : ""}${shortcutsShown ? " show-shortcuts" : ""}`} aria-label={compact ? t("Collapsed navigation") : t("Workspace navigation")}>
    <div className="workspace-nav-scroll">
      {groups.map((group, i) => {
        const pages = group.pages.filter(destinationEnabled);
        return <div className="workspace-nav-section" key={i}>
          {group.title && <div className="workspace-nav-group"><span className="ellipsis">{group.title === "GitHub" ? (gitlab ? "GitLab" : "GitHub") : t(group.title)}</span><span /></div>}
          {/* the reason sits under the section, not in a tip: a disabled row shows no tip */}
          {group.title && pages.some(needsRepository) && <div className="workspace-nav-why">{t("Open a repository to use these")}</div>}
          <div className="workspace-nav-card">{pages.map(row)}</div>
        </div>;
      })}
    </div>
    <div className="workspace-nav-footer"><button type="button" className="workspace-nav-item" aria-label={t("Settings")} data-tip={tip(t("Settings"), "", "Ctrl+,")} onClick={openSettings}><Settings size={compact ? 18 : 16} strokeWidth={1.5} /><span className="workspace-nav-copy"><span className="ellipsis">{t("Settings")}</span></span><span className="workspace-nav-kbd">Ctrl+,</span></button></div>
  </nav>;
}
