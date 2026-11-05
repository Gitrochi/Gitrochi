import { Blocks, CircleDot, Code2, FolderGit2, GitCompareArrows, GitPullRequest, Home, ListChecks, ListOrdered, PanelLeftClose, PlayCircle, Settings, Tag, UserRound, Waypoints } from "lucide-react";
import { destinationEnabled, repositoryDestinations, type WorkspaceDestination } from "@/entities/git";
import { ledgerStore } from "@/entities/ledger";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import icon from "@/shared/assets/icon.png";
import "./navigation-sidebar.css";

const titles: Record<WorkspaceDestination, string> = { home: "Home", repository: "Repository", compare: "Compare", rebase: "Rebase", code: "Code", pullRequests: "Pull requests", issues: "Issues", actions: "Actions", releases: "Releases", projects: "Projects", account: "Account", flows: "Flows", ledger: "Ledger" };
/** The page name as shown in the sidebar; GitLab repositories use that server's words. (macOS: WorkspaceDestination.title(gitlab:)) */
export const destinationTitle = (page: WorkspaceDestination, gitlab = false) => t(gitlab && page === "pullRequests" ? "Merge requests" : gitlab && page === "actions" ? "Pipelines" : titles[page]);
/** Each page's icon, shared with the page title row */
export const destinationIcons = { home: Home, repository: FolderGit2, compare: GitCompareArrows, rebase: ListOrdered, code: Code2, pullRequests: GitPullRequest, issues: CircleDot, actions: PlayCircle, releases: Tag, projects: Blocks, account: UserRound, flows: Waypoints, ledger: ListChecks };
// the sections of the rail and the redesign's sidebar: Home, then the repository's own pages
const groups: { title: string | null; pages: WorkspaceDestination[] }[] = [
  { title: null, pages: ["home"] },
  { title: "Repository", pages: ["repository", "compare", "rebase", "code"] },
  { title: "GitHub", pages: ["pullRequests", "issues", "actions", "releases", "projects", "account"] },
  { title: "Tools", pages: ["flows", "ledger"] },
];

/**
 * The window's pages. Once the repository screen opens, this folds into the 52px icon rail (`compact`) and the branch
 * list takes its place; the toolbar's sidebar toggle expands it again (docs/design.md › App shell).
 * (macOS: NavigationSidebar.swift, NavigationSidebarRail.swift)
 */
export function NavigationSidebar({ store, openSettings, compact = false, onToggle }: { store: RepoStore; openSettings: () => void; compact?: boolean; onToggle?: () => void }) {
  useObserve(store);
  const ledger = ledgerStore(null);
  useObserve(ledger);
  const gitlab = store.target?.provider === "gitlab";
  const row = (page: WorkspaceDestination) => {
    const Icon = destinationIcons[page], selected = store.destination === page;
    const title = destinationTitle(page, gitlab);
    // only Ledger counts something (docs/design.md › App shell, Sidebar)
    const count = page === "ledger" ? (ledger.state?.attention.total ?? 0) : 0;
    // in the rail a page that needs a repository is dimmed but stays enabled, so its tip says why
    const blocked = compact && !store.path && repositoryDestinations.has(page);
    return <button type="button" key={page} className={`workspace-nav-item${selected ? " selected" : ""}${blocked ? " blocked" : ""}${page === "repository" ? " repository-entry" : ""}`} aria-label={title} aria-current={selected ? "page" : undefined}
      onClick={() => store.navigate(page)} data-page={page} data-tip={blocked ? t("Open a repository to use this page.") : count > 0 ? `${title} (${count})` : title}>
      <Icon size={18} strokeWidth={compact ? 1.5 : selected ? 2 : 1.7} />
      <span className="workspace-nav-copy"><span className="ellipsis">{title}</span>{page === "repository" && <small className="ellipsis">{store.path ? store.name : t("Open a repository to get started")}</small>}</span>
      {count > 0 && <span className="workspace-nav-badge">{count > 999 ? "999+" : count}</span>}
    </button>;
  };
  return <nav className={`workspace-navigation${compact ? " compact" : ""}`} aria-label={compact ? t("Collapsed navigation") : t("Workspace navigation")}>
    <div className="workspace-nav-header"><div className="workspace-nav-brand"><img src={icon} alt="" /><span><strong>Gitrochi</strong><small>{t("Workspace")}</small></span></div>{/* the rail has no toggle of its own: the toolbar's sidebar toggle expands it */}{onToggle && !compact && <button type="button" className="workspace-nav-toggle" aria-label={t("Collapse sidebar")} aria-expanded onClick={onToggle} data-tip={`${t("Collapse sidebar")} · ${navigator.platform.includes("Mac") ? "⌘" : "Ctrl"} B`}><PanelLeftClose size={18} /></button>}</div>
    <div className="workspace-nav-scroll">
      {groups.map((group, i) => <div className="workspace-nav-section" key={i}>
        {group.title && <div className="workspace-nav-group"><span className="ellipsis">{group.title === "GitHub" ? (gitlab ? "GitLab" : "GitHub") : t(group.title)}</span><span /></div>}
        <div className="workspace-nav-card">{group.pages.filter(destinationEnabled).map(row)}</div>
      </div>)}
    </div>
    <div className="workspace-nav-footer"><button type="button" className="workspace-nav-item" aria-label={t("Settings")} data-tip={`${t("Settings")} · ${navigator.platform.includes("Mac") ? "⌘" : "Ctrl"} ,`} onClick={openSettings}><Settings size={18} strokeWidth={1.7} /><span className="workspace-nav-copy"><span className="ellipsis">{t("Settings")}</span></span></button></div>
  </nav>;
}
