import Foundation

struct ProjectTaskReference: Codable {
    var id: String
    var title: String
    var url: String
    var number: Int?
    var repository: String
    var host: String
}

/// Task links are saved only after successful branch creation, separately for each local repository.
enum ProjectTaskLinks {
    private static let key = "projectTaskBranches"
    static func remember(_ task: ProjectTaskReference, repositoryPath: String, branch: String, defaults: UserDefaults = .standard) {
        var saved = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([String: [String: ProjectTaskReference]].self, from: $0) } ?? [:]
        saved[repositoryPath, default: [:]][branch] = task
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: key) }
    }
    static func branches(taskID: String, repositoryPath: String, repository: String, host: String, defaults: UserDefaults = .standard) -> [String] {
        let saved = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([String: [String: ProjectTaskReference]].self, from: $0) } ?? [:]
        return (saved[repositoryPath] ?? [:]).filter { _, task in task.id == taskID && task.repository.caseInsensitiveCompare(repository) == .orderedSame && task.host.caseInsensitiveCompare(host) == .orderedSame }.keys.sorted()
    }
    static func task(repositoryPath: String, branch: String, repository: String, host: String, defaults: UserDefaults = .standard) -> ProjectTaskReference? {
        let saved = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([String: [String: ProjectTaskReference]].self, from: $0) } ?? [:]
        guard let task = saved[repositoryPath]?[branch], task.repository.caseInsensitiveCompare(repository) == .orderedSame, task.host.caseInsensitiveCompare(host) == .orderedSame else { return nil }
        return task
    }
    static func issueBranches(_ task: ProjectTaskReference, repositoryPath: String, defaults: UserDefaults = .standard) -> [String] {
        let saved = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([String: [String: ProjectTaskReference]].self, from: $0) } ?? [:]
        return (saved[repositoryPath] ?? [:]).filter { _, value in value.number == task.number && value.repository.caseInsensitiveCompare(task.repository) == .orderedSame && value.host.caseInsensitiveCompare(task.host) == .orderedSame }.keys.sorted()
    }

}
