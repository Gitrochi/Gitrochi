import Foundation

extension HostingHubAPI {
    /// Windows: createHubProjectTask. A column is applied to the exact new item, never inferred from a refreshed list.
    static func createProjectTask(_ c: HubAccess, detail: HubDetail, title: String, body: String = "", field: HubProjectField? = nil, option: String? = nil) async throws {
        if try usesLocal(c, item: detail.item) {
            _ = try await localProjectStore.saveDraft(detail: detail, title: title, body: body, initialField: field, option: option)
            try check(c); return
        }
        try githubProject(c, detail: detail)
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw fail(String(localized: "A draft title is required.")) }
        let actual: HubProjectField?
        if let field {
            guard let loaded = detail.fields.first(where: { $0.id == field.id }), !loaded.id.isEmpty, loaded.kind == .singleSelect,
                  option.map({ value in !value.isEmpty && loaded.options.contains(where: { $0.id == value }) }) ?? true else { throw fail(String(localized: "Select a loaded project field and item.")) }
            actual = loaded
        } else {
            guard option == nil else { throw fail(String(localized: "Select a loaded project field and item.")) }
            actual = nil
        }
        let createdID: String
        do {
            let result = try await graph(c, "mutation($input:AddProjectV2DraftIssueInput!){addProjectV2DraftIssue(input:$input){projectItem{id}}}",
                                         ["input": ["projectId": detail.item.id, "title": name, "body": body]])
            createdID = id(obj(obj(result, "addProjectV2DraftIssue"), "projectItem"))
            guard !createdID.isEmpty else { throw fail(String(localized: "The server returned an unexpected response.")) }
        } catch let error as HostingError where (400..<500).contains(error.status) { throw error }
        catch let error as HubProjectPermissionError { throw error }
        catch let error as HubProjectActionDeniedError { throw error }
        catch {
            throw HubUncertainWriteError(message: Self.error(error, token: c.token) + "\n\n" + String(localized: "The server may have accepted the last change. Refresh and check the remote item before trying again."))
        }
        guard let actual else { return }
        do {
            let input: J = ["projectId": detail.item.id, "itemId": createdID, "fieldId": actual.id]
            let result: J
            let operation: String
            if let option {
                operation = "updateProjectV2ItemFieldValue"
                var assignment = input; assignment["value"] = ["singleSelectOptionId": option]
                result = try await graph(c, "mutation($input:UpdateProjectV2ItemFieldValueInput!){updateProjectV2ItemFieldValue(input:$input){projectV2Item{id}}}", ["input": assignment])
            } else {
                operation = "clearProjectV2ItemFieldValue"
                result = try await graph(c, "mutation($input:ClearProjectV2ItemFieldValueInput!){clearProjectV2ItemFieldValue(input:$input){projectV2Item{id}}}", ["input": input])
            }
            guard id(obj(obj(result, operation), "projectV2Item")) == createdID else { throw fail(String(localized: "The server returned an unexpected response.")) }
        } catch {
            throw HubUncertainWriteError(message: String(localized: "The task was created, but its column was not confirmed. Refresh the project before trying again.") + "\n\n" + Self.error(error, token: c.token))
        }
    }
}
