import { lazy, Suspense } from "react";
import { IssueDetail } from "@/widgets/inspector";
import { destinationTitle, FlowPanel, IssueListSection } from "@/widgets/sidebar";
import { RepositoryCodePanel, RevisionComparisonPanel, RebaseWorkbenchPanel } from "@/widgets/local-workbench";
import { HostingHubPanel, projectBranchName } from "@/widgets/hosting-hub";
import { WorkspaceHomePanel, ActionsWorkspacePanel } from "@/widgets/workspace-panels";
import type { RepoStore } from "@/entities/repo";
import { repositoryDestinations } from "@/entities/git";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, Empty, Spinner } from "@/shared/ui";
import { AccountWorkspacePanel } from "./AccountWorkspacePanel";
import { PullRequestsWorkspace } from "./PullRequestsWorkspace";

// The Ledger is a preview page: its code loads the first time it opens
const LedgerWorkspace = lazy(() => import("@/widgets/ledger-workspace").then((module) => ({ default: module.LedgerWorkspace })));

/**
 * The full-width pages; the repository screen is RepositoryScreen. (macOS: WorkspaceDestinationContent.swift)
 * No title row: the selected sidebar item names the page and the toolbar is the only title (docs/design.md › App shell);
 * screen readers still hear the page name.
 */
export function WorkspaceContent({ store, openSettings }: { store: RepoStore; openSettings: () => void }) {
  useObserve(store);
  return (
    <section className="workspace-page" aria-label={destinationTitle(store.destination, store.target?.provider === "gitlab")}>
      <WorkspacePage store={store} openSettings={openSettings} />
    </section>
  );
}

function WorkspacePage({ store, openSettings }: { store: RepoStore; openSettings: () => void }) {
  const props = { store, openSettings };
  if (!store.path && (repositoryDestinations.has(store.destination) || store.destination === "issues" || store.destination === "releases")) return <WorkspaceHomePanel {...props} repositoryOnly />;
  switch (store.destination) {
    case "home": return <WorkspaceHomePanel {...props} />;
    case "compare": return <RevisionComparisonPanel store={store} />;
    case "rebase": return <RebaseWorkbenchPanel store={store} />;
    case "code": return <RepositoryCodePanel store={store} />;
    case "pullRequests": return <PullRequestsWorkspace {...props} />;
    case "issues": return <IssuesWorkspace {...props} />;
    case "actions": return <ActionsWorkspacePanel {...props} />;
    // Releases and Projects keep pages of their own, apart from the account's lists
    case "releases": case "projects": return <HostingHubPanel store={store} section={store.destination} onClone={(url) => store.openSheet({ kind: "clone", url })} projectActions={{path:store.path,branches:store.localBranches.map(branch=>branch.name),onStartTask: row => {if(store.target)store.requestNewBranch(undefined, undefined, projectBranchName(row), {id:row.id,title:row.title,url:row.url,number:row.number,repository:store.target.path,host:store.target.host});}, onOpenRequest: row => {if (row.number) {store.navigate("pullRequests");store.select({kind:"pullRequest",number:row.number});}}}} />;
    case "account": return <AccountWorkspacePanel {...props} />;
    case "flows": return <FlowPanel store={store} />;
    case "ledger": return <Suspense fallback={<div className="col grow" style={{ alignItems: "center", justifyContent: "center" }}><Spinner /></div>}><LedgerWorkspace repoPath={store.path} launcher={store} requests={store} flows={store} /></Suspense>;
    default: return null;
  }
}

/** Issues: the shared issue list on the left, the open issue on the right, like the Pull requests page (macOS: IssuesWorkspacePanel) */
export function IssuesWorkspace({ store, openSettings }: { store: RepoStore; openSettings: () => void }) {
  useObserve(store);
  if (!store.target) return <div className="col grow" style={{ alignItems: "center", justifyContent: "center", gap: 12 }}><Empty title={t("No hosting remote")} detail={t("Open a repository with a GitHub or GitLab remote to use this workspace.")} /><Button onClick={() => void store.pickAndOpen()}>{t("Open repository…")}</Button></div>;
  const detail = store.inboxDetail?.item.kind === "issue" ? store.inboxDetail : null;
  return <div className="workspace-pr-page">
    <div className="workspace-pr-list"><IssueListSection store={store} openSettings={openSettings} onPage /></div>
    <div className="workspace-pr-detail col">
      {detail ? <IssueDetail store={store} detail={detail} /> : <Empty title={t("Select an issue")} detail={t("Search the list, then read the conversation and reply here.")} />}
    </div>
  </div>;
}
