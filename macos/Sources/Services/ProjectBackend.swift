import Foundation

extension HostingHubAPI {
    static var localProjectStore = LocalProjectStore.shared

    /// A stale local action cannot accidentally use the selected GitHub account.
    static func usesLocal(_ c: HubAccess, item: HubItem) throws -> Bool {
        try check(c)
        let local = LocalProjectStore.isLocal(item) || item.id.hasPrefix("local:")
        guard c.local == local else { throw fail(String(localized: "Switch to the matching project workspace before saving.")) }
        return local
    }
}
