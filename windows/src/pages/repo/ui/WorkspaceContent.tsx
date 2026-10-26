import { useEffect } from "react";
import { GraphView } from "@/widgets/commit-graph";
import { DiffView, FileInspectView } from "@/widgets/diff-viewer";
import { Inspector } from "@/widgets/inspector";
import { AgentsPanel, FlowPanel, PullRequestSection, WorktreeSection } from "@/widgets/sidebar";
import { HostingHubPanel } from "@/widgets/hosting-hub";
import { projectBranchName } from "@/widgets/hosting-hub";
import { LocalBranchesPanel, RepositoryCodePanel, RevisionComparisonPanel, RebaseWorkbenchPanel } from "@/widgets/local-workbench";
import { WorkspaceHomePanel, RepositoryLibraryPanel, WorkInboxPanel, MyWorkPanel, IssuesWorkspacePanel, ActionsWorkspacePanel, OperationsWorkspacePanel } from "@/widgets/workspace-panels";
import { RepositoryAssistantSheet } from "@/features/repository-assistant";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, Empty } from "@/shared/ui";

export function WorkspaceContent({ store, openSettings }: { store: RepoStore; openSettings: () => void }) {
  const page = store.destination === "repository" ? store.repositorySection : store.destination;
  useEffect(() => { if (page === "assistant") void store.openRepositoryAssistant(false, false); }, [page, store]);
  const props = { store, openSettings };
  switch (page) {
    case "home": return <WorkspaceHomePanel {...props} />;
    case "repositories": return <RepositoryLibraryPanel {...props} />;
    case "branches": return <LocalBranchesPanel store={store} />;
    case "compare": return <RevisionComparisonPanel store={store} />;
    case "rebase": return <RebaseWorkbenchPanel store={store} />;
    case "code": return <RepositoryCodePanel store={store} />;
    case "inbox": return <WorkInboxPanel {...props} />;
    case "myWork": return <MyWorkPanel {...props} />;
    case "issues": return <IssuesWorkspacePanel {...props} />;
    case "actions": return <ActionsWorkspacePanel {...props} />;
    case "operations": return <OperationsWorkspacePanel {...props} />;
    case "pullRequests": return <PullRequestsWorkspace {...props} />;
    case "releases": case "projects": case "organizations": case "gists": return <HostingHubPanel store={store} section={page} onClone={(url) => store.openSheet({ kind: "clone", url })} projectActions={{path:store.path,branches:store.localBranches.map(branch=>branch.name),onStartTask: row => {if(store.target)store.requestNewBranch(undefined, undefined, projectBranchName(row), {id:row.id,title:row.title,url:row.url,number:row.number,repository:store.target.path,host:store.target.host});}, onOpenRequest: row => {if (row.number) store.select({kind:"pullRequest",number:row.number});}}} />;
    case "assistant": return <RepositoryAssistantSheet store={store} embedded close={() => store.navigate("home")} />;
    case "agents": return <AgentsPanel store={store} />;
    case "flows": return <FlowPanel store={store} />;
    case "worktrees": return <section className="workspace-worktrees col"><header className="row"><h1 className="grow">{t("Worktrees")}</h1><Button onClick={() => store.openSheet({ kind: "addWorktree", branch: null, start: null })}>{t("New worktree…")}</Button></header><WorktreeSection store={store} /></section>;
    default: return null;
  }
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
    <div className="workspace-pr-list"><PullRequestSection store={store} target={target} openSettings={openSettings} /></div>
    <div className="workspace-pr-detail col">
      {!selected ? <Empty title={t("Select a pull request")} detail={t("Search the list, then review the conversation, files and merge checks here.")} /> : <>
        {/* 파일을 확인하는 동안에도 대화를 유지해 작성 중인 댓글을 보존한다. */}
        <div className="workspace-pr-conversation col grow" style={{ display: diff ? "none" : "flex" }}><Inspector store={store} /></div>
        {diff && <><header className="row" style={{ padding: 10, borderBottom: "1px solid var(--border)" }}><Button onClick={() => store.closeDiff()}>{t("Back to conversation")}</Button></header><DiffView store={store} /></>}
      </>}
    </div>
  </div>;
}

export function RepositoryDocument({ store }: { store: RepoStore }) {
  if (store.fileInspect) return <FileInspectView store={store} />;
  if (store.diffSource) return <DiffView store={store} />;
  if (store.repositorySection === "changes") return <Empty title={t(store.wipCount ? "Select a file to review" : "Working directory is clean")} detail={t("Review changes, then stage the files or lines you want to commit.")} />;
  return <GraphView store={store} />;
}
