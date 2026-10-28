import Foundation
import Observation

/// Windows: entities/hosting/model/local-projects.ts. Local plans never use an account or hosting API.
@MainActor @Observable final class LocalProjectStore {
    static let shared = LocalProjectStore()
    var projects: [HubItem] = []
    var loading = false
    var loaded = false
    var error: String?
    var revision = 0
    @ObservationIgnored private let storage: LocalProjectPersistence
    @ObservationIgnored private var writing = false
    @ObservationIgnored private var operation = UUID()
    @ObservationIgnored private var writeGeneration = UUID()

    init(storage: LocalProjectPersistence = LocalProjectFileStorage()) { self.storage = storage }
    static func isLocal(_ item: HubItem) -> Bool { item.id.hasPrefix("local:") && item.data["localProject"] as? Bool == true }
    static var fields: [HubProjectField] {
        [HubProjectField(id: "local-status", name: String(localized: "Status"), options: [HubProjectOption(id: "local-todo", name: String(localized: "Todo")), HubProjectOption(id: "local-progress", name: String(localized: "In progress")), HubProjectOption(id: "local-done", name: String(localized: "Done"))]),
         HubProjectField(id: "local-start", name: String(localized: "Start date"), options: [], kind: .date),
         HubProjectField(id: "local-due", name: String(localized: "Due date"), options: [], kind: .date),
         HubProjectField(id: "local-priority", name: String(localized: "Priority"), options: [HubProjectOption(id: "local-low", name: String(localized: "Low")), HubProjectOption(id: "local-normal", name: String(localized: "Normal")), HubProjectOption(id: "local-high", name: String(localized: "High")), HubProjectOption(id: "local-urgent", name: String(localized: "Urgent"))]),
         HubProjectField(id: "local-assignees", name: String(localized: "Assignees"), options: [], kind: .text)]
    }
    func load() async {
        guard !writing else { return }
        let read = UUID(); operation = read; loading = true; error = nil
        defer { if operation == read { loading = false } }
        do { let document = try LocalPlannerDocument.decode(await storage.read()); if operation == read { publish(document) } }
        catch { if operation == read { self.error = error.localizedDescription } }
    }
    func detail(projectID: String) async throws -> HubDetail {
        guard !writing else { throw LocalProjectError.busy }
        guard projectID.hasPrefix("local:") else { throw LocalProjectError.unavailable }
        let generation = writeGeneration
        let document = try LocalPlannerDocument.decode(await storage.read())
        guard generation == writeGeneration, !writing else { throw LocalProjectError.stale }
        guard let project = document.projects.first(where: { $0.id == projectID }) else { throw LocalProjectError.unavailable }
        publish(document); return Self.detail(project)
    }
    func create(title: String, description: String = "") async throws -> HubItem {
        let name = try validTitle(title, maximum: 200), body = try validBody(description, maximum: 20_000), now = timestamp()
        let project = LocalPlannerProject(id: "local:" + UUID().uuidString.lowercased(), title: name, description: body, revision: 1, createdAt: now, updatedAt: now, tasks: [])
        try await transaction { document in guard document.projects.count < LocalProjectLimits.maxProjects else { throw LocalProjectError.invalidData }; document.projects.append(project) }
        return Self.item(project)
    }
    func saveDraft(detail: HubDetail, title: String, body: String, row: HubProjectRow? = nil, initialField: HubProjectField? = nil, option: String? = nil) async throws -> HubDetail {
        let name = try validTitle(title, maximum: 500), description = try validBody(body, maximum: 200_000)
        if let initialField {
            guard row == nil, let canonical = Self.fields.first(where: { $0.id == initialField.id && $0.kind == .singleSelect }),
                  let loaded = detail.fields.first(where: { $0.id == canonical.id && $0.kind == .singleSelect }), let option,
                  canonical.options.contains(where: { $0.id == option }), loaded.options.contains(where: { $0.id == option }) else { throw LocalProjectError.field }
        } else if option != nil { throw LocalProjectError.field }
        return try await change(detail) { project in
            if let row { let index = try taskIndex(project, row); guard !project.tasks[index].archived else { throw LocalProjectError.archived }; project.tasks[index].title = name; project.tasks[index].body = description; project.tasks[index].updatedAt = timestamp() }
            else {
                guard project.tasks.count < LocalProjectLimits.maxTasksPerProject else { throw LocalProjectError.invalidData }
                var task = LocalPlannerTask(id: "local-task:" + UUID().uuidString.lowercased(), title: name, body: description, status: "local-todo", start: "", due: "", priority: "local-normal", assignees: [], archived: false, updatedAt: timestamp())
                if let initialField { try setField(&task, fieldID: initialField.id, value: option!) }
                project.tasks.append(task)
            }
        }
    }
    func updateField(detail: HubDetail, row: HubProjectRow, field: HubProjectField, value: String?) async throws -> HubDetail {
        guard detail.fields.contains(where: { $0.id == field.id }), Self.fields.contains(where: { $0.id == field.id }) else { throw LocalProjectError.field }
        return try await change(detail) { project in let index = try taskIndex(project, row); try setField(&project.tasks[index], fieldID: field.id, value: value ?? "") }
    }
    func archive(detail: HubDetail, row: HubProjectRow, archived: Bool) async throws -> HubDetail {
        try await change(detail) { project in let index = try taskIndex(project, row); project.tasks[index].archived = archived; project.tasks[index].updatedAt = timestamp() }
    }
    func updateFields(detail: HubDetail, rows: [HubProjectRow], field: HubProjectField, value: String?) async throws -> HubDetail {
        guard detail.fields.contains(where: { $0.id == field.id }), Self.fields.contains(where: { $0.id == field.id }) else { throw LocalProjectError.field }
        return try await change(detail) { project in
            var seen = Set<String>()
            for row in rows where seen.insert(row.id).inserted { let index = try taskIndex(project, row); try setField(&project.tasks[index], fieldID: field.id, value: value ?? "") }
        }
    }
    func archiveMany(detail: HubDetail, rows: [HubProjectRow], archived: Bool) async throws -> HubDetail {
        try await change(detail) { project in
            for row in rows { let index = try taskIndex(project, row); project.tasks[index].archived = archived; project.tasks[index].updatedAt = timestamp() }
        }
    }
    func removeItem(detail: HubDetail, row: HubProjectRow) async throws -> HubDetail {
        try await removeMany(detail: detail, rows: [row])
    }
    func removeMany(detail: HubDetail, rows: [HubProjectRow]) async throws -> HubDetail {
        try await change(detail) { project in
            for row in rows { _ = try taskIndex(project, row) }
            let ids = Set(rows.map(\.id))
            guard !project.tasks.contains(where: { !ids.contains($0.id) && ($0.predecessorIDs ?? []).contains(where: { ids.contains($0) }) }) else { throw LocalProjectError.dependentDeletion }
            project.tasks.removeAll { ids.contains($0.id) }
        }
    }
    func setDependencies(detail: HubDetail, row: HubProjectRow, predecessorIDs: [String], durationDays: Int?) async throws -> HubDetail {
        try await change(detail) { project in
            let index = try taskIndex(project, row)
            guard !project.tasks[index].archived else { throw LocalProjectError.archived }
            project.tasks[index].predecessorIDs = predecessorIDs; project.tasks[index].durationDays = durationDays
            if let error = LocalProjectDependencies.validate(project.tasks) { throw error }
            project.tasks[index].updatedAt = timestamp()
        }
    }
    func reorder(detail: HubDetail, row: HubProjectRow, afterRow: HubProjectRow?) async throws -> HubDetail {
        try await change(detail) { project in
            let index = try taskIndex(project, row)
            if let afterRow { _ = try taskIndex(project, afterRow); guard afterRow.id != row.id else { throw LocalProjectError.item } }
            let task = project.tasks.remove(at: index)
            let target = afterRow.flatMap { after in project.tasks.firstIndex { $0.id == after.id }.map { $0 + 1 } } ?? 0
            project.tasks.insert(task, at: target)
        }
    }
    func saveProject(detail: HubDetail, title: String, description: String) async throws -> HubDetail {
        let name = try validTitle(title, maximum: 200), body = try validBody(description, maximum: 20_000)
        return try await change(detail) { project in project.title = name; project.description = body }
    }
    func deleteProject(detail: HubDetail) async throws {
        try await transaction { document in let index = try projectIndex(document, detail); document.projects.remove(at: index) }
    }
    func setAssignees(detail: HubDetail, row: HubProjectRow, assignees: [String]) async throws -> HubDetail {
        let values = try validAssignees(assignees)
        return try await change(detail) { project in let index = try taskIndex(project, row); guard !project.tasks[index].archived else { throw LocalProjectError.archived }; project.tasks[index].assignees = values; project.tasks[index].updatedAt = timestamp() }
    }
    func reschedule(detail: HubDetail, row: HubProjectRow, settings: ProjectScheduleSettings, targetDay: String) async throws -> HubDetail {
        try await change(detail) { project in
            let index = try taskIndex(project, row), actual = Self.detail(project).rows.first { $0.id == row.id }!
            let changes = try ProjectSchedule.reschedule(actual, fields: Self.fields, settings: settings, targetDay: targetDay)
            for change in changes { try setField(&project.tasks[index], fieldID: change.fieldID, value: change.value, validateRange: false) }
            try validRange(project.tasks[index])
        }
    }
    private func change(_ detail: HubDetail, work: (inout LocalPlannerProject) throws -> Void) async throws -> HubDetail {
        var changed: LocalPlannerProject?
        try await transaction { document in
            let index = try projectIndex(document, detail); try work(&document.projects[index])
            document.projects[index].revision += 1; document.projects[index].updatedAt = timestamp(); changed = document.projects[index]
        }
        return Self.detail(changed!)
    }
    private func transaction(_ work: (inout LocalPlannerDocument) throws -> Void) async throws {
        guard !writing else { throw LocalProjectError.busy }
        writing = true; writeGeneration = UUID(); operation = UUID(); loading = true; error = nil
        defer { writing = false; loading = false }
        do {
            let expected = try await storage.read(); var document = try LocalPlannerDocument.decode(expected)
            try work(&document); document.revision += 1
            guard document.valid else { throw LocalProjectError.invalidData }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(document)
            guard let content = String(data: data, encoding: .utf8) else { throw LocalProjectError.invalidData }
            try await storage.write(expected: expected, content: content); publish(document)
        } catch { self.error = error.localizedDescription; throw error }
    }
    private func projectIndex(_ document: LocalPlannerDocument, _ detail: HubDetail) throws -> Int {
        guard Self.isLocal(detail.item), let index = document.projects.firstIndex(where: { $0.id == detail.item.id }) else { throw LocalProjectError.unavailable }
        guard detail.item.data["localRevision"] as? Int == document.projects[index].revision else { throw LocalProjectError.stale }
        return index
    }
    private func taskIndex(_ project: LocalPlannerProject, _ row: HubProjectRow) throws -> Int {
        guard row.id.hasPrefix("local-task:"), let index = project.tasks.firstIndex(where: { $0.id == row.id }) else { throw LocalProjectError.item }
        return index
    }
    private func setField(_ task: inout LocalPlannerTask, fieldID: String, value: String, validateRange: Bool = true) throws {
        guard !task.archived else { throw LocalProjectError.archived }
        switch fieldID {
        case "local-status": guard LocalPlannerDocument.statusIDs.contains(value) else { throw LocalProjectError.field }; task.status = value
        case "local-priority": guard LocalPlannerDocument.priorityIDs.contains(value) else { throw LocalProjectError.field }; task.priority = value
        case "local-start", "local-due":
            guard value.isEmpty || ProjectSchedule.parseDay(value) != nil else { throw LocalProjectError.date }
            if fieldID == "local-start" { task.start = value } else { task.due = value }
        case "local-assignees": task.assignees = try validAssignees(value.components(separatedBy: ","))
        default: throw LocalProjectError.field
        }
        if validateRange { try validRange(task) }; task.updatedAt = timestamp()
    }
    private func validRange(_ task: LocalPlannerTask) throws { if !task.start.isEmpty && !task.due.isEmpty && task.start > task.due { throw LocalProjectError.range } }
    private func validAssignees(_ values: [String]) throws -> [String] {
        var seen = Set<String>(), result: [String] = []
        for value in values { let name = value.trimmingCharacters(in: .whitespacesAndNewlines); if !name.isEmpty && seen.insert(name.lowercased()).inserted { result.append(name) } }
        guard result.count <= 20, result.allSatisfy({ $0.count <= 100 }) else { throw LocalProjectError.assignees }; return result
    }
    private func validTitle(_ value: String, maximum: Int) throws -> String { let text = value.trimmingCharacters(in: .whitespacesAndNewlines); guard !text.isEmpty && text.count <= maximum else { throw LocalProjectError.title }; return text }
    private func validBody(_ value: String, maximum: Int) throws -> String { guard value.count <= maximum else { throw LocalProjectError.text }; return value }
    private func timestamp() -> String { ISO8601DateFormatter().string(from: Date()) }
    private func publish(_ document: LocalPlannerDocument) { projects = document.projects.sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }.map(Self.item); revision = document.revision; loaded = true; error = nil }
    private static func item(_ project: LocalPlannerProject) -> HubItem { HubItem(id: project.id, title: project.title, subtitle: String(localized: "Local project"), body: project.description, editable: true, data: ["localProject": true, "localRevision": project.revision, "createdAt": project.createdAt, "updatedAt": project.updatedAt]) }
    private static func detail(_ project: LocalPlannerProject) -> HubDetail {
        HubDetail(item: item(project), fields: fields, rows: project.tasks.map { task in
            HubProjectRow(id: task.id, title: task.title, body: task.body, url: "", contentID: task.id, statuses: ["local-status": task.status, "local-priority": task.priority], kind: .draft, state: task.status == "local-done" ? "CLOSED" : "OPEN", assignees: task.assignees, updatedAt: task.updatedAt, archived: task.archived, values: ["local-status": task.status, "local-start": task.start, "local-due": task.due, "local-priority": task.priority, "local-assignees": task.assignees.joined(separator: ", ")], predecessorIDs: task.predecessorIDs, durationDays: task.durationDays)
        })
    }
}
