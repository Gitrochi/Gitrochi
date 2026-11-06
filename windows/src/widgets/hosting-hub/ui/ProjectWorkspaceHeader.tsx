import { ChevronDown, Ellipsis, Plus, RefreshCw, SquareCheck } from "lucide-react";
import type { HostAccount } from "@/entities/git";
import { accounts, type HostingHubStore, type HubItem } from "@/entities/hosting";
import { ProjectScopeFailureStrip, ProjectScopeMenu, type ProjectScopeCatalogs } from "@/features/select-project-scope";
import { t } from "@/shared/i18n";
import { Button, type MenuItem, Segmented, showMenuBelow } from "@/shared/ui";

/** What the header asks the open project's workspace to show */
export type ProjectWorkspaceCommand = "task" | "project" | "fields" | "views";

/**
 * The Projects page's header, as the redesign's Projects board draws it: whose projects are shown and where they are
 * kept, then the project with its one filled action. macOS: ProjectWorkspaceHeader.
 */
export function ProjectWorkspaceHeader({ hub, catalogs, locked, creating, repositoryOwner, newProject, refresh, choose, command, openBrowser, deleteProject }: {
  hub: HostingHubStore;
  catalogs: ProjectScopeCatalogs;
  locked: boolean;
  /** The creation dialog is open: the source and the project stay as they are until it closes */
  creating: boolean;
  repositoryOwner: (account: HostAccount) => string | null;
  newProject: () => void;
  refresh: () => void;
  choose: (item: HubItem) => void;
  command: (value: ProjectWorkspaceCommand) => void;
  /** Present when the project has a page on the server that is safe to open */
  openBrowser?: () => void;
  /** Present for a local project, the only kind the app can delete */
  deleteProject?: () => void;
}) {
  const detail = hub.detail, local = hub.projectSource === "local", gitlab = hub.provider === "gitlab";
  // The account the page returns to from Local names the other side of the switch.
  const remote = (accounts.accounts.find((account) => account.id === hub.selectedAccountID) ?? hub.source.hostingAccount ?? accounts.accounts[0])?.provider === "gitlab" ? "GitLab" : "GitHub";
  const title = detail?.item.title ?? t("Choose a project");
  const caption = detail ? detail.item.body || t(local ? "Local project" : gitlab ? "GitLab issue board" : "GitHub project") : "";
  const projects = (): MenuItem[] => [
    ...hub.items.map((item): MenuItem => ({ label: item.title, checked: item.id === detail?.item.id, onClick: () => choose(item) })),
    ...(hub.more ? [{ label: t("Load more projects"), onClick: () => void hub.load(true) }] : []),
    "divider",
    { label: t("New project…"), onClick: newProject },
  ];
  // The board's menu is New, Rename and Delete; what the page already offered sits between them. Destructive comes last.
  const more = (): MenuItem[] => {
    const groups: MenuItem[][] = [
      [{ label: t("New project…"), onClick: newProject }, ...(gitlab ? [] : [{ label: t("Rename project…"), onClick: () => command("project") }])],
      [
        ...(!gitlab && !local ? [{ label: t("Manage fields…"), onClick: () => command("fields") }, { label: t("Manage shared views…"), onClick: () => command("views") }] : []),
        ...(openBrowser ? [{ label: t("Open in browser"), onClick: openBrowser }] : []),
      ],
      deleteProject ? [{ label: t("Delete project…"), danger: true, onClick: deleteProject }] : [],
    ];
    return groups.filter((group) => group.length).flatMap((group, index) => (index ? ["divider" as const, ...group] : group));
  };
  return <>
    <div className="project-scope-row" role="group" aria-label={t("Project scope")}>
      <ProjectScopeMenu catalogs={catalogs} account={hub.account} scope={hub.projectEffectiveScope} repositoryOwner={repositoryOwner} count={hub.items.length} more={hub.more} loading={hub.loading} local={local} disabled={locked || creating}
        onChange={(scope, accountID) => void hub.selectProjectScope(scope, accountID)} />
      <div className="project-source" role="group" aria-label={t("Project source")}>
        <Segmented value={hub.projectSource} options={[{ value: "local", label: t("Local") }, { value: "remote", label: remote }]} onChange={(source) => { if (!hub.busy && !creating) void hub.selectProjectSource(source); }} />
      </div>
      <Button className="project-icon-button" tip={t("Refresh")} aria-label={t("Refresh")} disabled={locked} onClick={refresh}><RefreshCw size={14} /></Button>
    </div>
    {!local && <div className="project-scope-failure"><ProjectScopeFailureStrip catalogs={catalogs} account={hub.account} /></div>}
    {/* With no project and nothing failed the empty state below says so; a title would have nothing to name. */}
    {(detail || hub.items.length > 0 || hub.error) && <div className="project-title-row">
      <div className="project-title-main">
        <button type="button" className="project-title-menu" aria-haspopup="menu" aria-label={`${t("Project")}: ${title}`} disabled={hub.busy || creating} onClick={(event) => showMenuBelow(event.currentTarget, projects())}>
          <SquareCheck size={16} aria-hidden /><span>{title}</span><ChevronDown size={12} aria-hidden />
        </button>
        {caption && <span className="project-title-caption">{caption}</span>}
      </div>
      {detail && <div className="project-header-actions">
        <Button className="project-icon-button" tip={t("More project actions")} aria-label={t("More project actions")} aria-haspopup="menu" disabled={locked} onClick={(event) => showMenuBelow(event.currentTarget, more())}><Ellipsis size={14} /></Button>
        <Button kind="primary" disabled={locked} onClick={() => command("task")}><Plus size={13} />{t("New task…")}</Button>
      </div>}
    </div>}
  </>;
}
