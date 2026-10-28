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
    var predecessorIDs: [String]? = nil; var durationDays: Int? = nil
    enum CodingKeys: String, CodingKey { case id, title, body, status, start, due, priority, assignees, archived, updatedAt, predecessorIDs, durationDays }
}
extension LocalPlannerTask {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id); title = try container.decode(String.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body); status = try container.decode(String.self, forKey: .status)
        start = try container.decode(String.self, forKey: .start); due = try container.decode(String.self, forKey: .due)
        priority = try container.decode(String.self, forKey: .priority); assignees = try container.decode([String].self, forKey: .assignees)
        archived = try container.decode(Bool.self, forKey: .archived); updatedAt = try container.decode(String.self, forKey: .updatedAt)
        // Absence is an older document; explicit null or malformed values are corruption.
        predecessorIDs = container.contains(.predecessorIDs) ? try container.decode([String].self, forKey: .predecessorIDs) : nil
        durationDays = container.contains(.durationDays) ? try container.decode(Int.self, forKey: .durationDays) : nil
    }
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
            return LocalProjectDependencies.validate(project.tasks) == nil && project.tasks.allSatisfy { task in
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
    case invalidData, stale, unavailable, item, busy, field, title, text, date, range, assignees, archived, storage, dependencies, dependencyCycle, duration, dependentDeletion
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
        case .dependencies: return String(localized: "Choose up to 100 different predecessor tasks from this project, excluding this task.")
        case .dependencyCycle: return String(localized: "These predecessor links would create a cycle.")
        case .duration: return String(localized: "Enter a duration from 1 to 3650 whole days, or leave it empty.")
        case .dependentDeletion: return String(localized: "Remove predecessor links from dependent tasks before deleting this task.")
        }
    }
}

/// Windows: project-dependencies.ts. Iterative traversal also handles long local plans.
enum LocalProjectDependencies {
    struct Node: Identifiable {
        var row: HubProjectRow; var level: Int; var completed: Bool; var blockedBy: [String]; var critical = false
        var id: String { row.id }
    }
    struct Graph { var nodes: [Node]; var invalid = false; var durationDays: Int? = nil }

    static func validate(_ tasks: [LocalPlannerTask]) -> LocalProjectError? {
        if tasks.contains(where: { task in task.durationDays.map { $0 < 1 || $0 > 3650 } == true }) { return .duration }
        return validation(tasks.map(\.id), predecessors: Dictionary(tasks.map { ($0.id, $0.predecessorIDs ?? []) }, uniquingKeysWith: { first, _ in first }))
    }
    private static func validation(_ ids: [String], predecessors: [String: [String]]) -> LocalProjectError? {
        let all = Set(ids)
        guard all.count == ids.count else { return .dependencies }
        for id in ids {
            let values = predecessors[id] ?? []
            guard values.count <= 100, Set(values).count == values.count, !values.contains(id), values.allSatisfy({ all.contains($0) }) else { return .dependencies }
        }
        return order(ids, predecessors: predecessors).count == ids.count ? nil : .dependencyCycle
    }
    private static func order(_ ids: [String], predecessors: [String: [String]]) -> [String] {
        var remaining = Dictionary(uniqueKeysWithValues: ids.map { ($0, predecessors[$0]?.count ?? 0) }), successors: [String: [String]] = [:]
        for id in ids { for previous in predecessors[id] ?? [] { successors[previous, default: []].append(id) } }
        var queue = ids.filter { remaining[$0] == 0 }, index = 0
        while index < queue.count {
            for id in successors[queue[index]] ?? [] { remaining[id, default: 0] -= 1; if remaining[id] == 0 { queue.append(id) } }
            index += 1
        }
        return queue
    }
    static func graph(_ rows: [HubProjectRow]) -> Graph {
        let ids = rows.map(\.id), previous = Dictionary(rows.map { ($0.id, $0.predecessorIDs ?? []) }, uniquingKeysWith: { first, _ in first })
        guard validation(ids, predecessors: previous) == nil, !rows.contains(where: { $0.durationDays.map { $0 < 1 || $0 > 3650 } == true }) else { return Graph(nodes: [], invalid: true) }
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        func completed(_ id: String) -> Bool { byID[id]?.statuses["local-status"] == "local-done" }
        var levels: [String: Int] = [:]
        var nodes = order(ids, predecessors: previous).map { id -> Node in
            let predecessors = previous[id] ?? [], level = predecessors.isEmpty ? 0 : 1 + (predecessors.compactMap { levels[$0] }.max() ?? 0)
            levels[id] = level
            return Node(row: byID[id]!, level: level, completed: completed(id), blockedBy: predecessors.filter { !completed($0) })
        }
        let active = nodes.filter { !$0.completed && !$0.row.archived }, activeIDs = Set(active.map(\.id))
        guard !active.isEmpty, active.allSatisfy({ $0.row.durationDays != nil }),
              !active.contains(where: { $0.blockedBy.contains { byID[$0]?.archived == true } }) else { return Graph(nodes: nodes) }
        var earliest: [String: Int] = [:], duration = 0
        for node in nodes {
            guard activeIDs.contains(node.id) else { earliest[node.id] = 0; continue }
            let start = (previous[node.id] ?? []).compactMap { earliest[$0] }.max() ?? 0
            let finish = start + node.row.durationDays!
            earliest[node.id] = finish; duration = max(duration, finish)
        }
        var latest = Dictionary(uniqueKeysWithValues: active.map { ($0.id, duration) })
        for index in nodes.indices.reversed() {
            let node = nodes[index]
            guard activeIDs.contains(node.id) else { continue }
            let finish = latest[node.id]!, start = finish - node.row.durationDays!
            nodes[index].critical = finish == earliest[node.id]
            for id in previous[node.id] ?? [] where activeIDs.contains(id) { latest[id] = min(latest[id]!, start) }
        }
        return Graph(nodes: nodes, durationDays: duration)
    }
}
