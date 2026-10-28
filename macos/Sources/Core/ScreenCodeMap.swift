import Foundation

struct ScreenCodeEntry: Identifiable {
    let screenID: String
    let title: String
    let macOS: [String]
    let windows: [String]
    let tests: [String]
    var id: String { screenID }
}

/// Maintained entry-point links, rather than inferred source dependencies.
enum ScreenCodeMap {
    static let entries = [
        ScreenCodeEntry(screenID: "repository", title: "Repository", macOS: ["macos/Sources/Views/RepoView.swift"], windows: ["windows/src/pages/repo/ui/RepositoryScreen.tsx"], tests: ["windows/src/app/lib/navigation-selftest.tsx"]),
        ScreenCodeEntry(screenID: "changes", title: "Changes", macOS: ["macos/Sources/Views/Inspector/CommitImpactView.swift", "macos/Sources/Store/RepoStore+CommitImpact.swift"], windows: ["windows/src/widgets/inspector/ui/CommitImpactPanel.tsx"], tests: ["windows/tests/commit-impact.test.ts"]),
        ScreenCodeEntry(screenID: "code", title: "Code", macOS: ["macos/Sources/Views/Graph/FileInspectView.swift"], windows: ["windows/src/widgets/local-workbench/ui/LocalWorkbench.tsx"], tests: ["windows/src/app/lib/local-workbench-selftest.tsx"]),
        ScreenCodeEntry(screenID: "assistant", title: "Repository assistant", macOS: ["macos/Sources/Views/Sheets/RepositoryAssistantSheet.swift", "macos/Sources/Store/RepoStore+RepositoryAssistant.swift"], windows: ["windows/src/features/repository-assistant/ui/RepositoryAssistantSheet.tsx", "windows/src/entities/repo/model/layers/repository-assistant.ts"], tests: ["windows/tests/repository-assistant.test.ts"]),
        ScreenCodeEntry(screenID: "graph", title: "Structure graph", macOS: ["macos/Sources/Views/Shared/StructureGraphMenu.swift", "macos/Sources/Store/RepoStore+Gitch.swift"], windows: ["windows/src/entities/gitch/model/gitch.ts"], tests: ["tools/gitch/tests/graph_browser.mjs"]),
        ScreenCodeEntry(screenID: "workValidation", title: "Work validation", macOS: ["macos/Sources/Views/Sheets/WorkValidationSheet.swift", "macos/Sources/Store/FlowStore.swift"], windows: ["windows/src/features/work-validation/ui/WorkValidationSheet.tsx", "windows/src/entities/flow/model/store.ts"], tests: ["windows/tests/work-validation.test.ts", "macos/Tools/test-work-validation.sh"])
    ]
    static func entry(for screenID: String) -> ScreenCodeEntry? { entries.first { $0.screenID == screenID } }
}
