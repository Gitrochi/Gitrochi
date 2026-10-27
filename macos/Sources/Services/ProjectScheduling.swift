import Foundation

extension HostingHubAPI {
    /// Compare the captured dates before shifting a range so another person's schedule is preserved.
    static func rescheduleProjectItem(_ c: HubAccess, detail: HubDetail, row: HubProjectRow,
                                      settings: ProjectScheduleSettings, targetDay: String) async throws {
        if try usesLocal(c, item: detail.item) { _ = try await localProjectStore.reschedule(detail: detail, row: row, settings: settings, targetDay: targetDay); try check(c); return }
        try githubProject(c, detail: detail)
        guard let loaded = detail.rows.first(where: { $0.id == row.id }), !loaded.archived,
              loaded.kind != .redacted else { throw fail(String(localized: "Select a loaded project field and item.")) }
        let changes: [ProjectScheduleChange]
        do { changes = try ProjectSchedule.reschedule(loaded, fields: detail.fields, settings: settings, targetDay: targetDay) }
        catch ProjectScheduleError.invalidRange { throw fail(String(localized: "The start date is after the due date. Correct it before rescheduling.")) }
        catch { throw fail(String(localized: "Choose valid project date fields before scheduling this task.")) }
        let pending = changes.filter { ($0.value) != (loaded.values[$0.fieldID] ?? loaded.statuses[$0.fieldID] ?? "") }
        guard !pending.isEmpty else { return }
        let response = try await graph(c, "query($id:ID!){node(id:$id){... on ProjectV2Item{id isArchived project{id} fieldValues(first:100){nodes{... on ProjectV2ItemFieldDateValue{date field{... on ProjectV2FieldCommon{id}}}} pageInfo{hasNextPage}}}}}", ["id": loaded.id])
        let fresh = obj(response, "node"), connection = obj(fresh, "fieldValues")
        guard id(fresh) == loaded.id, id(obj(fresh, "project")) == detail.item.id,
              fresh["isArchived"] as? Bool == false, connection["nodes"] as? [J] != nil,
              obj(connection, "pageInfo")["hasNextPage"] as? Bool == false else {
            throw fail(String(localized: "This item changed on the server. Refresh before saving."))
        }
        var values: [String: String] = [:]
        for value in arr(connection, "nodes") { values[id(obj(value, "field"))] = s(value, "date") }
        let scheduleFields = ProjectSchedule.fields(detail.fields, settings: settings)
        let comparedIDs = Set([scheduleFields.start?.id, scheduleFields.due?.id].compactMap { $0 })
        for fieldID in comparedIDs {
            guard detail.fields.contains(where: { $0.id == fieldID && $0.kind == .date }),
                  (values[fieldID] ?? "") == (loaded.values[fieldID] ?? loaded.statuses[fieldID] ?? "") else {
                throw fail(String(localized: "This item changed on the server. Refresh before saving."))
            }
        }
        var completed = 0
        do {
            for change in pending {
                guard let field = detail.fields.first(where: { $0.id == change.fieldID }) else { continue }
                try await updateProjectField(c, detail: detail, row: loaded, field: field, value: change.value)
                completed += 1
            }
        } catch let error as HostingError where completed == 0 && (400..<500).contains(error.status) { throw error }
        catch {
            throw HubUncertainWriteError(message: Self.error(error, token: c.token) + "\n\n" + String(localized: "The schedule may have changed. Refresh the project before scheduling again."))
        }
    }
}
