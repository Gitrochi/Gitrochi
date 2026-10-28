import SwiftUI

/// Local selection preview and editable task starters; selection never sends a question.
struct AssistantContextPanel: View {
    @Environment(RepoStore.self) private var store
    @ViewState private var promptID = ""
    @ViewState private var promptNotice = ""

    var body: some View {
        let state = store.repositoryAssistant
        if let context = state.context {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Analysis scope", selection: Binding(get: { context.scope }, set: { store.refreshRepositorySelection(scope: $0) })) {
                        Text("Working tree").tag("worktree")
                        Text("Staged changes").tag("staged")
                        Text("Commits").tag("commits")
                    }.frame(maxWidth: 230)
                    Button("Refresh selection context") { store.refreshRepositorySelection() }
                    Button("Load graph context") { Task { await store.loadRepositoryGraph() } }.disabled(state.reader == nil)
                    if state.graphLoading { ProgressView().controlSize(.small) }
                }.disabled(state.loading || state.working || state.graphLoading)
                Text(verbatim: selectionSummary(context)).font(.caption).foregroundStyle(.secondary)
                if store.repositoryContextStale { Text("The selection changed. Refresh selection context before sending.").font(.caption).foregroundStyle(.orange) }
                DisclosureGroup("Selection context") {
                    ScrollView { Text(context.json).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 100)
                }
                Picker("Task prompt", selection: $promptID) {
                    Text("Choose a task…").tag("")
                    ForEach(WorkPrompts.all) { prompt in Text(String(localized: String.LocalizationValue(prompt.title))).tag(prompt.id) }
                }.onChange(of: promptID) { _, value in promptNotice = ""; if !value.isEmpty { store.useRepositoryPrompt(value) } }.disabled(state.loading || state.working)
                if !promptID.isEmpty {
                    HStack {
                        Button("Use task prompt") { store.useRepositoryPrompt(promptID) }
                        Button("Save task prompt") { if store.saveRepositoryPrompt(promptID) { promptNotice = String(localized: "Task prompt saved for this repository.") } }.disabled(state.question.trimmed.isEmpty || store.repositoryContextStale)
                        Button("Reset task prompt") { if store.saveRepositoryPrompt(promptID, reset: true) { promptNotice = String(localized: "Default task prompt restored.") } }.disabled(store.repositoryContextStale)
                        if !promptNotice.isEmpty { Text(promptNotice).font(.caption).foregroundStyle(.secondary) }
                    }.disabled(state.loading || state.working || state.graphLoading)
                }
                if let graph = state.graphSnapshot {
                    Text(verbatim: graphSummary(graph)).font(.caption).foregroundStyle(.secondary)
                    Picker("Graph node", selection: Binding(get: { state.selectedNodeIDs.first ?? "" }, set: { state.selectedNodeIDs = $0.isEmpty ? [] : [$0]; store.refreshRepositorySelection() })) {
                        Text("No node selected").tag("")
                        ForEach(graph.nodeIDs, id: \.self) { Text($0).tag($0) }
                    }.disabled(state.working || state.graphLoading)
                    DisclosureGroup("Graph coverage and snapshot") {
                        ScrollView { Text(state.graphCoverage ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 100)
                    }
                }
                DisclosureGroup("Screen implementation map") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Maintained Gitrochi source links; these are not inferred dependencies.").font(.caption).foregroundStyle(.secondary)
                        if let entry = ScreenCodeMap.entry(for: context.screenID) {
                            ForEach(entry.macOS + entry.windows + entry.tests, id: \.self) { path in Button(path) { openSource(path) }.font(.system(.caption, design: .monospaced)).lineLimit(2) }
                        } else { Text("This screen has no maintained source mapping yet.").font(.caption).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func openSource(_ path: String) {
        guard WorkContext.safePath(path), let url = store.url, FileManager.default.fileExists(atPath: url.appendingPathComponent(path).path) else {
            store.repositoryAssistant.error = String(localized: "This implementation link is available when the Gitrochi source checkout is open."); return
        }
        store.openFileHistory(path)
    }

    private func selectionSummary(_ context: WorkContext) -> String {
        let screen = String(localized: "Screen") + ": " + context.screenID
        let paths = context.selectedPaths.isEmpty ? String(localized: "No files selected") : context.selectedPaths.joined(separator: ", ")
        return screen + " · " + String(localized: "Selected paths") + ": " + paths
    }

    private func graphSummary(_ graph: WorkGraphSnapshot) -> String {
        let count = String(localized: "Working file graph") + ": " + String(graph.nodeIDs.count)
        return count + " · " + String(localized: "Graph context is bounded. Omitted files and edges are not evidence of absence.")
    }
}
