import Foundation

/// The same account/project preference is used by Home and the project workspace.
enum ProjectSchedulePreferences {
    private static func key(_ accountID: String, _ projectID: String) -> String {
        "projectSchedule.v1." + (projectID.hasPrefix("local:") ? "local" : accountID) + "." + projectID
    }
    static func load(accountID: String, projectID: String, defaults: UserDefaults = .standard) -> ProjectScheduleSettings {
        guard let data = defaults.data(forKey: key(accountID, projectID)),
              let settings = try? JSONDecoder().decode(ProjectScheduleSettings.self, from: data) else {
            return projectID.hasPrefix("local:") ? ProjectScheduleSettings(startFieldID: "local-start", dueFieldID: "local-due", statusFieldID: "local-status", completedOptionIDs: ["local-done"]) : .init()
        }
        return settings
    }
    static func save(_ settings: ProjectScheduleSettings, accountID: String, projectID: String, defaults: UserDefaults = .standard) {
        guard (!accountID.isEmpty || projectID.hasPrefix("local:")), !projectID.isEmpty, let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key(accountID, projectID))
    }
}
