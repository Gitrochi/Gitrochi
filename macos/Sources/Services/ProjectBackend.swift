import Foundation

extension HostingHubAPI {
    static var localProjectStore = LocalProjectStore.shared

    /// Local predecessor edits retain the same captured context as other project writes.
    static func saveProjectDependencies(_ c: HubAccess, detail: HubDetail, row: HubProjectRow, predecessorIDs: [String], durationDays: Int?) async throws {
        guard try usesLocal(c, item: detail.item) else { throw fail(String(localized: "Predecessor planning is available for local projects.")) }
        _ = try await localProjectStore.setDependencies(detail: detail, row: row, predecessorIDs: predecessorIDs, durationDays: durationDays)
        try check(c)
    }

    /// A stale local action cannot accidentally use the selected GitHub account.
    static func usesLocal(_ c: HubAccess, item: HubItem) throws -> Bool {
        try check(c)
        let local = LocalProjectStore.isLocal(item) || item.id.hasPrefix("local:")
        guard c.local == local else { throw fail(String(localized: "Switch to the matching project workspace before saving.")) }
        return local
    }
}
