// shared/lib 의 공개 API — 다른 조각은 이 파일로만 가져온다
export { drag } from "./drag";
export { laneColor, longDate, shortDate, stableHash, validBranchName } from "./format";
export { type MdBlock, type MdInline, type MdRefs, parseMarkdown } from "./markdown";
export { markdownImageURL } from "./markdown-inline";
export { Observable, useObserve } from "./observable";
export { shareHeights } from "./share-heights";
export { createWorkContext, sameWorkContext, workContextPath, workFingerprint, parseWorkGraphSnapshot, validateWorkGraphActions, type WorkContext, type WorkContextInput, type WorkScope, type WorkGraphSnapshot, type WorkGraphAction, type WorkGraphActions } from "./work-context";
export { workPrompts, renderWorkPrompt, workPromptTemplate, type WorkPrompt } from "./work-prompts";
export { screenCodeMap, screenCodeFor, type ScreenCodeEntry } from "./screen-code-map";
export { flowEvidence, safeWorkPath, decodeAgentAssignments, decodeValidationBindings, taskBoundaryOverlaps, handoffReport, type ValidationBinding, type FlowEvidence, type AgentAssignment } from "./work-validation";
export { teamHubEndpoint, teamRepoKey, decodeTeamSnapshot, readTeamSnapshot, type TeamSnapshot, type TeamOverlap, type TeamPresence } from "./team-hub";
