import Foundation

/// A failed create must be reconciled even after the dialog or the application is reopened.
@MainActor enum ProjectCreationRecovery {
    struct Attempt { var title: String; var project: HubItem? }
    private static func key(_ account: HostAccount, owner: String) -> String {
        "projectCreationPending.v1." + account.id + "." + account.host.lowercased() + "." + owner.lowercased()
    }
    static func load(_ account: HostAccount, owner: String) -> Attempt? {
        guard let value = UserDefaults.standard.dictionary(forKey: key(account, owner: owner)), let title = value["title"] as? String else { return nil }
        let project = (value["id"] as? String).map { HubItem(id: $0, title: title, url: value["url"] as? String ?? "") }
        return Attempt(title: title, project: project)
    }
    static func save(_ account: HostAccount, owner: String, title: String, project: HubItem? = nil) {
        var value = ["title": title]
        if let project { value["id"] = project.id; value["url"] = project.url }
        UserDefaults.standard.set(value, forKey: key(account, owner: owner))
    }
    static func clear(_ account: HostAccount, owner: String) { UserDefaults.standard.removeObject(forKey: key(account, owner: owner)) }
}
