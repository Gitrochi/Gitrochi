#!/usr/bin/env bash
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
    static var handler: (URLRequest) throws -> Data = { _ in fatalError("Unexpected HTTP") }
    static func projectID(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.~")))! }
    static func request(_ provider: Provider, _ url: String, token: String, method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest {
        var request = URLRequest(url: URL(string: url)!); request.httpMethod = method
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }; return request
    }
    static func data(_ request: URLRequest) async throws -> Data { try handler(request) }
}
@main struct ProjectManagementTests {
    @MainActor static func main() async throws {
        typealias J = [String: Any]
        func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
        func requestBody(_ request: URLRequest) throws -> J { try JSONSerialization.jsonObject(with: request.httpBody!) as! J }
        func variables(_ request: URLRequest) throws -> J { try requestBody(request)["variables"] as! J }
        func input(_ request: URLRequest) throws -> J { try variables(request)["input"] as! J }
        func connection(_ nodes: [J], more: Bool = false) -> J { ["nodes": nodes, "pageInfo": ["hasNextPage": more]] }
        let c = HubAccess(target: RepoTarget(provider: .github, remote: "origin", host: "github.com", path: "team/client"), token: "fixture-token", apiBase: "https://api.github.com", me: "reader")
        let metadata: J = ["id": "P", "number": 1, "title": "Delivery", "shortDescription": "Team plan", "readme": "Guide", "public": false, "closed": false, "updatedAt": "2026-01-01"]
        let field = HubProjectField(id: "F", name: "Priority", options: [HubProjectOption(id: "A", name: "High"), HubProjectOption(id: "B", name: "Low")])
        let fieldNode: J = ["id": "F", "name": "Priority", "options": [["id": "A", "name": "High", "color": "RED", "description": "Urgent"], ["id": "B", "name": "Low", "color": "GRAY", "description": "Later"]]]
        let detail = HubDetail(item: HubItem(id: "P", title: "Delivery", body: "Team plan", data: metadata), fields: [field, HubProjectField(id: "N", name: "Points", options: [], kind: .number), HubProjectField(id: "TITLE", name: "Title", options: [], kind: .unsupported)])
        let viewNode: J = ["id": "V", "name": "Ready", "number": 2, "updatedAt": "2026-01-01", "layout": "BOARD_LAYOUT", "filter": "status:Todo", "project": ["id": "P"], "configuration": ["visibleFields": connection([["id": "F"], ["id": "TITLE"]])], "groupByFields": connection([["id": "F"]]), "sortByFields": connection([["direction": "DESC", "field": ["id": "N"]]])]
        let view = HubProjectView(id: "V", name: "Ready", number: 2, updatedAt: "2026-01-01", layout: .board, filter: "status:Todo", visibleFieldIDs: ["F", "TITLE"], groupFieldIDs: ["F"], sortFields: [HubProjectViewSort(fieldID: "N", direction: "DESC")])
        var calls: [URLRequest] = []
        Hosting.handler = { request in
            calls.append(request); precondition(request.url!.absoluteString == "https://api.github.com/graphql")
            return try json(["data": (try requestBody(request)["query"] as! String).hasPrefix("query") ? ["repository": ["id": "REPO", "owner": ["id": "OWNER"]]] : ["createProjectV2": ["projectV2": metadata]]])
        }
        let created = try await HostingHubAPI.createProject(c, title: "  Delivery  ")
        precondition(created.id == "P" && calls.count == 2)
        let createInput = try input(calls.last!)
        precondition(createInput["ownerId"] as? String == "OWNER" && createInput["repositoryId"] as? String == "REPO" && createInput["title"] as? String == "Delivery")
        var personal = c.target; personal.path = "reader/workspace"
        Hosting.handler = { request in
            calls.append(request)
            return try json(["data": (try requestBody(request)["query"] as! String).hasPrefix("query") ? ["repositoryOwner": ["id": "USER"]] : ["createProjectV2": ["projectV2": metadata]]])
        }
        _ = try await HostingHubAPI.createProject(HubAccess(target: personal, token: c.token, apiBase: c.apiBase, me: c.me), title: "Personal")
        precondition(try! input(calls.last!)["repositoryId"] == nil)

        let settings = HubProjectSettingsInput(title: "Release", shortDescription: "Summary", readme: "Handbook", isPublic: true, closed: true)
        Hosting.handler = { request in calls.append(request); return try json(["data": ["node": metadata]]) }
        try await HostingHubAPI.saveProjectSettings(c, detail: detail, input: settings)
        let settingsInput = try input(calls.last!)
        precondition(settingsInput["public"] as? Bool == true && settingsInput["closed"] as? Bool == true && settingsInput["readme"] as? String == "Handbook")
        let beforeConflict = calls.count
        var changed = metadata; changed["readme"] = "Collaborator"
        Hosting.handler = { request in calls.append(request); return try json(["data": ["node": changed]]) }
        do { try await HostingHubAPI.saveProjectSettings(c, detail: detail, input: settings); fatalError("Stale metadata accepted") } catch { precondition(error.localizedDescription.contains("changed on the server")) }
        precondition(calls.count == beforeConflict + 1)

        Hosting.handler = { request in calls.append(request); return try json(["data": [:]]) }
        for (kind, expected) in [(HubProjectFieldKind.text, "TEXT"), (.number, "NUMBER"), (.date, "DATE"), (.singleSelect, "SINGLE_SELECT")] {
            let options: [HubProjectFieldOptionInput] = kind == .singleSelect ? [HubProjectFieldOptionInput(name: "Ready", color: "GREEN")] : []
            try await HostingHubAPI.saveProjectCustomField(c, detail: detail, input: HubProjectFieldInput(name: "Custom", kind: kind, options: options))
            precondition(try! input(calls.last!)["dataType"] as? String == expected)
        }
        Hosting.handler = { request in calls.append(request); return try json(["data": ["node": ["id": "P", "fields": connection([fieldNode])]]]) }
        try await HostingHubAPI.saveProjectCustomField(c, detail: detail, input: HubProjectFieldInput(name: "Urgency", kind: .singleSelect, options: [HubProjectFieldOptionInput(id: "A", name: "Critical"), HubProjectFieldOptionInput(id: "B", name: "Low")]), previous: field)
        let updatedOptions = try input(calls.last!)["singleSelectOptions"] as! [J]
        precondition(updatedOptions[0]["id"] as? String == "A" && updatedOptions[0]["color"] as? String == "RED" && updatedOptions[0]["description"] as? String == "Urgent")
        try await HostingHubAPI.deleteProjectCustomField(c, detail: detail, field: field)
        precondition((try! requestBody(calls.last!)["query"] as! String).contains("DeleteProjectV2FieldInput!"))
        let beforeInvalid = calls.count
        do { try await HostingHubAPI.deleteProjectCustomField(c, detail: detail, field: detail.fields[2]); fatalError("Built-in field deleted") } catch {}
        do { try await HostingHubAPI.saveProjectCustomField(c, detail: detail, input: HubProjectFieldInput(name: "X", kind: .number), previous: field); fatalError("Changed field type") } catch {}
        do { try await HostingHubAPI.saveProjectCustomField(c, detail: detail, input: HubProjectFieldInput(name: "X", kind: .singleSelect)); fatalError("Empty options") } catch {}
        do { try await HostingHubAPI.saveProjectCustomField(c, detail: detail, input: HubProjectFieldInput(name: "X", kind: .singleSelect, options: [HubProjectFieldOptionInput(name: "One"), HubProjectFieldOptionInput(name: " One ")])); fatalError("Duplicate options") } catch {}
        precondition(calls.count == beforeInvalid)

        Hosting.handler = { request in calls.append(request); return try json(["data": ["node": ["id": "P", "views": ["nodes": [viewNode], "pageInfo": ["hasNextPage": true, "endCursor": "next"]]]]]) }
        let page = try await HostingHubAPI.projectViews(c, detail: detail, cursor: "before")
        precondition(page.views == [view] && page.more && page.cursor == "next")
        precondition(try! variables(calls.last!)["cursor"] as? String == "before")
        let viewQuery = try requestBody(calls.last!)["query"] as! String
        precondition(viewQuery.contains("configuration{visibleFields") && viewQuery.contains("groupByFields") && viewQuery.contains("sortByFields") && !viewQuery.contains("items("))
        Hosting.handler = { request in calls.append(request); return try json(["data": ["node": viewNode]]) }
        try await HostingHubAPI.saveProjectView(c, detail: detail, input: HubProjectViewInput(name: "Review", layout: .table, filter: "assignee:@me", visibleFieldIDs: ["TITLE", "F"]), previous: view)
        let viewInput = try input(calls.last!), configuration = viewInput["configuration"] as! J
        precondition(viewInput["viewId"] as? String == "V" && viewInput["layout"] as? String == "TABLE_LAYOUT" && configuration["visibleFieldIds"] as? [String] == ["TITLE", "F"])
        precondition(viewInput["groupByFields"] == nil && viewInput["sortByFields"] == nil)
        try await HostingHubAPI.deleteProjectView(c, detail: detail, view: view)
        precondition((try! requestBody(calls.last!)["query"] as! String).contains("DeleteProjectV2ViewInput!"))
        let beforeWrongProject = calls.count
        var wrongView = viewNode; wrongView["project"] = ["id": "OTHER"]
        Hosting.handler = { request in calls.append(request); return try json(["data": ["node": wrongView]]) }
        do { try await HostingHubAPI.deleteProjectView(c, detail: detail, view: view); fatalError("Wrong project accepted") } catch {}
        precondition(calls.count == beforeWrongProject + 1)

        Hosting.handler = { request in calls.append(request); return try json(["data": ["createProjectV2View": ["projectV2View": ["id": "NEW"]]]]) }
        try await HostingHubAPI.saveProjectView(c, detail: detail, input: HubProjectViewInput(name: "Mine", layout: .board, filter: "assignee:@me", visibleFieldIDs: ["TITLE"]))
        let createViewInput = try input(calls[calls.count - 2]), filterInput = try input(calls.last!)
        precondition(createViewInput["filter"] == nil && filterInput["viewId"] as? String == "NEW" && filterInput["filter"] as? String == "assignee:@me")
        Hosting.handler = { request in
            calls.append(request)
            if (try requestBody(request)["query"] as! String).contains("updateProjectV2View") { throw HostingError(status: 403) }
            return try json(["data": ["createProjectV2View": ["projectV2View": ["id": "NEW"]]]])
        }
        let beforePartial = calls.count
        do { try await HostingHubAPI.saveProjectView(c, detail: detail, input: HubProjectViewInput(name: "Mine", layout: .board, filter: "assignee:@me", visibleFieldIDs: [])); fatalError("Partial creation accepted") } catch { precondition(error is HubUncertainWriteError) }
        precondition(calls.count == beforePartial + 2)

        var commonDetail = detail; commonDetail.fields.append(HubProjectField(id: "M", name: "Teams", options: [], kind: .unsupported))
        var commonView = viewNode; commonView["configuration"] = ["visibleFields": connection([["__typename": "ProjectV2MultiSelectField", "id": "M"], ["id": "TITLE"], ["id": "F"]])]
        Hosting.handler = { request in
            calls.append(request); let query = try requestBody(request)["query"] as! String
            if query.contains("views(first:") { precondition(query.contains("... on ProjectV2FieldCommon{id}")); return try json(["data": ["node": ["id": "P", "views": connection([commonView])]]]) }
            return try json(["data": ["node": commonView]])
        }
        let commonPage = try await HostingHubAPI.projectViews(c, detail: commonDetail)
        precondition(commonPage.views[0].visibleFieldIDs == ["M", "TITLE", "F"])
        try await HostingHubAPI.saveProjectView(c, detail: commonDetail, input: HubProjectViewInput(name: "Renamed", layout: commonPage.views[0].layout, filter: commonPage.views[0].filter, visibleFieldIDs: commonPage.views[0].visibleFieldIDs), previous: commonPage.views[0])
        precondition((try! input(calls.last!)["configuration"] as! J)["visibleFieldIds"] as? [String] == ["M", "TITLE", "F"])
        var incompleteVisible = viewNode, incompleteGroup = viewNode, incompleteSort = viewNode
        incompleteVisible["configuration"] = ["visibleFields": connection([[:]])]; incompleteGroup["groupByFields"] = connection([[:]]); incompleteSort["sortByFields"] = connection([["direction": "ASC", "field": [:]]])
        for malformed in [incompleteVisible, incompleteGroup, incompleteSort] {
            Hosting.handler = { request in calls.append(request); return try json(["data": ["node": ["id": "P", "views": connection([malformed])]]]) }
            do { _ = try await HostingHubAPI.projectViews(c, detail: commonDetail); fatalError("Incomplete shared view fields accepted") } catch { precondition(error.localizedDescription.contains("unexpected response")) }
        }
        var current = true, guarded = c; guarded.isCurrent = { current }
        Hosting.handler = { request in calls.append(request); current = false; return try json(["data": ["repository": ["id": "R", "owner": ["id": "O"]]]]) }
        let beforeSwitch = calls.count
        do { _ = try await HostingHubAPI.createProject(guarded, title: "Plan"); fatalError("Stale scope accepted") } catch { precondition(error.localizedDescription.contains("account changed")) }
        precondition(calls.count == beforeSwitch + 1)
        print("Project management contract checks passed")
    }
}
SWIFT
swiftc -parse-as-library -swift-version 5 "$ROOT/Sources/Services/HostingHub.swift" "$ROOT/Sources/Services/ProjectManagement.swift" "$TASK_TMP/main.swift" -o "$TASK_TMP/test-project-management"
"$TASK_TMP/test-project-management"
