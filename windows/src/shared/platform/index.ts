// shared/platform 의 공개 API — 다른 조각은 이 파일로만 가져온다
export { describe, git, gitAvailable, gitBytes, type GitOptions, gitRaw, unsafeRepository } from "./git";
export { worktreeStamp } from "./work-stamp";
export { readOnlyGraphArguments } from "./readonly-graph";
export { type IndexSearchScope, repoIndex } from "./repo-index";
export { type ToolId, toolList, tools, wslCapable } from "./tools";
export { updater } from "./updater";
export { listDistros, tempFile, withWslEnv, wslArgs } from "./wsl";
