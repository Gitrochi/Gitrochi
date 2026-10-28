export interface ScreenCodeEntry { screenID: string; title: string; macOS: string[]; windows: string[]; tests: string[] }
/** Explicit entry-point mapping; these are maintained links, not inferred dependencies. */
export const screenCodeMap: readonly ScreenCodeEntry[] = [
  { screenID: "repository", title: "Repository", macOS: ["macos/Sources/Views/RepoView.swift"], windows: ["windows/src/pages/repo/ui/RepositoryScreen.tsx"], tests: ["windows/src/app/lib/navigation-selftest.tsx"] },
  { screenID: "changes", title: "Changes", macOS: ["macos/Sources/Views/Inspector/CommitImpactView.swift", "macos/Sources/Store/RepoStore+CommitImpact.swift"], windows: ["windows/src/widgets/inspector/ui/CommitImpactPanel.tsx"], tests: ["windows/tests/commit-impact.test.ts"] },
  { screenID: "code", title: "Code", macOS: ["macos/Sources/Views/Workbench/RepositoryCodePanel.swift"], windows: ["windows/src/widgets/local-workbench/ui/RepositoryCodePanel.tsx"], tests: ["windows/src/app/lib/local-workbench-selftest.tsx"] },
  { screenID: "assistant", title: "Repository assistant", macOS: ["macos/Sources/Views/Sheets/RepositoryAssistantSheet.swift", "macos/Sources/Store/RepoStore+RepositoryAssistant.swift"], windows: ["windows/src/features/repository-assistant/ui/RepositoryAssistantSheet.tsx", "windows/src/entities/repo/model/layers/repository-assistant.ts"], tests: ["windows/tests/repository-assistant.test.ts"] },
  { screenID: "graph", title: "Structure graph", macOS: ["macos/Sources/Views/Shared/StructureGraphMenu.swift", "macos/Sources/Store/RepoStore+Gitch.swift"], windows: ["windows/src/entities/gitch/model/gitch.ts"], tests: ["tools/gitch/tests/graph_browser.mjs"] },
  { screenID: "workValidation", title: "Work validation", macOS: ["macos/Sources/Views/Sheets/WorkValidationSheet.swift", "macos/Sources/Store/FlowStore.swift"], windows: ["windows/src/features/work-validation/ui/WorkValidationSheet.tsx", "windows/src/entities/flow/model/store.ts"], tests: ["windows/tests/work-validation.test.ts", "macos/Tools/test-work-validation.sh"] },
];
export function screenCodeFor(screenID: string): ScreenCodeEntry | undefined { return screenCodeMap.find((entry) => entry.screenID === screenID); }
