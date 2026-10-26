import Foundation

/// Gitrochi was called Branchwork up to 0.3.5 (bundle ID com.ensnif.Branchwork).
/// On first launch carry its settings and data folder over; legacy keychain items remain readable without an automatic write.
enum LegacyData {
    static let bundleID = "com.ensnif.Branchwork"
    static let keychainService = bundleID
    private static let doneKey = "legacyDataMigrated"

    static func migrate() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        if let old = defaults.persistentDomain(forName: bundleID), let id = Bundle.main.bundleIdentifier {
            let current = defaults.persistentDomain(forName: id) ?? [:]
            for (key, value) in old where current[key] == nil { defaults.set(value, forKey: key) }
        }
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let from = support.appendingPathComponent("Branchwork"), to = support.appendingPathComponent("Gitrochi")
        if fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) { try? fm.moveItem(at: from, to: to) }
        defaults.set(true, forKey: doneKey)
    }
}
