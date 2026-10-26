import { useEffect } from "react";
import { DiffView } from "@/widgets/diff-viewer";
import { Inspector } from "@/widgets/inspector";
import { FlowPanel, PullRequestSection } from "@/widgets/sidebar";
import { RepositoryCodePanel, RevisionComparisonPanel, RebaseWorkbenchPanel } from "@/widgets/local-workbench";
import { WorkspaceHomePanel, IssuesWorkspacePanel, ActionsWorkspacePanel } from "@/widgets/workspace-panels";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, Empty } from "@/shared/ui";
import { AccountWorkspacePanel } from "./AccountWorkspacePanel";

/** The full-width pages; the repository screen is RepositoryScreen. (macOS: WorkspaceDestinationContent.swift) */
export function WorkspaceContent({ store, openSettings }: { store: RepoStore; openSettings: () => void }) {
  useObserve(store);
  const props = { store, openSettings };
  switch (store.destination) {
    case "home": return <WorkspaceHomePanel {...props} />;
    case "compare": return <RevisionComparisonPanel store={store} />;
    case "rebase": return <RebaseWorkbenchPanel store={store} />;
    case "code": return <RepositoryCodePanel store={store} />;
    case "pullRequests": return <PullRequestsWorkspace {...props} />;
    case "issues": return <IssuesWorkspacePanel {...props} />;
    case "actions": return <ActionsWorkspacePanel {...props} />;
    case "account": return <AccountWorkspacePanel {...props} />;
    case "flows": return <FlowPanel store={store} />;
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
