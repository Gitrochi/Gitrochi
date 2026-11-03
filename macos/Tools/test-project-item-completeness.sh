#!/usr/bin/env bash
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
    static var handler: (URLRequest) throws -> Data = { _ in fatalError("Unexpected request") }
    static func projectID(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics)! }
    static func request(_ provider: Provider, _ url: String, token: String, method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest {
        var request = URLRequest(url: URL(string: url)!); request.httpMethod = method
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }; return request
    }
    static func data(_ request: URLRequest) async throws -> Data { try handler(request) }
}

@main struct ProjectItemCompletenessTests {
    @MainActor static func main() async throws {
        typealias J = [String: Any]
        func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
        func body(_ request: URLRequest) throws -> J { try JSONSerialization.jsonObject(with: request.httpBody!) as! J }
        func item(_ index: Int) -> J {
            let kind = index % 4
            var node: J = ["id": "ITEM-\(index)", "isArchived": index % 5 == 0]
            if kind == 3 { node["type"] = "REDACTED"; return node }
            node["content"] = ["__typename": kind == 1 ? "DraftIssue" : kind == 2 ? "PullRequest" : "Issue", "id": "CONTENT-\(index)", "title": "Task \(index)", "body": "Body", "state": index % 2 == 0 ? "CLOSED" : "OPEN"]
            return node
        }
        func page(_ nodes: [J], more: Bool, cursor: String? = nil, projectID: String = "PROJECT") throws -> Data {
            var info: J = ["hasNextPage": more]; if let cursor { info["endCursor"] = cursor }
            return try json(["data": ["node": ["id": projectID, "title": "Team plan", "fields": ["nodes": []], "items": ["nodes": nodes, "pageInfo": info]]]])
        }
        let access = HubAccess(target: RepoTarget(provider: .github, remote: "origin", host: "github.com", path: "demo-team/workspace"), token: "fixture-token", apiBase: "https://api.github.com", me: "reader", projectOrganization: "demo-team")
        let project = HubItem(id: "PROJECT", title: "Team plan")
        var records = (0..<215).map(item), requests = 0, detailReads = 0, organizationReads = 0
        func transport(_ request: URLRequest) throws -> Data {
            requests += 1
            let payload = try body(request), query = payload["query"] as! String, variables = payload["variables"] as! J
            if query.contains("organization(login:$owner)") {
                precondition(variables["owner"] as? String == "demo-team")
                organizationReads += 1
                return try json(["data": ["organization": ["projectsV2": ["nodes": [["id": "PROJECT", "title": "Team plan"]], "pageInfo": ["hasNextPage": false]]]]])
            }
            if query.contains("items(first:100") {
                detailReads += 1
                precondition(query.contains("archivedStates:[ARCHIVED,NOT_ARCHIVED]") && variables["id"] as? String == "PROJECT")
                switch variables["cursor"] as? String {
                case nil: return try page(Array(records[0..<100]), more: true, cursor: "AFTER-100")
                case "AFTER-100": return try page(Array(records[99..<199]), more: true, cursor: "AFTER-199")
                case "AFTER-199": return try page(Array(records[199...]), more: false)
                default: fatalError("Unexpected cursor")
                }
            }
            if query.contains("... on DraftIssue{id title body}") {
                let contentID = variables["id"] as! String
                let content = records.compactMap { $0["content"] as? J }.first { $0["id"] as? String == contentID }!
                return try json(["data": ["node": content]])
            }
            let input = variables["input"] as! J
            if query.contains("updateProjectV2DraftIssue") {
                let index = records.firstIndex { ($0["content"] as? J)?["id"] as? String == input["draftIssueId"] as? String }!
                var content = records[index]["content"] as! J; content["title"] = input["title"]; content["body"] = input["body"]; records[index]["content"] = content
                return try json(["data": ["updateProjectV2DraftIssue": ["draftIssue": ["id": input["draftIssueId"]!]]]])
            }
            precondition(query.contains("addProjectV2DraftIssue"))
            records.append(["id": "NEW-DRAFT", "content": ["__typename": "DraftIssue", "id": "NEW-CONTENT", "title": input["title"]!, "body": input["body"]!]])
            return try json(["data": ["addProjectV2DraftIssue": ["projectItem": ["id": "NEW-DRAFT"]]]])
        }
        Hosting.handler = transport
        let complete = try await HostingHubAPI.detail(access, section: .projects, item: project)
        precondition(complete.rows.count == 215 && Set(complete.rows.map(\.id)).count == 215 && detailReads == 3)
        precondition(complete.rows.last?.id == "ITEM-214" && !complete.more && complete.cursor == nil)
        precondition(complete.rows.contains { $0.archived } && complete.rows.contains { $0.kind == .redacted } && complete.rows.contains { $0.kind == .draft } && complete.rows.contains { $0.state == "CLOSED" })
        let explicit = try await HostingHubAPI.detail(access, section: .projects, item: project, page: 2, cursor: "AFTER-100")
        precondition(explicit.rows.count == 100 && explicit.more && detailReads == 4)

        // The same default loader used after mutations must retain every earlier item and late-page draft.
        let draft = complete.rows.first { $0.id == "ITEM-213" }!
        try await HostingHubAPI.saveProjectDraft(access, detail: complete, title: "Edited late draft", body: "Edited", row: draft)
        let afterEdit = try await HostingHubAPI.detail(access, section: .projects, item: project)
        precondition(afterEdit.rows.count == 215 && afterEdit.rows.first { $0.id == draft.id }?.title == "Edited late draft")
        try await HostingHubAPI.saveProjectDraft(access, detail: afterEdit, title: "New late draft", body: "Created")
        let afterCreation = try await HostingHubAPI.detail(access, section: .projects, item: project)
        precondition(afterCreation.rows.count == 216 && afterCreation.rows.last?.id == "NEW-DRAFT")

        let portfolio = ProjectPortfolioState()
        await portfolio.load(access, context: "organization")
        precondition(organizationReads == 1 && portfolio.error == nil && portfolio.projectErrors.isEmpty && portfolio.details.first?.rows.count == 216)
        let successfulSnapshot = portfolio.details[0].rows.map(\.id)
        Hosting.handler = { request in
            let variables = try body(request)["variables"] as! J
            if variables["cursor"] as? String == "AFTER-100" { throw HostingError(status: 503) }
            return try transport(request)
        }
        do { _ = try await HostingHubAPI.detail(access, section: .projects, item: project); fatalError("A partial read cannot succeed") } catch {}
        await portfolio.refresh(access, context: "organization")
        precondition(portfolio.details[0].rows.map(\.id) == successfulSnapshot && portfolio.projectErrors[project.id] != nil)

        var pageCalls = 0
        Hosting.handler = { _ in
            pageCalls += 1
            switch pageCalls {
            case 1: return try page([item(1)], more: true, cursor: "A")
            case 2: return try page([], more: true, cursor: "B")
            case 3: return try page([item(1)], more: true, cursor: "C")
            default: return try page([item(2)], more: false)
            }
        }
        let sparse = try await HostingHubAPI.detail(access, section: .projects, item: project)
        precondition(sparse.rows.map(\.id) == ["ITEM-1", "ITEM-2"] && pageCalls == 4)
        for invalidCursor: String? in [nil, ""] {
            Hosting.handler = { _ in try page([item(1)], more: true, cursor: invalidCursor) }
            do { _ = try await HostingHubAPI.detail(access, section: .projects, item: project); fatalError("Missing cursor accepted") } catch {}
        }
        pageCalls = 0
        Hosting.handler = { _ in
            pageCalls += 1
            return try page([item(pageCalls)], more: true, cursor: pageCalls == 2 ? "B" : "A")
        }
        do { _ = try await HostingHubAPI.detail(access, section: .projects, item: project); fatalError("Cursor cycle accepted") } catch {}
        precondition(pageCalls == 3)
        pageCalls = 0
        Hosting.handler = { _ in pageCalls += 1; return try page([item(pageCalls)], more: true, cursor: "A") }
        do { _ = try await HostingHubAPI.detail(access, section: .projects, item: project); fatalError("Stalled cursor accepted") } catch {}
        precondition(pageCalls == 2)
        pageCalls = 0
        Hosting.handler = { _ in pageCalls += 1; return try page([item(pageCalls)], more: pageCalls == 1, cursor: "A", projectID: pageCalls == 1 ? "PROJECT" : "OTHER") }
        do { _ = try await HostingHubAPI.detail(access, section: .projects, item: project); fatalError("Wrong project accepted") } catch {}
        precondition(pageCalls == 2)
        var current = true, staleAccess = access
        staleAccess.isCurrent = { current }
        pageCalls = 0
        Hosting.handler = { _ in
            pageCalls += 1
            if pageCalls == 2 { current = false }
            return try page([item(pageCalls)], more: true, cursor: pageCalls == 1 ? "A" : "B")
        }
        do { _ = try await HostingHubAPI.detail(staleAccess, section: .projects, item: project); fatalError("Stale project accepted") } catch {}
        precondition(pageCalls == 2)
        let beforeCancellation = requests
        Hosting.handler = { _ in requests += 1; fatalError("Cancelled read requested transport") }
        let cancelled = Task { try await HostingHubAPI.detail(access, section: .projects, item: project) }
        cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("Cancelled project accepted") } catch is CancellationError {} catch { fatalError("Wrong cancellation failure") }
        precondition(requests == beforeCancellation)
        print("Project completeness: all mixed item pages, deduplication, late draft edits and creation, organization portfolio, failed-page snapshot preservation, sparse advancing pages, invalid cursors, wrong project, stale context and cancellation passed")
    }
}
SWIFT
swiftc -parse-as-library -swift-version 5 "$ROOT/Sources/Services/HostingHub.swift" "${PROJECT_BACKEND_TEST_SOURCES[@]}" "$ROOT/Sources/Core/ProjectPortfolioPreferences.swift" "$ROOT/Sources/Services/ProjectPortfolio.swift" "$TASK_TMP/main.swift" -o "$TASK_TMP/test-project-item-completeness"
"$TASK_TMP/test-project-item-completeness"
