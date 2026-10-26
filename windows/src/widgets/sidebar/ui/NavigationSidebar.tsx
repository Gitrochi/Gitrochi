import { CircleDot, Code2, FolderGit2, GitCompareArrows, GitPullRequest, Home, ListOrdered, PanelLeftClose, PanelLeftOpen, PlayCircle, Settings, UserRound, Waypoints } from "lucide-react";
import { repositoryDestinations, type WorkspaceDestination } from "@/entities/git";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import "./navigation-sidebar.css";

const titles: Record<WorkspaceDestination, string> = { home: "Home", repository: "Repository", compare: "Compare", rebase: "Rebase", code: "Code", pullRequests: "Pull requests", issues: "Issues", actions: "Actions", account: "Account", flows: "Flows" };
/** The page name as shown in the sidebar; GitLab repositories use that server's words. (macOS: WorkspaceDestination.title(gitlab:)) */
export const destinationTitle = (page: WorkspaceDestination, gitlab = false) => t(gitlab && page === "pullRequests" ? "Merge requests" : gitlab && page === "actions" ? "Pipelines" : titles[page]);
const icons = { home: Home, repository: FolderGit2, compare: GitCompareArrows, rebase: ListOrdered, code: Code2, pullRequests: GitPullRequest, issues: CircleDot, actions: PlayCircle, account: UserRound, flows: Waypoints };
const groups: { title: string | null; pages: WorkspaceDestination[] }[] = [
  { title: null, pages: ["home", "repository"] },
  { title: "Workspace", pages: ["compare", "rebase", "code"] },
  { title: "GitHub", pages: ["pullRequests", "issues", "actions", "account"] },
  { title: "Tools", pages: ["flows"] },
];

/**
 * The window's pages. Once the repository screen opens, this folds into the icon rail (`compact`) and the branch list
 * takes its place; the rail expands it again. (macOS: NavigationSidebar.swift, NavigationSidebarRail.swift)
 */
export function NavigationSidebar({ store, openSettings, compact = false, onToggle }: { store: RepoStore; openSettings: () => void; compact?: boolean; onToggle?: () => void }) {
  useObserve(store);
  const gitlab = store.target?.provider === "gitlab";
  const row = (page: WorkspaceDestination) => {
    const Icon = icons[page], selected = store.destination === page, disabled = repositoryDestinations.has(page) && !store.path;
    const title = destinationTitle(page, gitlab);
    const count = page === "repository" ? store.wipCount : page === "pullRequests" ? store.pullRequests.length : 0;
    return <button type="button" key={page} className={`workspace-nav-item${selected ? " selected" : ""}${page === "repository" ? " repository-entry" : ""}`} aria-label={title} aria-current={selected ? "page" : undefined} disabled={disabled}
      onClick={() => store.navigate(page)} data-page={page} data-tip={disabled ? t("Open a repository to use this page.") : count > 0 ? `${title} (${count})` : title}>
      <Icon size={18} strokeWidth={selected ? 2 : 1.7} />
      <span className="workspace-nav-copy"><span className="ellipsis">{title}</span>{page === "repository" && <small className="ellipsis">{store.path ? store.name : t("Open a repository to get started")}</small>}</span>
      {count > 0 && <span className="workspace-nav-badge">{count > 999 ? "999+" : count}</span>}
    </button>;
  };
  return <nav className={`workspace-navigation${compact ? " compact" : ""}`} aria-label={compact ? t("Collapsed navigation") : t("Workspace navigation")}>
    {onToggle && <div className="workspace-nav-header"><span>{t("Workspace")}</span><button type="button" className="workspace-nav-toggle" aria-label={t(compact ? "Expand sidebar" : "Collapse sidebar")} aria-expanded={!compact} onClick={onToggle} data-tip={`${t(compact ? "Expand sidebar" : "Collapse sidebar")} · ${navigator.platform.includes("Mac") ? "⌘" : "Ctrl"} B`}>{compact ? <PanelLeftOpen size={18} /> : <PanelLeftClose size={18} />}</button></div>}
    <div className="workspace-nav-scroll">
      {groups.map((group, i) => <div className="workspace-nav-section" key={i}>
        {group.title && <div className="workspace-nav-group"><span className="ellipsis">{group.title === "GitHub" ? (gitlab ? "GitLab" : "GitHub") : t(group.title)}</span><span /></div>}
        {group.pages.map(row)}
      </div>)}
    </div>
    <div className="workspace-nav-footer"><button type="button" className="workspace-nav-item" aria-label={t("Settings")} data-tip={`${t("Settings")} · ${navigator.platform.includes("Mac") ? "⌘" : "Ctrl"} ,`} onClick={openSettings}><Settings size={18} strokeWidth={1.7} /><span className="workspace-nav-copy"><span className="ellipsis">{t("Settings")}</span></span></button></div>
  </nav>;
}
