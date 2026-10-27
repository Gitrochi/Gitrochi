import Foundation

enum LocalProjectLimits {
    static let maxProjects = 1000
    static let maxTasksPerProject = 10_000
    static let maxBytes = 50_000_000
}

struct LocalPlannerTask: Codable {
    var id: String; var title: String; var body: String; var status: String
    var start: String; var due: String; var priority: String; var assignees: [String]
    var archived: Bool; var updatedAt: String
}
struct LocalPlannerProject: Codable {
    var id: String; var title: String; var description: String; var revision: Int
    var createdAt: String; var updatedAt: String; var tasks: [LocalPlannerTask]
}
struct LocalPlannerDocument: Codable {
    var version = 1; var revision = 0; var projects: [LocalPlannerProject] = []
    static let statusIDs = ["local-todo", "local-progress", "local-done"]
    static let priorityIDs = ["local-low", "local-normal", "local-high", "local-urgent"]

    static func decode(_ raw: String?) throws -> LocalPlannerDocument {
        guard let raw else { return .init() }
        guard raw.utf8.count <= LocalProjectLimits.maxBytes, let data = raw.data(using: .utf8),
              let document = try? JSONDecoder().decode(Self.self, from: data), document.valid else {
            throw LocalProjectError.invalidData
        }
        return document
    }
    var valid: Bool {
        guard version == 1, revision >= 0, projects.count <= LocalProjectLimits.maxProjects, Set(projects.map(\.id)).count == projects.count else { return false }
        return projects.allSatisfy { project in
            guard project.id.range(of: "^local:[A-Za-z0-9-]+$", options: .regularExpression) != nil,
                  project.id.count <= 100, Self.text(project.title, maximum: 200, required: true),
                  project.description.count <= 20_000, project.revision >= 0,
                  Self.text(project.createdAt, maximum: 50, required: true), Self.text(project.updatedAt, maximum: 50, required: true),
                  project.tasks.count <= LocalProjectLimits.maxTasksPerProject, Set(project.tasks.map(\.id)).count == project.tasks.count else { return false }
            return project.tasks.allSatisfy { task in
                task.id.range(of: "^local-task:[A-Za-z0-9-]+$", options: .regularExpression) != nil && task.id.count <= 100 &&
                Self.text(task.title, maximum: 500, required: true) && task.body.count <= 200_000 &&
                Self.statusIDs.contains(task.status) && Self.priorityIDs.contains(task.priority) &&
                Self.text(task.updatedAt, maximum: 50, required: true) && task.assignees.count <= 20 &&
                task.assignees.allSatisfy { Self.text($0, maximum: 100, required: true) } &&
                (task.start.isEmpty || ProjectSchedule.parseDay(task.start) != nil) &&
                (task.due.isEmpty || ProjectSchedule.parseDay(task.due) != nil) &&
                (task.start.isEmpty || task.due.isEmpty || task.start <= task.due)
            }
        }
    }
    private static func text(_ value: String, maximum: Int, required: Bool) -> Bool {
        value.count <= maximum && (!required || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

enum LocalProjectError: LocalizedError {
    case invalidData, stale, unavailable, item, busy, field, title, text, date, range, assignees, archived, storage
    var errorDescription: String? {
        switch self {
        case .invalidData: return String(localized: "Local project data is invalid. Your saved data has not been changed.")
        case .stale: return String(localized: "This local project changed. Refresh before saving.")
        case .unavailable: return String(localized: "This local project is unavailable.")
        case .item: return String(localized: "Select a local project item.")
        case .busy: return String(localized: "Local projects are still saving. Try again in a moment.")
        case .field: return String(localized: "Choose a supported local project field.")
        case .title: return String(localized: "A local project or task title is required.")
        case .text: return String(localized: "Local project text is too long.")
        case .date: return String(localized: "Enter a date as YYYY-MM-DD.")
        case .range: return String(localized: "The start date must be on or before the due date.")
        case .assignees: return String(localized: "Enter valid assignee names separated by commas.")
        case .archived: return String(localized: "Restore this task before editing it.")
        case .storage: return String(localized: "Local project storage could not be read.")
        }
    }
}
