// entities/git 의 공개 API — 다른 조각은 이 파일로만 가져온다
export { workspaceDestinations, repositoryDestinations, returnsToRepository, isWorkspaceDestination, restoredDestination, type WorkspaceDestination } from "./model/workspace-navigation";
export { choiceLines, choiceTitle, conflictProjection, type ConflictBlock, type ConflictChoice, type ConflictDocument, parseConflict, resolveConflict } from "./lib/conflict";
export { buildPatch, canEditLines, diffSides, modeSummary, type SplitRow, splitRows } from "./lib/diff";
export { layoutGraph, layoutGraphAsync } from "./lib/graph";
export { detailFormat, fileHistoryFormat, logFormat, newFileDiff, newFileDiffAsync, parseBlame, parseBlameAsync, parseCommitDetail, parseDiff, parseDiffAsync, parseFileHistory, parseFileHistoryAsync, parseIdentityConfig, parseLog, parseLogAsync, parseNameStatus, parseNumstat, parseRefs, parseRemotes, parseStashes, parseStatus, parseWorktrees, refFormat, stashFormat } from "./lib/parsers";
export { makePlan, planChanged, planProblem, rebaseActions, rebaseItem, type RebaseItem, type RebasePlan, rebaseTodo, shellQuote } from "./lib/rebase";
export { parseSplitPlan, type SplitGroup } from "./lib/split";
export { CommitSearchQuery } from "./lib/search";
export { accountApiBase, accountHost, type BlameLine, type Branch, branchRemote, branchShort, canLoadImage, changeId, type ChangeKind, changePaths, type Commit, type CommitDetail, type ConfirmRequest, type DiffDocument, type DiffLine, type DiffSource, type DropChoice, type DropRequest, emptyStatus, type FileChange, fileDir, type FileHistoryEntry, type FileInspect, fileName, type GraphEntry, type GraphRow, type HostAccount, type Identity, isMerge, isPending, isUncommittedLine, isWIP, type LineStat, type LoadingInfo, type LoadState, markdownLinks, markdownRefs, type Provider, providerInfo, type PullMode, type PullRequest, type RefLabel, refOrder, type RemoteRepo, type RepoState, repoStateTitle, type RepoTarget, type ResetMode, rowSelection, sameDiffSource, sameTarget, type SearchScope, searchScopes, type Selection, selectionID, type SheetKind, short, type Stash, statsClean, statusCount, statusFiles, statusIsEmpty, type Tag, WIP_ID, wipCommit, wipWorktree, type WorkingStatus, type Worktree, type WorktreeStats, worktreeStats, worktreeWIPCommit } from "./model/types";
export { RefBadge, StatusBadge } from "./ui/badges";
export { type PushReviewPlan, type PushConfig, parsePushConfig, displayPushURL, resolvePushDestination, pushConfigStamp, reviewedPushArguments } from "./lib/push-review";
export { type BatchCommitAction, type BatchCommitItem, type LineHistoryEntry, batchArguments, fullObjectID, lineHistoryRange, parseLineHistory, toggleGraphSelection, validRevisionInput, historyOperationInProgress } from "./lib/history-tools";
export { initialRepositoryFile, repositoryFolderCount, loadRepositoryTree, loadRepositoryBlob, safeRepositoryPath, parseRepositoryTree, repositoryImageMime, type RepositoryTreeEntry, type RepositoryTree, type RepositoryBlob } from "./lib/repository-browser";

export { defaultRebaseBase, loadRebasePreview, type RebasePreview } from "./lib/rebase-preview";

export type { ProjectTaskReference } from "./model/types";
