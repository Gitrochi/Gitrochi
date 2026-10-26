import { AddWorktreeSheet } from "@/features/add-worktree";
import { CloneSheet } from "@/features/clone-repo";
import { NewBranchSheet } from "@/features/create-branch";
import { CreatePullRequestSheet } from "@/features/create-pull-request";
import { TagSheet } from "@/features/create-tag";
import { GitchBackupsSheet } from "@/features/gitch-backups";
import { GraphCheckSheet } from "@/features/graph-check";
import { GraphDiffSheet } from "@/features/graph-diff";
import { InteractiveRebaseSheet } from "@/features/interactive-rebase";
import { RunPipelineSheet } from "@/features/run-pipeline";
import { SplitCommitsSheet } from "@/features/split-commits";
import { StartAgentSheet } from "@/features/start-agent";
import { StashSheet } from "@/features/stash-changes";
import { PushReviewSheet } from "@/features/push-review";
import { AskChangesSheet } from "@/features/ask-changes";
import { CompareRevisionsSheet, BatchCommitsSheet, LineHistorySheet } from "@/features/history-tools";
import { LocalWorkflowsSheet } from "@/features/local-workflows";
import { WorkspaceOverviewSheet } from "@/features/workspace-overview";
import { CollaborationInboxSheet } from "@/features/collaboration-inbox";
import { RepositoryAssistantSheet, MCPConnectionSheet } from "@/features/repository-assistant";
import type { SheetKind } from "@/entities/git";
import type { RepoStore } from "@/entities/repo";

export function SheetHost({ store }: { store: RepoStore }) {
  const s = store.sheet;
  if (!s) return null;
  const close = () => {
    if (s.kind === "pushReview") store.cancelPushReview();
    if (s.kind === "askChanges") store.cancelChangeQuestion();
    if (s.kind === "repositoryAssistant") store.cancelRepositoryAssistant();
    store.sheet = null;
    store.changed();
  };
  return <SheetSwitch store={store} sheet={s} close={close} />;
}

function SheetSwitch({ store, sheet, close }: { store: RepoStore; sheet: SheetKind; close: () => void }) {
  switch (sheet.kind) {
    case "clone":
      return <CloneSheet store={store} close={close} initialURL={sheet.url} />;
    case "stash":
      return <StashSheet store={store} close={close} />;
    case "newBranch":
      return <NewBranchSheet store={store} close={close} start={sheet.start} label={sheet.label} />;
    case "tag":
      return <TagSheet store={store} close={close} sha={sheet.sha} />;
    case "createPullRequest":
      return <CreatePullRequestSheet store={store} close={close} />;
    case "pushReview":
      return <PushReviewSheet store={store} close={close} branch={sheet.branch} force={sheet.force} remoteOverride={sheet.remoteOverride} />;
    case "askChanges":
      return <AskChangesSheet store={store} close={close} />;
    case "compareRevisions": return <CompareRevisionsSheet store={store} close={close} />;
    case "batchCommits": return <BatchCommitsSheet store={store} close={close} />;
    case "lineHistory": return <LineHistorySheet store={store} close={close} />;
    case "localWorkflows": return <LocalWorkflowsSheet store={store} close={close} />;
    case "workspaceOverview": return <WorkspaceOverviewSheet store={store} close={close} />;
    case "collaborationInbox": return <CollaborationInboxSheet store={store} close={close} />;
    case "repositoryAssistant": return <RepositoryAssistantSheet store={store} close={close} />;
    case "mcpConnection": return <MCPConnectionSheet store={store} close={close} />;
    case "startAgent":
      return <StartAgentSheet store={store} close={close} presetPath={sheet.path} />;
    case "addWorktree":
      return <AddWorktreeSheet store={store} close={close} presetBranch={sheet.branch} start={sheet.start} />;
    case "splitCommits":
      return <SplitCommitsSheet store={store} close={close} />;
    case "runPipeline":
      return <RunPipelineSheet store={store} close={close} />;
    case "interactiveRebase":
      return <InteractiveRebaseSheet store={store} close={close} />;
    case "gitchBackups":
      return <GitchBackupsSheet store={store} close={close} />;
    case "graphDiff":
      return <GraphDiffSheet store={store} close={close} />;
    case "graphCheck":
      return <GraphCheckSheet store={store} close={close} />;
  }
}
