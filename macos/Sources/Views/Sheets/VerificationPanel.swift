import SwiftUI

struct VerificationPanel: View {
    let store: RepoStore
    let flows: FlowStore
    @Binding var stamp: String
    @Binding var evidence: [WorkFlowEvidence]
    @ViewState private var flow = ""
    @ViewState private var working = false
    @ViewState private var error = ""

    private var candidates: [String] {
        if case .ready(let report, _) = store.commitImpactState { return report.tests.map(\.path) }
        return []
    }
    private var contentKey: String { (store.headHash ?? "") + ":" + String(store.workContentRevision) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Verification evidence").font(.headline)
            Text("Candidates are suggestions. Flow results report actual execution; they do not prove candidate coverage.").font(.caption).foregroundStyle(.secondary)
            if !candidates.isEmpty { DisclosureGroup("Related test candidates") { ForEach(candidates, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) } } }
            else { Text("Analyze staged files to find related test candidates.").font(.caption).foregroundStyle(.secondary) }
            Text("Verification runs the configured flow against the working tree, including unstaged edits.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Picker("Flow", selection: $flow) { Text("Choose a flow").tag(""); ForEach(flows.list?.flows ?? []) { Text($0.name).tag($0.name) } }.frame(maxWidth: 280)
                Button("Run verification flow") { Task { await run() } }.disabled(flow.isEmpty || working || flows.list?.trusted != true)
                Button("Review flows") { store.sheet = nil; store.navigate(.flows) }
                Button("Refresh") { Task { await refresh() } }.disabled(working)
                if working || flows.loading { ProgressView().controlSize(.small) }
            }
            if !flows.hasFlowFile { Text("Set up flows in the Flows workspace to connect your tests.").font(.caption).foregroundStyle(.secondary) }
            if stamp.hasPrefix("untracked:") { Text("Untracked file contents are not bound to verification. Add them to Git before relying on a current result.").font(.caption).foregroundStyle(.secondary) }
            if stamp.hasPrefix("uncertified:") { Text("Hidden tracked files or dirty submodules prevent content verification.").font(.caption).foregroundStyle(.secondary) }
            ForEach(evidence) { item in
                VStack(alignment: .leading, spacing: 3) {
                    HStack { Text(item.runID).font(.caption.monospaced()).textSelection(.enabled); Text(item.state).fontWeight(.medium); Text(freshness(item.freshness)) }
                    if let executed = item.executed {
                        HStack { Text("Executed tests: \(executed)"); if let passed = item.passed { Text("Passed tests: \(passed)") }; if let failed = item.failed { Text("Failed tests: \(failed)") } }.font(.caption)
                    }
                    else { Text("No test execution count was reported.").font(.caption).foregroundStyle(.secondary) }
                }.accessibilityElement(children: .combine)
            }
            if evidence.isEmpty { Text("No verification runs have been recorded.").foregroundStyle(.secondary) }
            if !error.isEmpty { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
        .task(id: contentKey) {
            stamp = ""
            evidence = evidence.map { WorkFlowEvidence(runID: $0.runID, state: $0.state, freshness: $0.freshness == "running" ? "running" : "stale", executed: $0.executed, passed: $0.passed, failed: $0.failed) }
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(flows.runs.contains { $0.running == true } ? 3 : 30))
            }
        }
    }

    private func freshness(_ value: String) -> String {
        switch value {
        case "current": return String(localized: "Current content")
        case "stale": return String(localized: "Stale content")
        case "running": return String(localized: "Running")
        default: return String(localized: "No content binding")
        }
    }

    private func refresh() async {
        await flows.refresh()
        for row in flows.runs.prefix(12) { await flows.open(row.runId) }
        do {
            let current = try await WorkStamp.read(in: flows.repo)
            guard !Task.isCancelled, store.url == flows.repo else { return }
            stamp = current.stamp
            evidence = flows.runs.prefix(12).compactMap { row in flows.record(row.runId).map { WorkFlowEvidence.read($0, binding: flows.validationBindings.first { $0.runID == row.runId }, currentStamp: current.stamp) } }
            error = ""
        } catch { if !Task.isCancelled { self.error = store.describe(error) } }
    }

    private func run() async {
        working = true; error = ""
        defer { working = false }
        do { _ = try await flows.startVerified(flow, candidates: candidates); await refresh() }
        catch { self.error = store.describe(error) }
    }
}
