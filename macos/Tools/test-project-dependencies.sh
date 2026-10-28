#!/usr/bin/env bash
# Predecessor edits use isolated memory persistence and never touch account or planner data.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/Tools/project-backend-test-sources.sh"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
cat > "$TASK_TMP/main.swift" <<'SWIFT'
import Foundation

enum Provider: String { case github, gitlab }
struct RepoTarget { var provider: Provider; var remote: String; var host: String; var path: String }
struct HostingError: LocalizedError { let status: Int; var errorDescription: String? { "HTTP \(status)" } }
enum Hosting {
    static func projectID(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics)! }
    static func request(_ provider: Provider, _ url: String, token: String, method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest { fatalError("Unexpected network") }
    static func data(_ request: URLRequest) async throws -> Data { fatalError("Unexpected network") }
}
actor MemoryPersistence: LocalProjectPersistence {
    var content: String?
    var writes = 0
    func read() -> String? { content }
    func write(expected: String?, content: String) throws { guard expected == self.content else { throw LocalProjectError.stale }; self.content = content; writes += 1 }
}
@main struct ProjectDependencyTests {
    @MainActor static func main() async throws {
        let storage = MemoryPersistence(), store = LocalProjectStore(storage: storage)
        let project = try await store.create(title: "Synthetic delivery plan")
        var detail = try await store.detail(projectID: project.id)
        for title in ["Design", "Implement", "Review"] { detail = try await store.saveDraft(detail: detail, title: title, body: "") }
        let older = try LocalPlannerDocument.decode(await storage.read())
        precondition(older.projects[0].tasks[0].predecessorIDs == nil)
        let stale = detail, beforeDates = detail.rows.map(\.values)
        detail = try await store.setDependencies(detail: detail, row: detail.rows[0], predecessorIDs: [], durationDays: 2)
        detail = try await store.setDependencies(detail: detail, row: detail.rows[1], predecessorIDs: [detail.rows[0].id], durationDays: 4)
        detail = try await store.setDependencies(detail: detail, row: detail.rows[2], predecessorIDs: [detail.rows[1].id], durationDays: 1)
        precondition(detail.rows.map(\.values) == beforeDates)
        var graph = LocalProjectDependencies.graph(detail.rows)
        precondition(graph.durationDays == 7 && graph.nodes.allSatisfy(\.critical) && graph.nodes[2].level == 2)
        precondition(graph.nodes[0].blockedBy.isEmpty && graph.nodes[1].blockedBy == [detail.rows[0].id])
        let before = await storage.read(), writes = await storage.writes
        for ids in [[detail.rows[0].id], [detail.rows[1].id], ["local-task:missing"], [detail.rows[2].id, detail.rows[2].id]] {
            do { _ = try await store.setDependencies(detail: detail, row: detail.rows[0], predecessorIDs: ids, durationDays: 2); preconditionFailure("Invalid dependency accepted") } catch {}
        }
        for duration in [0, -1, 3651] {
            do { _ = try await store.setDependencies(detail: detail, row: detail.rows[0], predecessorIDs: [], durationDays: duration); preconditionFailure("Invalid duration accepted") } catch {}
        }
        do { _ = try await store.setDependencies(detail: stale, row: stale.rows[0], predecessorIDs: [], durationDays: 1); preconditionFailure("Stale dependencies accepted") } catch {}
        do { _ = try await store.removeItem(detail: detail, row: detail.rows[0]); preconditionFailure("Dependent predecessor deleted") } catch {}
        let after = await storage.read(), afterWrites = await storage.writes
        precondition(before == after && writes == afterWrites)
        detail = try await store.archive(detail: detail, row: detail.rows[0], archived: true)
        graph = LocalProjectDependencies.graph(detail.rows)
        precondition(graph.durationDays == nil && graph.nodes[1].blockedBy == [detail.rows[0].id])
        do { _ = try await store.setDependencies(detail: detail, row: detail.rows[0], predecessorIDs: [], durationDays: 1); preconditionFailure("Archived predecessor edited") } catch {}
        detail = try await store.archive(detail: detail, row: detail.rows[0], archived: false)
        detail = try await store.updateField(detail: detail, row: detail.rows[0], field: detail.fields[0], value: "local-done")
        graph = LocalProjectDependencies.graph(detail.rows)
        precondition(graph.durationDays == 5 && graph.nodes[1].blockedBy.isEmpty)
        detail = try await store.saveDraft(detail: detail, title: "Implementation", body: "Preserve links", row: detail.rows[1])
        let reopened = try await LocalProjectStore(storage: storage).detail(projectID: project.id)
        precondition(reopened.rows[1].predecessorIDs == [detail.rows[0].id] && reopened.rows[1].durationDays == 4)
        let valid = try JSONSerialization.jsonObject(with: Data((await storage.read())!.utf8)) as! [String: Any]
        for patch in [["predecessorIDs": NSNull()], ["predecessorIDs": "text"], ["predecessorIDs": [detail.rows[0].id]], ["durationDays": NSNull()], ["durationDays": "5"], ["durationDays": 0]] as [[String: Any]] {
            var document = valid, projects = document["projects"] as! [[String: Any]], tasks = projects[0]["tasks"] as! [[String: Any]]
            for (key, value) in patch { tasks[0][key] = value }
            projects[0]["tasks"] = tasks; document["projects"] = projects
            let invalid = String(data: try JSONSerialization.data(withJSONObject: document), encoding: .utf8)!
            do { _ = try LocalPlannerDocument.decode(invalid); preconditionFailure("Corrupt predecessor document accepted") } catch {}
        }
        let chain = (0..<10_000).map { index in HubProjectRow(id: "task-\(index)", title: "Task", body: "", url: "", contentID: "", statuses: ["local-status": "local-todo"], predecessorIDs: index == 0 ? [] : ["task-\(index - 1)"], durationDays: 1) }
        let large = LocalProjectDependencies.graph(chain)
        precondition(large.nodes.count == 10_000 && large.nodes.last?.level == 9999 && large.durationDays == 10_000)
        detail = try await store.removeMany(detail: detail, rows: detail.rows)
        precondition(detail.rows.isEmpty)
        print("Project dependencies passed: older documents, atomic save, status readiness, explicit critical path, archive blockers, stale/self/missing/duplicate/cycle guards, deletion policy, corruption and 10,000-task chain")
    }
}
SWIFT
swiftc -parse-as-library -swift-version 5 "$ROOT/Sources/Services/HostingHub.swift" "${PROJECT_BACKEND_TEST_SOURCES[@]}" "$TASK_TMP/main.swift" -o "$TASK_TMP/test-project-dependencies"
"$TASK_TMP/test-project-dependencies"
