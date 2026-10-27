import { useEffect } from "react";
import { DiffView } from "@/widgets/diff-viewer";
import { Inspector, IssueDetail } from "@/widgets/inspector";
import { FlowPanel, IssueListSection, PullRequestSection } from "@/widgets/sidebar";
import { RepositoryCodePanel, RevisionComparisonPanel, RebaseWorkbenchPanel } from "@/widgets/local-workbench";
import { HostingHubPanel } from "@/widgets/hosting-hub";
import { WorkspaceHomePanel, ActionsWorkspacePanel } from "@/widgets/workspace-panels";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, Empty } from "@/shared/ui";
import { AccountWorkspacePanel } from "./AccountWorkspacePanel";
import { PageHeader } from "./PageHeader";

/** The full-width pages; the repository screen is RepositoryScreen. (macOS: WorkspaceDestinationContent.swift) */
// Pages with the shared title row; Home has its own welcome and the repository screen is the work screen
const titled = new Set(["compare", "rebase", "code", "pullRequests", "issues", "actions", "releases", "projects", "account", "flows"]);

export function WorkspaceContent({ store, openSettings }: { store: RepoStore; openSettings: () => void }) {
  useObserve(store);
  const page = <WorkspacePage store={store} openSettings={openSettings} />;
  if (!titled.has(store.destination)) return page;
  return <div className="workspace-titled"><PageHeader store={store} /><div className="workspace-titled-body">{page}</div></div>;
}

function WorkspacePage({ store, openSettings }: { store: RepoStore; openSettings: () => void }) {
  const props = { store, openSettings };
  switch (store.destination) {
    case "home": return <WorkspaceHomePanel {...props} />;
    case "compare": return <RevisionComparisonPanel store={store} />;
    case "rebase": return <RebaseWorkbenchPanel store={store} />;
    case "code": return <RepositoryCodePanel store={store} />;
    case "pullRequests": return <PullRequestsWorkspace {...props} />;
    case "issues": return <IssuesWorkspace {...props} />;
    case "actions": return <ActionsWorkspacePanel {...props} />;
    // Releases and Projects keep pages of their own, apart from the account's lists
    case "releases": case "projects": return <HostingHubPanel store={store} section={store.destination} onClone={(url) => store.openSheet({ kind: "clone", url })} />;
    case "account": return <AccountWorkspacePanel {...props} />;
    case "flows": return <FlowPanel store={store} />;
    default: return null;
  }
}

/** Issues: the shared issue list on the left, the open issue on the right, like the Pull requests page (macOS: IssuesWorkspacePanel) */
export function IssuesWorkspace({ store, openSettings }: { store: RepoStore; openSettings: () => void }) {
  useObserve(store);
  if (!store.target) return <div className="col grow" style={{ alignItems: "center", justifyContent: "center", gap: 12 }}><Empty title={t("No hosting remote")} detail={t("Open a repository with a GitHub or GitLab remote to use this workspace.")} /><Button onClick={openSettings}>{t("Connect account…")}</Button></div>;
  const detail = store.inboxDetail?.item.kind === "issue" ? store.inboxDetail : null;
  return <div className="workspace-pr-page">
    <div className="workspace-pr-list"><IssueListSection store={store} openSettings={openSettings} onPage /></div>
    <div className="workspace-pr-detail col">
      {detail ? <IssueDetail store={store} detail={detail} /> : <Empty title={t("Select an issue")} detail={t("Search the list, then read the conversation and reply here.")} />}
    </div>
  </div>;
}

function PullRequestsWorkspace({ store, openSettings }: { store: RepoStore; openSettings: () => void }) {
  useObserve(store);
  const target = store.target;
  const targetKey = target ? `${target.provider}:${target.host}/${target.path}` : "";
  useEffect(() => { if (store.target) void store.loadPullRequests(); }, [store, targetKey]);
  if (!target) return <div className="col grow" style={{ alignItems: "center", justifyContent: "center", gap: 12 }}><Empty title={t("No hosting remote")} detail={t("Open a repository with a GitHub or GitLab remote to use this workspace.")} /><Button onClick={openSettings}>{t("Connect account…")}</Button></div>;
  const selected = store.selection?.kind === "pullRequest";
  const diff = selected && store.diffSource?.kind === "review";
  return <div className="workspace-pr-page">
    <div className="workspace-pr-list"><PullRequestSection store={store} target={target} openSettings={openSettings} onPage /></div>
    <div className="workspace-pr-detail col">
      {!selected ? <Empty title={t("Select a pull request")} detail={t("Search the list, then review the conversation, files and merge checks here.")} /> : <>
        {/* 파일을 확인하는 동안에도 대화를 유지해 작성 중인 댓글을 보존한다. */}
        <div className="workspace-pr-conversation col grow" style={{ display: diff ? "none" : "flex" }}><Inspector store={store} /></div>
        {diff && <><header className="row" style={{ padding: 10, borderBottom: "1px solid var(--border)" }}><Button onClick={() => store.closeDiff()}>{t("Back to conversation")}</Button></header><DiffView store={store} /></>}
      </>}
    </div>
  </div>;
}
