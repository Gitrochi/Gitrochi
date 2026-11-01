import Foundation
import Observation

/// Independent repository-file drafts use the engine's boundary checks and optimistic write contract.
@MainActor @Observable
final class FlowRelatedFileStore {
    let repo: URL
    private(set) var snapshot: FlowSourceResult?
    var text = ""
    private(set) var loading = false
    private(set) var saving = false
    var diagnostics: [FlowDesignDiagnostic] = []
    var error: String?
    private var generation = UUID()
    var active: Bool { snapshot != nil }
    var path: String { snapshot?.path ?? "" }
    var dirty: Bool { snapshot.map { !$0.exists || text != ($0.content ?? "") } ?? false }

    init(repo: URL) { self.repo = repo }

    func open(_ path: String, create: Bool = false) async {
        guard !saving else { return }
        let request = UUID(); generation = request
        loading = true; error = nil; diagnostics = []
        defer { if generation == request { loading = false } }
        do {
            let result = try await FlowEngine.readSource(path, in: repo)
            guard generation == request, !saving else { return }
            diagnostics = result.diagnostics
            let missing = result.diagnostics.contains { $0.code == "SOURCE_NOT_FOUND" || (create && $0.code == "SOURCE_PARENT_NOT_FOUND") }
            guard !result.hasErrors || (missing && create) else { return }
            if create, result.exists { error = String(localized: "The file already exists. Choose Open to edit it."); return }
            if result.exists, result.content == nil || result.fingerprint == nil { error = String(localized: "The source response is incomplete. Try opening the file again."); return }
            guard result.exists || create else { error = String(localized: "The file does not exist. Choose New file to create it."); return }
            snapshot = result
            text = result.content ?? ""
            if missing { diagnostics = [] }
        } catch { if generation == request { self.error = error.localizedDescription } }
    }

    func edit(_ value: String) { if !saving && !loading { text = value } }
    func close() { if !saving { generation = UUID(); snapshot = nil; text = ""; loading = false; diagnostics = []; error = nil } }

    func save() async -> Bool {
        guard let snapshot, !saving, !loading else { return false }
        saving = true; error = nil; diagnostics = []
        defer { saving = false }
        let value = text
        do {
            let result = try await FlowEngine.writeSource(snapshot.path, content: value, expected: snapshot.fingerprint, createParents: !snapshot.exists, in: repo)
            diagnostics = result.diagnostics
            guard result.saved, !result.hasErrors, result.content != nil else { return false }
            self.snapshot = result
            text = result.content ?? value
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
}
