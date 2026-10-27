import Foundation

/// Stores project identifiers only; absence and an explicitly empty portfolio are distinct.
enum ProjectPortfolioPreferences {
    private static func key(_ context: String) -> String { "projectPortfolioSelection.v1." + context }

    static func load(context: String, defaults: UserDefaults = .standard) -> Set<String>? {
        guard !context.isEmpty, let data = defaults.data(forKey: key(context)),
              let ids = try? JSONDecoder().decode([String].self, from: data),
              ids.allSatisfy({ !$0.isEmpty }) else { return nil }
        return Set(ids)
    }

    static func save(_ ids: Set<String>, context: String, defaults: UserDefaults = .standard) {
        guard !context.isEmpty, ids.allSatisfy({ !$0.isEmpty }),
              let data = try? JSONEncoder().encode(ids.sorted()) else { return }
        defaults.set(data, forKey: key(context))
    }
}
