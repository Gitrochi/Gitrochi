import SwiftUI

struct AgentHandoffPanel: View {
    let store: RepoStore
    let stamp: String
    let evidence: [WorkFlowEvidence]
    @ViewState private var assignments: [WorkAgentAssignment] = []
    @ViewState private var report = ""
    @ViewState private var pathError = ""
    @ViewState private var pathDrafts: [String: String] = [:]
    private var invalidPaths: Bool { pathDrafts.values.contains { !$0.split(separator: "\n").map(String.init).allSatisfy(WorkValidation.safePath) } }
    private var center: AgentCenter { .shared }
    private var key: String { "agentAssignments:" + (store.url?.path ?? "") }
    private var sessions: [AgentSession] { center.sessions.filter { session in session.path == store.url?.path || store.worktrees.contains { $0.path == session.path } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agent handoff").font(.headline)
            Text("Declare task boundaries explicitly. Shared paths do not prove which agent edited a file.").font(.caption).foregroundStyle(.secondary)
            ForEach(sessions) { session in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Observed at \(ISO8601DateFormatter().string(from: session.updated))").font(.caption).foregroundStyle(.secondary)
                        TextField("Task ID", text: binding(session.id, \.taskID)).textFieldStyle(.roundedBorder)
                        TextField("Task goal", text: binding(session.id, \.goal)).textFieldStyle(.roundedBorder)
                        Text("Task boundaries · relative paths, one per line").font(.caption)
                        TextEditor(text: Binding(get: { pathDrafts[session.id] ?? value(session.id).paths.joined(separator: "\n") }, set: { text in
                            pathDrafts[session.id] = text; report = ""
                            let paths = text.split(separator: "\n").map(String.init)
                            if paths.allSatisfy(WorkValidation.safePath) { update(session.id) { $0.paths = paths }; pathError = "" }
                            else { pathError = String(localized: "Use repository-relative paths without parent traversal.") }
                        })).font(.body.monospaced()).frame(minHeight: 65).accessibilityLabel("Task boundaries · relative paths, one per line")
                        TextField("Remaining work", text: binding(session.id, \.remaining)).textFieldStyle(.roundedBorder)
                    }.padding(.vertical, 6)
                } label: { HStack { Text(session.kind.title); Text(session.status.title).foregroundStyle(.secondary); Text(value(session.id).taskID.isEmpty ? session.id : value(session.id).taskID).font(.caption.monospaced()) } }
            }
            if sessions.isEmpty { Text("No tracked agent sessions are available for this repository.").foregroundStyle(.secondary) }
            let active = Set(sessions.filter { $0.status != .ended }.map(\.id))
            let overlaps = WorkValidation.overlaps(assignments.filter { active.contains($0.sessionID) })
            if !overlaps.isEmpty {
                Text("Overlapping task boundaries").fontWeight(.medium)
                ForEach(overlaps, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
            }
            if !pathError.isEmpty { Text(pathError).foregroundStyle(.red) }
            Button("Create handoff report") {
                let candidates: [String]
                if case .ready(let result, _) = store.commitImpactState { candidates = result.tests.map(\.path) } else { candidates = [] }
                let observations = sessions.map { session in WorkAgentObservation(taskID: value(session.id).taskID, kind: session.kind.rawValue, state: session.status.rawValue, branch: store.worktrees.first { $0.path == session.path }?.branch ?? store.headBranch, observedAt: ISO8601DateFormatter().string(from: session.updated)) }
                report = WorkValidation.handoff(head: store.headHash, stamp: stamp, appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown", changedPaths: store.status.files.map(\.path), candidates: candidates, evidence: evidence, assignments: assignments, sessions: observations)
            }.disabled(stamp.isEmpty || invalidPaths)
            if !report.isEmpty {
                Text("Review task text before sharing this report.").font(.caption).foregroundStyle(.secondary)
                Text(report).font(.caption.monospaced()).textSelection(.enabled)
            }
        }.task(id: key) {
            assignments = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([WorkAgentAssignment].self, from: $0) } ?? []
        }
    }

    private func value(_ id: String) -> WorkAgentAssignment { assignments.first { $0.sessionID == id } ?? WorkAgentAssignment(sessionID: id) }
    private func binding(_ id: String, _ field: WritableKeyPath<WorkAgentAssignment, String>) -> Binding<String> { Binding(get: { value(id)[keyPath: field] }, set: { text in update(id) { $0[keyPath: field] = String(text.prefix(4000)) } }) }
    private func update(_ id: String, change: (inout WorkAgentAssignment) -> Void) {
        var assignment = value(id); change(&assignment)
        assignments = Array(assignments.filter { $0.sessionID != id }.suffix(199)) + [assignment]
        if let data = try? JSONEncoder().encode(assignments) { UserDefaults.standard.set(data, forKey: key) }
        report = ""
    }
}
