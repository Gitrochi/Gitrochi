#!/usr/bin/env bash
# Exercise column creation against memory-only persistence and exact synthetic GraphQL responses.
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
    static var requests: [URLRequest] = []
    static var handler: (URLRequest) throws -> Data = { _ in fatalError("Unexpected HTTP") }
    static func projectID(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics)! }
    static func request(_ provider: Provider, _ url: String, token: String, method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest {
        var request = URLRequest(url: URL(string: url)!); request.httpMethod = method
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }; return request
    }
    static func data(_ request: URLRequest) async throws -> Data { requests.append(request); return try handler(request) }
}
actor MemoryPersistence: LocalProjectPersistence {
    var content: String?
    var reads = 0, writes = 0
    func read() -> String? { reads += 1; return content }
    func write(expected: String?, content: String) throws { guard expected == self.content else { throw LocalProjectError.stale }; self.content = content; writes += 1 }
}
@main struct ProjectTaskCreationTests {
    @MainActor static func main() async throws {
        typealias J = [String: Any]
        func json(_ value: J) throws -> Data { try JSONSerialization.data(withJSONObject: ["data": value]) }
        func payload(_ request: URLRequest) throws -> J { try JSONSerialization.jsonObject(with: request.httpBody!) as! J }
        func input(_ request: URLRequest) throws -> J { (try payload(request)["variables"] as! J)["input"] as! J }
        precondition(HostingHubAPI.projectDetailQuery.contains("createdAt author{login}") && HostingHubAPI.projectDetailQuery.contains("createdAt creator{login}"))
        let issueMetadata = HostingHubAPI.projectRow(["id": "ISSUE", "content": ["__typename": "Issue", "id": "I", "title": "Issue", "author": ["login": "issue-writer"], "createdAt": "2026-10-01T12:00:00Z"]])
        let draftMetadata = HostingHubAPI.projectRow(["id": "DRAFT", "content": ["__typename": "DraftIssue", "id": "D", "title": "Draft", "creator": ["login": "draft-writer"], "createdAt": "2026-10-02T13:00:00Z"]])
        let hiddenMetadata = HostingHubAPI.projectRow(["id": "HIDDEN"])
        precondition(issueMetadata.author == "issue-writer" && issueMetadata.createdAt == "2026-10-01T12:00:00Z")
        precondition(draftMetadata.author == "draft-writer" && draftMetadata.createdAt == "2026-10-02T13:00:00Z")
        precondition(hiddenMetadata.author == nil && hiddenMetadata.createdAt == nil)
        let memory = MemoryPersistence(), store = LocalProjectStore(storage: memory)
        HostingHubAPI.localProjectStore = store
        let local = HubAccess(target: RepoTarget(provider: .github, remote: "origin", host: "local", path: "local/workspace"), token: "", apiBase: "", me: "", local: true)
        let project = try await store.create(title: "Synthetic plan")
        var detail = try await store.detail(projectID: project.id)
        let stale = detail
        var writes = await memory.writes
        try await HostingHubAPI.createProjectTask(local, detail: detail, title: "In progress", body: "Notes", field: detail.fields[0], option: "local-progress")
        var actualWrites = await memory.writes
        precondition(actualWrites == writes + 1)
        detail = try await store.detail(projectID: project.id)
        precondition(detail.rows[0].statuses["local-status"] == "local-progress" && detail.rows[0].statuses["local-priority"] == "local-normal")
        writes = await memory.writes
        try await HostingHubAPI.createProjectTask(local, detail: detail, title: "Urgent", field: detail.fields.first { $0.id == "local-priority" }, option: "local-urgent")
        actualWrites = await memory.writes
        precondition(actualWrites == writes + 1)
        detail = try await store.detail(projectID: project.id)
        precondition(detail.rows[1].values["local-priority"] == "local-urgent" && detail.rows[1].values["local-status"] == "local-todo")
        let before = await memory.content, reads = await memory.reads
        writes = await memory.writes
        do { try await HostingHubAPI.createProjectTask(local, detail: detail, title: "Invalid", field: detail.fields[0], option: "forged"); fatalError("Invalid column created") } catch {}
        do { try await HostingHubAPI.createProjectTask(local, detail: detail, title: "Unset", field: detail.fields[0]); fatalError("Required status cleared") } catch {}
        do { try await HostingHubAPI.createProjectTask(local, detail: detail, title: "No field", option: "local-progress"); fatalError("Option without field accepted") } catch {}
        let afterReads = await memory.reads
        precondition(afterReads == reads, "Invalid columns must fail before the transaction reads storage")
        do { try await HostingHubAPI.createProjectTask(local, detail: stale, title: "Stale", field: stale.fields[0], option: "local-progress"); fatalError("Stale project created a task") } catch {}
        let after = await memory.content
        actualWrites = await memory.writes
        precondition(before == after && actualWrites == writes && Hosting.requests.isEmpty)

        let c = HubAccess(target: RepoTarget(provider: .github, remote: "origin", host: "github.com", path: "team/client"), token: "fixture-token", apiBase: "https://api.github.com", me: "reader")
        let field = HubProjectField(id: "STATUS", name: "Status", options: [HubProjectOption(id: "ACTIVE", name: "In progress")])
        let remote = HubDetail(item: HubItem(id: "PROJECT", title: "Delivery"), fields: [field], rows: [HubProjectRow(id: "OLDER", title: "Same title", body: "", url: "", contentID: "OLD-DRAFT", statuses: [:], kind: .draft)])
        let created: J = ["addProjectV2DraftIssue": ["projectItem": ["id": "NEW-EXACT"]]]
        Hosting.handler = { request in
            precondition(request.url!.absoluteString == "https://api.github.com/graphql")
            return try json((try payload(request)["query"] as! String).contains("addProjectV2DraftIssue") ? created : ["updateProjectV2ItemFieldValue": ["projectV2Item": ["id": "NEW-EXACT"]]])
        }
        try await HostingHubAPI.createProjectTask(c, detail: remote, title: "  Same title  ", body: "Body", field: field, option: "ACTIVE")
        precondition(Hosting.requests.count == 2 && (try! input(Hosting.requests[0])["title"] as! String) == "Same title")
        let assignment = try input(Hosting.requests[1])
        precondition(assignment["projectId"] as? String == "PROJECT" && assignment["itemId"] as? String == "NEW-EXACT" && assignment["fieldId"] as? String == "STATUS" && (assignment["value"] as? J)?["singleSelectOptionId"] as? String == "ACTIVE")
        Hosting.requests = []
        Hosting.handler = { request in try json((try payload(request)["query"] as! String).contains("addProjectV2DraftIssue") ? created : ["clearProjectV2ItemFieldValue": ["projectV2Item": ["id": "NEW-EXACT"]]]) }
        try await HostingHubAPI.createProjectTask(c, detail: remote, title: "Unset", field: field)
        precondition(Hosting.requests.count == 2 && (try! payload(Hosting.requests[1])["query"] as! String).contains("ClearProjectV2ItemFieldValueInput"))
        Hosting.requests = []
        try await HostingHubAPI.createProjectTask(c, detail: remote, title: "Default")
        precondition(Hosting.requests.count == 1)
        Hosting.requests = []
        var invalid = field; invalid.id = "FOREIGN"
        do { try await HostingHubAPI.createProjectTask(c, detail: remote, title: "Invalid field", field: invalid, option: "ACTIVE"); fatalError("Unknown field accepted") } catch {}
        do { try await HostingHubAPI.createProjectTask(c, detail: remote, title: "Invalid option", field: field, option: "MISSING"); fatalError("Unknown option accepted") } catch {}
        var staleAccess = c; staleAccess.isCurrent = { false }
        do { try await HostingHubAPI.createProjectTask(staleAccess, detail: remote, title: "Stale", field: field, option: "ACTIVE"); fatalError("Stale context accepted") } catch {}
        do { try await HostingHubAPI.createProjectTask(local, detail: remote, title: "Crossed", field: field, option: "ACTIVE"); fatalError("Crossed namespace accepted") } catch {}
        var wrongKind = remote; wrongKind.fields[0].kind = .iteration
        do { try await HostingHubAPI.createProjectTask(c, detail: wrongKind, title: "Wrong kind", field: field, option: "ACTIVE"); fatalError("Non-select field accepted") } catch {}
        precondition(Hosting.requests.isEmpty)
        for failure in ["network", "permission", "wrong-item"] {
            Hosting.handler = { request in
                if (try payload(request)["query"] as! String).contains("addProjectV2DraftIssue") { return try json(created) }
                if failure == "network" { throw HostingHubAPI.fail("Assignment disconnected") }
                if failure == "permission" { throw HubProjectActionDeniedError() }
                return try json(["updateProjectV2ItemFieldValue": ["projectV2Item": ["id": "OTHER"]]])
            }
            do { try await HostingHubAPI.createProjectTask(c, detail: remote, title: "Same title", field: field, option: "ACTIVE"); fatalError("Unconfirmed column reported success") }
            catch let error as HubUncertainWriteError { precondition(error.message.contains("Refresh the project before trying again")) }
            precondition(Hosting.requests.count == 2, "An uncertain create must never retry or delete")
            Hosting.requests = []
        }
        Hosting.handler = { _ in throw HubProjectActionDeniedError() }
        do { try await HostingHubAPI.createProjectTask(c, detail: remote, title: "Denied", field: field, option: "ACTIVE"); fatalError("Denied creation accepted") } catch is HubProjectActionDeniedError {}
        precondition(Hosting.requests.count == 1); Hosting.requests = []
        Hosting.handler = { _ in try json(["addProjectV2DraftIssue": ["projectItem": [:]]]) }
        do { try await HostingHubAPI.createProjectTask(c, detail: remote, title: "Missing ID", field: field, option: "ACTIVE"); fatalError("Missing created ID accepted") } catch is HubUncertainWriteError {}
        precondition(Hosting.requests.count == 1); Hosting.requests = []
        var current = true, changed = c; changed.isCurrent = { current }
        Hosting.handler = { _ in current = false; return try json(created) }
        do { try await HostingHubAPI.createProjectTask(changed, detail: remote, title: "Changed context", field: field, option: "ACTIVE"); fatalError("Changed context accepted") } catch is HubUncertainWriteError {}
        precondition(Hosting.requests.count == 1)
        print("Project task creation passed: atomic local columns, stale/field guards, exact remote item IDs, unset/default columns and uncertain partial writes without retries")
    }
}
SWIFT
swiftc -parse-as-library -swift-version 5 "$ROOT/Sources/Services/HostingHub.swift" "${PROJECT_BACKEND_TEST_SOURCES[@]}" "$ROOT/Sources/Services/ProjectTaskCreation.swift" "$TASK_TMP/main.swift" -o "$TASK_TMP/test-project-task-creation"
"$TASK_TMP/test-project-task-creation"
