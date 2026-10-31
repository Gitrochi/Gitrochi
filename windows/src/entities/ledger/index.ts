// The public API of entities/ledger: other slices import only from this file
export { type LedgerBackend, LedgerError, ledgerFailure, ledgerResult, nativeCanRun, nativeLedgerBackend } from "./api/backend";
export { DemoLedgerBackend, type DemoOptions } from "./api/demo-backend";
export { type AnswerKind, countdown, type Countdown, type CountdownTone, describeAnswer, promptActions, promptChoice, type PromptOption, promptOptions, promptSummary, serverNow, waitingPrompts } from "./lib/countdown";
export { emptyFilter, filterSessions, foldText, matchesText, projectForRepository, type SessionFilter, streamCount, verdictCounts } from "./lib/filter";
export { GRAPH_LANE_W, GRAPH_LEFT_PAD, GRAPH_ROW_H, type GraphPlot, laneX, pathsInBand, type PlacedNode, type PlacedPath, plotLedgerGraph, rowY, visibleRows } from "./lib/graph";
export { countReports, type ImportLine, type ImportOutcome, type ImportSummary, summarizeImport } from "./lib/imports";
export { type InboxAction, type InboxGroup, type InboxGroupId, inboxCount, type InboxItem, inboxGroups, inboxItems, inboxKeyAction, stepIndex } from "./lib/inbox";
export { LEDGER_NARROW, LEDGER_WIDE, type LedgerLayout, ledgerLayout } from "./lib/layout";
export { inverseOperation, operationTitle } from "./lib/undo";
export { compareSessions, computeVerdict, isFinished, STALE_HOURS, type VerdictIcon, type VerdictLook, verdictDisplayOrder, verdictLook } from "./lib/verdict";
export { compareVersions } from "./lib/version";
export { LEDGER_POLL_MS, type LedgerToast, type LedgerView, ledgerViews } from "./model/reader";
export { LedgerStore, ledgerStore } from "./model/store";
export { type LedgerActor, type LedgerAttention, type LedgerBackupResult, type LedgerBaseline, type LedgerBaselineSource, ledgerBaselineSources, type LedgerEvent, type LedgerGraph, type LedgerGraphEdge, type LedgerGraphNode, type LedgerGraphTail, type LedgerHumanAction, type LedgerHumanArgs, type LedgerHumanRequest, type LedgerImportResult, type LedgerInfo, type LedgerKindRule, type LedgerLegacyImport, type LedgerMethod, type LedgerMethods, type LedgerOverlap, type LedgerPendingPrompt, type LedgerProject, type LedgerProjectChange, type LedgerProjectSettings, type LedgerPromptAnswer, type LedgerPromptKind, type LedgerQuestion, type LedgerRange, ledgerRanges, type LedgerRole, ledgerRoles, type LedgerScanResult, type LedgerSearchHit, type LedgerSearchKind, type LedgerSession, type LedgerSessionDetail, type LedgerSettings, type LedgerState, type LedgerStatus, ledgerStatuses, type LedgerStreamCycle, type LedgerVerdict, ledgerVerdicts, type Ms } from "./model/types";
