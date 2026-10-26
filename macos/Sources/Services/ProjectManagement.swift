import Foundation

/// Windows: mirrors the checked ProjectV2 management contract in project-management.ts.
struct HubProjectSettingsInput { var title: String; var shortDescription: String; var readme: String; var isPublic: Bool; var closed: Bool }
struct HubProjectFieldOptionInput { var id: String?; var name: String; var color: String?; var description: String? }
struct HubProjectFieldInput { var name: String; var kind: HubProjectFieldKind; var options: [HubProjectFieldOptionInput] = [] }
enum HubProjectViewLayout: String, CaseIterable, Identifiable {
    case board = "BOARD_LAYOUT", table = "TABLE_LAYOUT", roadmap = "ROADMAP_LAYOUT"
    var id: String { rawValue }
}
struct HubProjectViewSort: Equatable { var fieldID: String; var direction: String }
struct HubProjectView: Identifiable, Equatable {
    var id: String; var name: String; var number: Int?; var updatedAt: String?
    var layout: HubProjectViewLayout; var filter: String; var visibleFieldIDs: [String]; var groupFieldIDs: [String]; var sortFields: [HubProjectViewSort]
}
struct HubProjectViewInput { var name: String; var layout: HubProjectViewLayout; var filter: String; var visibleFieldIDs: [String] }
struct HubProjectViewPage { var views: [HubProjectView]; var more: Bool; var cursor: String? }

extension HostingHubAPI {
    private static var managementProjectFragment: String { "id number title shortDescription readme public closed url updatedAt" }
    private static var managementFieldIDFragment: String { "... on ProjectV2FieldCommon{id}" }
    private static var managementFieldFragment: String { "... on ProjectV2FieldCommon{id name dataType} ... on ProjectV2SingleSelectField{id name options{id name color description}}" }
    private static var managementViewFragment: String {
        "id name number updatedAt layout filter project{id} configuration{visibleFields(first:100){nodes{\(managementFieldIDFragment)} pageInfo{hasNextPage}}} groupByFields(first:100){nodes{\(managementFieldIDFragment)} pageInfo{hasNextPage}} sortByFields(first:100){nodes{direction field{\(managementFieldIDFragment)}} pageInfo{hasNextPage}}"
    }
    private static var managementConflict: NSError { fail(String(localized: "This item changed on the server. Refresh before saving.")) }
    private static var managementInvalid: NSError { fail(String(localized: "Enter a valid project name and field configuration.")) }
    private static func managementType(_ kind: HubProjectFieldKind) -> String? {
        switch kind { case .text: return "TEXT"; case .number: return "NUMBER"; case .date: return "DATE"; case .singleSelect: return "SINGLE_SELECT"; default: return nil }
    }
    private static func managementCheck(_ c: HubAccess, detail: HubDetail? = nil) throws {
        try check(c)
        guard c.target.provider == .github, detail == nil || detail?.item.id.isEmpty == false else { throw fail(String(localized: "This action requires a GitHub project.")) }
    }
    private static func managementName(_ value: String) throws -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw managementInvalid }; return clean
    }
    private static func managementCreation<T>(_ c: HubAccess, _ action: () async throws -> T) async throws -> T {
        do { return try await action() }
        catch let error as HostingError where (400..<500).contains(error.status) { throw error }
        catch let error as HubProjectPermissionError { throw error }
        catch let error as HubUncertainWriteError { throw error }
        catch { throw HubUncertainWriteError(message: Self.error(error, token: c.token) + "\n\n" + String(localized: "The server may have accepted the last change. Refresh and check the remote item before trying again.")) }
    }

    /// Resolves the captured scope's owner and optional linked repository on the connected API.
    static func createProject(_ c: HubAccess, title: String) async throws -> HubItem {
        try managementCheck(c); let cleanTitle = try managementName(title)
        let parts = c.target.path.split(separator: "/").map(String.init), owner = parts.first ?? c.me, repository = parts.last ?? "workspace", personal = repository == "workspace"
        let query = personal ? "query($owner:String!){repositoryOwner(login:$owner){id}}" : "query($owner:String!,$name:String!){repository(owner:$owner,name:$name){id owner{id}}}"
        let response = try await graph(c, query, personal ? ["owner": owner] : ["owner": owner, "name": repository]), source = obj(response, "repository")
        let ownerID = id(personal ? obj(response, "repositoryOwner") : obj(source, "owner"))
        guard !ownerID.isEmpty, personal || !id(source).isEmpty else { throw fail(String(localized: "Projects are unavailable for this repository owner.")) }
        var input: J = ["ownerId": ownerID, "title": cleanTitle]; if !personal { input["repositoryId"] = id(source) }
        return try await managementCreation(c) {
            let data = try await graph(c, "mutation($input:CreateProjectV2Input!){createProjectV2(input:$input){projectV2{\(managementProjectFragment)}}}", ["input": input]), project = obj(obj(data, "createProjectV2"), "projectV2")
            guard !id(project).isEmpty else { throw fail(String(localized: "The server returned an unexpected response.")) }
            return HubItem(id: id(project), title: s(project, "title"), subtitle: "#" + id(project, "number") + (project["closed"] as? Bool == true ? " · closed" : ""), body: s(project, "shortDescription"), url: s(project, "url"), data: project)
        }
    }

    /// Checks the captured metadata before changing identity, visibility or lifecycle.
    static func saveProjectSettings(_ c: HubAccess, detail: HubDetail, input: HubProjectSettingsInput) async throws {
        try managementCheck(c, detail: detail); let title = try managementName(input.title)
        let response = try await graph(c, "query($id:ID!){node(id:$id){... on ProjectV2{\(managementProjectFragment)}}}", ["id": detail.item.id]), fresh = obj(response, "node"), previous = detail.item
        guard id(fresh) == previous.id, s(fresh, "title") == previous.title, s(fresh, "shortDescription") == previous.body else { throw managementConflict }
        for key in ["readme", "public", "closed", "updatedAt"] where previous.data[key] != nil {
            guard NSObject.isEqualValue(previous.data[key], fresh[key]) else { throw managementConflict }
        }
        _ = try await graph(c, "mutation($input:UpdateProjectV2Input!){updateProjectV2(input:$input){projectV2{id}}}", ["input": ["projectId": previous.id, "title": title, "shortDescription": input.shortDescription, "readme": input.readme, "public": input.isPublic, "closed": input.closed]])
    }

    private static func managementLoadedField(_ detail: HubDetail, _ field: HubProjectField) throws -> HubProjectField {
        guard let actual = detail.fields.first(where: { $0.id == field.id }), managementType(actual.kind) != nil else { throw fail(String(localized: "Select a loaded custom project field.")) }
        return actual
    }
    private static func managementFreshField(_ c: HubAccess, detail: HubDetail, field: HubProjectField) async throws -> J {
        let response = try await graph(c, "query($id:ID!){node(id:$id){... on ProjectV2{id fields(first:100){nodes{\(managementFieldFragment)}}}}}", ["id": detail.item.id]), project = obj(response, "node")
        guard id(project) == detail.item.id, let fresh = arr(obj(project, "fields"), "nodes").first(where: { id($0) == field.id }), s(fresh, "name") == field.name else { throw managementConflict }
        if field.kind == .singleSelect {
            let options = arr(fresh, "options")
            guard options.count == field.options.count, zip(options, field.options).allSatisfy({ id($0.0) == $0.1.id && s($0.0, "name") == $0.1.name }) else { throw managementConflict }
        } else { guard s(fresh, "dataType") == managementType(field.kind) else { throw managementConflict } }
        return fresh
    }
    private static func managementOptions(_ input: HubProjectFieldInput, current: J = [:]) throws -> [J]? {
        guard input.kind == .singleSelect else { guard input.options.isEmpty else { throw managementInvalid }; return nil }
        let names = try input.options.map { try managementName($0.name) }, ids = input.options.compactMap(\.id)
        guard !names.isEmpty, Set(names).count == names.count, Set(ids).count == ids.count else { throw managementInvalid }
        let known = arr(current, "options"), colors = ["BLUE", "GRAY", "GREEN", "ORANGE", "PINK", "PURPLE", "RED", "YELLOW"]
        return try input.options.map { option in
            let existing = known.first { id($0) == option.id } ?? [:]
            guard option.id == nil || !existing.isEmpty, option.color == nil || colors.contains(option.color!) else { throw managementInvalid }
            let previousColor = s(existing, "color")
            var value: J = ["name": try managementName(option.name), "color": option.color ?? (previousColor.isEmpty ? "GRAY" : previousColor), "description": option.description ?? s(existing, "description")]
            if let optionID = option.id { value["id"] = optionID }; return value
        }
    }

    /// Preserves option identities and metadata so a rename does not clear task values.
    static func saveProjectCustomField(_ c: HubAccess, detail: HubDetail, input: HubProjectFieldInput, previous: HubProjectField? = nil) async throws {
        try managementCheck(c, detail: detail); let name = try managementName(input.name)
        guard let type = managementType(input.kind) else { throw managementInvalid }
        guard let previous else {
            let options = try managementOptions(input); var variables: J = ["projectId": detail.item.id, "name": name, "dataType": type]
            if let options { variables["singleSelectOptions"] = options }
            _ = try await managementCreation(c) { try await graph(c, "mutation($input:CreateProjectV2FieldInput!){createProjectV2Field(input:$input){projectV2Field{\(managementFieldIDFragment)}}}", ["input": variables]) }; return
        }
        let actual = try managementLoadedField(detail, previous); guard actual.kind == input.kind else { throw managementInvalid }
        let fresh = try await managementFreshField(c, detail: detail, field: actual), options = try managementOptions(input, current: fresh)
        var variables: J = ["fieldId": actual.id, "name": name]; if let options { variables["singleSelectOptions"] = options }
        _ = try await graph(c, "mutation($input:UpdateProjectV2FieldInput!){updateProjectV2Field(input:$input){projectV2Field{\(managementFieldIDFragment)}}}", ["input": variables])
    }

    /// Deletes only a loaded custom field after checking its current server identity.
    static func deleteProjectCustomField(_ c: HubAccess, detail: HubDetail, field: HubProjectField) async throws {
        try managementCheck(c, detail: detail); let actual = try managementLoadedField(detail, field)
        _ = try await managementFreshField(c, detail: detail, field: actual)
        _ = try await graph(c, "mutation($input:DeleteProjectV2FieldInput!){deleteProjectV2Field(input:$input){projectV2Field{\(managementFieldIDFragment)}}}", ["input": ["fieldId": actual.id]])
    }

    private static func managementView(_ value: J) throws -> HubProjectView {
        let visible = obj(obj(value, "configuration"), "visibleFields"), group = obj(value, "groupByFields"), sort = obj(value, "sortByFields")
        guard !id(value).isEmpty, let layout = HubProjectViewLayout(rawValue: s(value, "layout")), ![visible, group, sort].contains(where: { obj($0, "pageInfo")["hasNextPage"] as? Bool == true }) else { throw fail(String(localized: "The server returned an unexpected response.")) }
        let visibleIDs = arr(visible, "nodes").map { id($0) }, groupIDs = arr(group, "nodes").map { id($0) }, sortFields = arr(sort, "nodes").map { HubProjectViewSort(fieldID: id(obj($0, "field")), direction: s($0, "direction") == "DESC" ? "DESC" : "ASC") }
        guard (visibleIDs + groupIDs + sortFields.map(\.fieldID)).allSatisfy({ !$0.isEmpty }) else { throw fail(String(localized: "The server returned an unexpected response.")) }
        return HubProjectView(id: id(value), name: s(value, "name"), number: value["number"] as? Int, updatedAt: value["updatedAt"] as? String, layout: layout, filter: s(value, "filter"), visibleFieldIDs: visibleIDs, groupFieldIDs: groupIDs, sortFields: sortFields)
    }

    /// Loads shared views with ordered visible fields, grouping and sorting, including pagination.
    static func projectViews(_ c: HubAccess, detail: HubDetail, cursor: String? = nil) async throws -> HubProjectViewPage {
        try managementCheck(c, detail: detail)
        let response = try await graph(c, "query($id:ID!,$cursor:String){node(id:$id){... on ProjectV2{id views(first:30,after:$cursor){nodes{\(managementViewFragment)} pageInfo{hasNextPage endCursor}}}}}", ["id": detail.item.id, "cursor": cursor as Any? ?? NSNull()]), project = obj(response, "node"), connection = obj(project, "views"), page = obj(connection, "pageInfo")
        guard id(project) == detail.item.id else { throw fail(String(localized: "Project is unavailable or this account cannot access it.")) }
        return HubProjectViewPage(views: try arr(connection, "nodes").map(managementView), more: page["hasNextPage"] as? Bool == true, cursor: page["endCursor"] as? String)
    }
    private static func managementFreshView(_ c: HubAccess, detail: HubDetail, previous: HubProjectView) async throws {
        let response = try await graph(c, "query($id:ID!){node(id:$id){... on ProjectV2View{\(managementViewFragment)}}}", ["id": previous.id]), fresh = obj(response, "node")
        guard id(obj(fresh, "project")) == detail.item.id, try managementView(fresh) == previous else { throw managementConflict }
    }

    /// The API permits writing name/layout/filter/visible fields; grouping and sorting remain unchanged.
    static func saveProjectView(_ c: HubAccess, detail: HubDetail, input: HubProjectViewInput, previous: HubProjectView? = nil) async throws {
        try managementCheck(c, detail: detail); let name = try managementName(input.name)
        guard Set(input.visibleFieldIDs).count == input.visibleFieldIDs.count, input.visibleFieldIDs.allSatisfy({ fieldID in detail.fields.contains { $0.id == fieldID } }) else { throw managementInvalid }
        let configuration: J = ["visibleFieldIds": input.visibleFieldIDs]
        if let previous {
            try await managementFreshView(c, detail: detail, previous: previous)
            _ = try await graph(c, "mutation($input:UpdateProjectV2ViewInput!){updateProjectV2View(input:$input){projectV2View{id}}}", ["input": ["viewId": previous.id, "name": name, "layout": input.layout.rawValue, "filter": input.filter, "configuration": configuration]]); return
        }
        _ = try await managementCreation(c) {
            let response = try await graph(c, "mutation($input:CreateProjectV2ViewInput!){createProjectV2View(input:$input){projectV2View{id}}}", ["input": ["projectId": detail.item.id, "name": name, "layout": input.layout.rawValue, "configuration": configuration]]), viewID = id(obj(obj(response, "createProjectV2View"), "projectV2View"))
            guard !viewID.isEmpty else { throw fail(String(localized: "The server returned an unexpected response.")) }
            // CreateProjectV2ViewInput has no filter; a failed follow-up can leave a created view.
            if !input.filter.isEmpty {
                do { _ = try await graph(c, "mutation($input:UpdateProjectV2ViewInput!){updateProjectV2View(input:$input){projectV2View{id}}}", ["input": ["viewId": viewID, "filter": input.filter]]) }
                catch { throw HubUncertainWriteError(message: Self.error(error, token: c.token) + "\n\n" + String(localized: "The server may have accepted the last change. Refresh and check the remote item before trying again.")) }
            }
        }
    }

    /// Validates project membership and current view configuration before deletion.
    static func deleteProjectView(_ c: HubAccess, detail: HubDetail, view: HubProjectView) async throws {
        try managementCheck(c, detail: detail); try await managementFreshView(c, detail: detail, previous: view)
        _ = try await graph(c, "mutation($input:DeleteProjectV2ViewInput!){deleteProjectV2View(input:$input){projectV2View{id}}}", ["input": ["viewId": view.id]])
    }
}

private extension NSObject {
    static func isEqualValue(_ lhs: Any?, _ rhs: Any?) -> Bool {
        guard let lhs = lhs as? NSObject, let rhs = rhs as? NSObject else { return lhs == nil && rhs == nil }; return lhs.isEqual(rhs)
    }
}
