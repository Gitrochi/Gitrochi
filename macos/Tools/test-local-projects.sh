#!/usr/bin/env bash
# Use production JSON storage under an isolated temporary folder, never user planner data.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
cat > "$TASK_TMP/main.swift" <<'SWIFT'
import Foundation

enum Provider: String { case github, gitlab }
struct RepoTarget { var provider: Provider; var remote: String; var host: String; var path: String }
struct HostingError: LocalizedError { let status: Int; var errorDescription: String? { "HTTP \(status)" } }
enum Hosting {
    static func projectID(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics)! }
    static func request(_ provider: Provider, _ url: String, token: String, method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest { fatalError("Local planning must never request credentials or HTTP") }
    static func data(_ request: URLRequest) async throws -> Data { fatalError("Local planning must never send HTTP") }
}
actor FailingWriter: LocalProjectPersistence {
    let original: LocalProjectFileStorage
    init(_ original: LocalProjectFileStorage) { self.original = original }
    func read() async throws -> String? { try await original.read() }
    func write(expected: String?, content: String) throws { throw LocalProjectError.storage }
}
final class MemoryDefaults: UserDefaults {
    var values: [String: Data] = [:]
    override func data(forKey key: String) -> Data? { values[key] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value as? Data }
}

@main struct LocalProjectsTests {
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let preferences = MemoryDefaults()
        let localDefaults = ProjectSchedulePreferences.load(accountID: "", projectID: "local:plan", defaults: preferences)
        precondition(localDefaults == ProjectScheduleSettings(startFieldID: "local-start", dueFieldID: "local-due", statusFieldID: "local-status", completedOptionIDs: ["local-done"]))
        let explicit = ProjectScheduleSettings(startFieldID: "", dueFieldID: "", statusFieldID: "", completedOptionIDs: [])
        ProjectSchedulePreferences.save(explicit, accountID: "", projectID: "local:plan", defaults: preferences)
        precondition(ProjectSchedulePreferences.load(accountID: "different-account", projectID: "local:plan", defaults: preferences) == explicit)
        precondition(ProjectSchedulePreferences.load(accountID: "account", projectID: "REMOTE", defaults: preferences) == .init())
        let url = directory.appendingPathComponent("planner/projects.json")
        let storage = LocalProjectFileStorage(url: url), model = LocalProjectStore(storage: storage)
        let project = try await model.create(title: "  Release plan  ", description: "Local team schedule")
        precondition(LocalProjectStore.isLocal(project) && project.title == "Release plan")
        var detail = try await model.detail(projectID: project.id)
        detail = try await model.saveDraft(detail: detail, title: "Task one", body: "Implementation notes")
        detail = try await model.saveDraft(detail: detail, title: "Task two", body: "")
        let restarted = LocalProjectStore(storage: LocalProjectFileStorage(url: url))
        await restarted.load()
        precondition(restarted.projects.map(\.title) == ["Release plan"])
        let restored = try await restarted.detail(projectID: project.id)
        precondition(restored.rows.map(\.title) == ["Task one", "Task two"] && restored.rows[0].body == "Implementation notes")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber
        precondition(permissions.intValue == 0o600)
        func field(_ id: String) -> HubProjectField { detail.fields.first { $0.id == id }! }
        detail = try await model.updateField(detail: detail, row: detail.rows[0], field: field("local-start"), value: "2026-03-07")
        detail = try await model.updateField(detail: detail, row: detail.rows[0], field: field("local-due"), value: "2026-03-09")
        detail = try await model.updateField(detail: detail, row: detail.rows[0], field: field("local-priority"), value: "local-high")
        detail = try await model.updateField(detail: detail, row: detail.rows[0], field: field("local-assignees"), value: "alex, sam, ALEX")
        precondition(Set(detail.rows[0].assignees.map { $0.lowercased() }) == ["alex", "sam"])
        let beforeRangeRevision = model.revision
        detail = try await model.reschedule(detail: detail, row: detail.rows[0], settings: .init(), targetDay: "2026-11-02")
        precondition(detail.rows[0].values["local-start"] == "2026-10-31" && detail.rows[0].values["local-due"] == "2026-11-02" && model.revision == beforeRangeRevision + 1)
        detail = try await model.saveDraft(detail: detail, title: "Edited task", body: "After", row: detail.rows[0])
        detail = try await model.updateField(detail: detail, row: detail.rows[0], field: field("local-status"), value: "local-done")
        precondition(detail.rows[0].title == "Edited task" && detail.rows[0].body == "After" && detail.rows[0].state == "CLOSED")
        let translatedFields = detail.fields.map { HubProjectField(id: $0.id, name: "Localized field", options: $0.options, kind: $0.kind) }
        let scheduled = ProjectSchedule.entries(detail.rows, fields: translatedFields)
        precondition(scheduled[0].start == "2026-10-31" && scheduled[0].due == "2026-11-02" && scheduled[0].completed, "Fixed local fields must schedule correctly in every display language")

        let beforeInvalid = try await storage.read()
        do { _ = try await model.saveProject(detail: restored, title: "Stale overwrite", description: ""); preconditionFailure("Stale snapshot accepted") } catch {}
        do { _ = try await model.updateField(detail: detail, row: detail.rows[0], field: field("local-due"), value: "2026-02-30"); preconditionFailure("Invalid date accepted") } catch {}
        do { _ = try await model.updateField(detail: detail, row: detail.rows[0], field: field("local-due"), value: "2026-10-30"); preconditionFailure("Reversed range accepted") } catch {}
        var forged = detail; forged.item.id = "REMOTE"; forged.item.data = [:]
        do { _ = try await model.saveProject(detail: forged, title: "Remote", description: ""); preconditionFailure("Foreign project accepted") } catch {}
        let afterInvalid = try await storage.read()
        precondition(afterInvalid == beforeInvalid)

        let second = detail.rows[1].id, first = detail.rows[0].id
        detail = try await model.reorder(detail: detail, row: detail.rows[1], afterRow: nil)
        precondition(detail.rows.map(\.id) == [second, first])
        let bulkRevision = model.revision
        detail = try await model.updateFields(detail: detail, rows: detail.rows, field: field("local-status"), value: "local-done")
        precondition(model.revision == bulkRevision + 1 && detail.rows.allSatisfy { $0.state == "CLOSED" })
        detail = try await model.archiveMany(detail: detail, rows: detail.rows, archived: true)
        precondition(detail.rows.allSatisfy(\.archived))
        do { _ = try await model.saveDraft(detail: detail, title: "Forbidden edit", body: "", row: detail.rows[0]); preconditionFailure("Archived task edited") } catch {}
        detail = try await model.archiveMany(detail: detail, rows: detail.rows, archived: false)
        var foreignRow = detail.rows[0]; foreignRow.id = "foreign"
        let beforeBatch = try await storage.read()
        do { _ = try await model.updateFields(detail: detail, rows: detail.rows + [foreignRow], field: field("local-status"), value: "local-todo"); preconditionFailure("Partially saved invalid batch") } catch {}
        let afterBatch = try await storage.read()
        precondition(beforeBatch == afterBatch)

        let failing = LocalProjectStore(storage: FailingWriter(storage))
        await failing.load()
        let beforeFailure = try await storage.read()
        do { _ = try await failing.saveProject(detail: detail, title: "Unsaved", description: ""); preconditionFailure("Failed disk write reported success") } catch {}
        let afterFailure = try await storage.read()
        precondition(beforeFailure == afterFailure && failing.projects[0].title == "Release plan")
        do { try await storage.write(expected: nil, content: "{}"); preconditionFailure("Compare-and-swap accepted a stale file") } catch {}
        let afterCAS = try await storage.read()
        precondition(afterCAS == afterFailure)

        detail = try await model.removeMany(detail: detail, rows: detail.rows)
        precondition(detail.rows.isEmpty)
        try await model.deleteProject(detail: detail)
        precondition(model.projects.isEmpty)
        for invalid in ["invalid JSON", "{\"version\":2,\"revision\":0,\"projects\":[]}", "{\"version\":1,\"revision\":0,\"projects\":[{}]}"] {
            try Data(invalid.utf8).write(to: url, options: .atomic)
            do { _ = try await model.create(title: "Do not overwrite"); preconditionFailure("Corrupt data overwritten") } catch {}
            let preserved = try String(contentsOf: url, encoding: .utf8)
            precondition(preserved == invalid)
        }
        precondition(LocalProjectLimits.maxProjects == 1000 && LocalProjectLimits.maxTasksPerProject == 10_000 && LocalProjectLimits.maxBytes == 50_000_000)
        print("Local projects: account-free durable JSON, private permissions, task CRUD and fields, locale-safe dates, atomic schedule/bulk changes, reorder, stale/CAS guards and corruption/write-failure preservation passed")
    }
}
SWIFT
swiftc -parse-as-library -swift-version 5 "$ROOT/Sources/Services/HostingHub.swift" "$ROOT/Sources/Services/OrganizationManagement.swift" "$ROOT/Sources/Services/ProjectBackend.swift" "$ROOT/Sources/Core/ProjectSchedule.swift" "$ROOT/Sources/Core/ProjectSchedulePreferences.swift" "$ROOT/Sources/Core/LocalProjectDocument.swift" "$ROOT/Sources/Services/LocalProjectPersistence.swift" "$ROOT/Sources/Services/LocalProjects.swift" "$TASK_TMP/main.swift" -o "$TASK_TMP/test-local-projects"
"$TASK_TMP/test-local-projects" "$TASK_TMP"
