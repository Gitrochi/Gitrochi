#!/usr/bin/env bash
# Exercise production schedule writes against fake HTTP, never a real account or project.
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
    static var handler: (URLRequest) throws -> Data = { _ in fatalError("Unexpected HTTP") }
    static func projectID(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics)! }
    static func request(_ provider: Provider, _ url: String, token: String, method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest {
        var request = URLRequest(url: URL(string: url)!); request.httpMethod = method
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }; return request
    }
    static func data(_ request: URLRequest) async throws -> Data { try handler(request) }
}

@main struct ProjectSchedulingTests {
    @MainActor static func main() async throws {
        typealias J = [String: Any]
        func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: ["data": value]) }
        func requestBody(_ request: URLRequest) throws -> J { try JSONSerialization.jsonObject(with: request.httpBody!) as! J }
        func input(_ request: URLRequest) throws -> J { (try requestBody(request)["variables"] as! J)["input"] as! J }
        func query(_ request: URLRequest) throws -> String { try requestBody(request)["query"] as! String }
        func row(_ values: [String: String] = ["start": "2026-10-27", "due": "2026-10-29"], id: String = "ROW", kind: HubProjectRowKind = .issue, archived: Bool = false) -> HubProjectRow {
            HubProjectRow(id: id, title: "Task", body: "", url: "https://github.com/team/client/issues/1", contentID: "ISSUE", statuses: [:], kind: kind, archived: archived, values: values)
        }
        func detail(_ task: HubProjectRow) -> HubDetail { HubDetail(item: HubItem(id: "PROJECT", title: "Delivery"), fields: [HubProjectField(id: "start", name: "Start date", options: [], kind: .date), HubProjectField(id: "due", name: "Due date", options: [], kind: .date)], rows: [task]) }
        func fresh(_ values: [String: String] = ["start": "2026-10-27", "due": "2026-10-29"]) -> J { ["id": "ROW", "isArchived": false, "project": ["id": "PROJECT"], "fieldValues": ["nodes": values.sorted { $0.key < $1.key }.map { ["date": $0.value, "field": ["id": $0.key]] as J }, "pageInfo": ["hasNextPage": false]]] }
        let access = HubAccess(target: RepoTarget(provider: .github, remote: "origin", host: "github.com", path: "team/client"), token: "fixture-credential", apiBase: "https://api.github.com", me: "reviewer")
        let settings = ProjectScheduleSettings()
        var calls: [URLRequest] = []
        Hosting.handler = { request in
            precondition(request.url!.absoluteString == "https://api.github.com/graphql")
            calls.append(request)
            return try json(try query(request).hasPrefix("query") ? ["node": fresh()] : ["updateProjectV2ItemFieldValue": ["projectV2Item": ["id": "ROW"]]])
        }
        try await HostingHubAPI.rescheduleProjectItem(access, detail: detail(row()), row: row(), settings: settings, targetDay: "2026-11-02")
        precondition(calls.count == 3)
        let first = try input(calls[1]), second = try input(calls[2])
        precondition(first["fieldId"] as? String == "start" && (first["value"] as? J)?["date"] as? String == "2026-10-31")
        precondition(second["fieldId"] as? String == "due" && (second["value"] as? J)?["date"] as? String == "2026-11-02")
        precondition(first["projectId"] as? String == "PROJECT" && second["itemId"] as? String == "ROW")
        calls = []
        try await HostingHubAPI.rescheduleProjectItem(access, detail: detail(row()), row: row(["due": "2030-01-01"]), settings: settings, targetDay: "2026-10-29")
        precondition(calls.isEmpty, "No-op edits must not request or mutate anything, and caller values must not replace loaded values")

        for task in [row(["due": "2026-02-30"]), row(["start": "2026-10-30", "due": "2026-10-27"]), row([:], archived: true), row([:], kind: .redacted)] {
            do { try await HostingHubAPI.rescheduleProjectItem(access, detail: detail(task), row: task, settings: settings, targetDay: "2026-11-02"); preconditionFailure("Invalid task accepted") } catch {}
        }
        do { try await HostingHubAPI.rescheduleProjectItem(access, detail: detail(row()), row: row(id: "FOREIGN"), settings: settings, targetDay: "2026-11-02"); preconditionFailure() } catch {}
        let foreign = HubAccess(target: RepoTarget(provider: .gitlab, remote: "origin", host: "gitlab.example.com", path: "team/client"), token: access.token, apiBase: access.apiBase, me: access.me)
        do { try await HostingHubAPI.rescheduleProjectItem(foreign, detail: detail(row()), row: row(), settings: settings, targetDay: "2026-11-02"); preconditionFailure() } catch {}
        let stale = HubAccess(target: access.target, token: access.token, apiBase: access.apiBase, me: access.me, isCurrent: { false })
        do { try await HostingHubAPI.rescheduleProjectItem(stale, detail: detail(row()), row: row(), settings: settings, targetDay: "2026-11-02"); preconditionFailure() } catch {}
        do { try await HostingHubAPI.rescheduleProjectItem(access, detail: detail(row()), row: row(), settings: settings, targetDay: "2026-02-30"); preconditionFailure() } catch {}
        precondition(calls.isEmpty, "Invalid, foreign and stale tasks must fail before HTTP")

        Hosting.handler = { request in calls.append(request); return try json(["node": fresh(["start": "2026-11-10"])]) }
        let startOnly = row(["start": "2026-10-27"])
        do { try await HostingHubAPI.rescheduleProjectItem(access, detail: detail(startOnly), row: startOnly, settings: settings, targetDay: "2026-11-02"); preconditionFailure("Concurrent unchanged start was overwritten") }
        catch { precondition(error.localizedDescription.contains("changed on the server")) }
        precondition(calls.count == 1, "All schedule fields must be compared before the first mutation")

        var wrongProject = fresh(); wrongProject["project"] = ["id": "OTHER"]
        var archived = fresh(); archived["isArchived"] = true
        var incomplete = fresh(); var connection = incomplete["fieldValues"] as! J; connection["pageInfo"] = ["hasNextPage": true]; incomplete["fieldValues"] = connection
        var missingArchive = fresh(); missingArchive["isArchived"] = nil
        var missingPage = fresh(); connection = missingPage["fieldValues"] as! J; connection["pageInfo"] = nil; missingPage["fieldValues"] = connection
        for node in [wrongProject, archived, incomplete, missingArchive, missingPage] {
            calls = []; Hosting.handler = { request in calls.append(request); return try json(["node": node]) }
            do { try await HostingHubAPI.rescheduleProjectItem(access, detail: detail(row()), row: row(), settings: settings, targetDay: "2026-11-02"); preconditionFailure("Incomplete fresh metadata accepted") }
            catch { precondition(error.localizedDescription.contains("changed on the server")) }
            precondition(calls.count == 1)
        }

        calls = []; var writes = 0
        Hosting.handler = { request in calls.append(request); if try query(request).hasPrefix("query") { return try json(["node": fresh()]) }; writes += 1; if writes == 2 { throw HostingError(status: 403) }; return try json([:]) }
        do { try await HostingHubAPI.rescheduleProjectItem(access, detail: detail(row()), row: row(), settings: settings, targetDay: "2026-11-02"); preconditionFailure("Partial range failure was not locked") }
        catch { precondition(error is HubUncertainWriteError) }
        precondition(calls.count == 3)
        calls = []
        Hosting.handler = { request in calls.append(request); if try query(request).hasPrefix("query") { return try json(["node": fresh()]) }; throw HostingError(status: 403) }
        do { try await HostingHubAPI.rescheduleProjectItem(access, detail: detail(row()), row: row(), settings: settings, targetDay: "2026-11-02"); preconditionFailure() }
        catch { precondition(error is HostingError, "A definite first-write rejection must preserve its error") }
        precondition(calls.count == 2)

        calls = []; var current = true
        Hosting.handler = { request in calls.append(request); current = false; return try json(["node": fresh()]) }
        let expiring = HubAccess(target: access.target, token: access.token, apiBase: access.apiBase, me: access.me, isCurrent: { current })
        do { try await HostingHubAPI.rescheduleProjectItem(expiring, detail: detail(row()), row: row(), settings: settings, targetDay: "2026-11-02"); preconditionFailure() } catch {}
        precondition(calls.count == 1, "Expired context must never reach a mutation")
        print("Project scheduling API: fresh compare, concurrent edits, range duration, no-op and invalid guards, complete metadata, account freshness and partial-write recovery passed")
    }
}
SWIFT
swiftc -parse-as-library -swift-version 5 "$ROOT/Sources/Services/HostingHub.swift" "${PROJECT_BACKEND_TEST_SOURCES[@]}" "$ROOT/Sources/Services/ProjectScheduling.swift" "$TASK_TMP/main.swift" -o "$TASK_TMP/test-project-scheduling"
"$TASK_TMP/test-project-scheduling"
