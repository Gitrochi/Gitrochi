// The public API of entities/flow: other slices import only from this file
export { FlowEngineError, flowEngine } from "./model/engine";
export { applyEvent, consumeEvents, formatDuration, type FlowNodeState, isBadState, newRunView, runCounts, type RunNode, type RunStep, type RunView, TAIL_LIMIT } from "./model/run-view";
export { FlowStore, flowStoreFor } from "./model/store";
export { recordIsRunning, recoverRunHistory, runPresentationState, runRowPresentationState } from "./model/history";
export { fitFlowGraph, flowZoomAnchor, layoutFlowGraph } from "./model/graph";
export { flowConfigFiles, readFlowImport, readWebFlowImport, saveFlowConfig, scriptFlowExample, type FlowAttachment, type FlowImportSource } from "./model/config";
export { type FlowBlock, type FlowDesignDiagnostic, type FlowDesignInspection, type FlowDesignRender, type FlowDocument, type FlowInputSchema, type FlowModule, addDesignModule, canDesignDependOn, checkedDesignYaml, composeDesignProposal, designFlowNames, designModules, flowObject, importedDesignModules, importedFlowName, removeDesignModule, updateDesignInput, updateDesignModule } from "./model/design";
export { browseFlowConnection, connectionProblem, listFlowConnections, saveFlowConnection, testFlowConnection, type FlowConnection, type FlowRemoteBrowse } from "./model/connections";
export { type FlowDetached, type FlowEvent, type FlowGate, type FlowInitProposal, type FlowItem, type FlowList, type FlowPlan, type FlowPlanNode, type FlowRunRow, needsConfirmation, parseEngineError } from "./model/types";
