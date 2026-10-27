import Foundation

/// The state of an issue or a pull/merge request as a word ("Open", not the verb "Open" of a button).
/// The lowercase keys keep the two apart in translations. (Windows: entities/hosting/lib/work-state.ts)
enum WorkState {
    static func title(_ state: String) -> String {
        switch state {
        case "open", "opened": return String(localized: "open").localizedCapitalized
        case "closed": return String(localized: "closed").localizedCapitalized
        case "merged": return String(localized: "merged").localizedCapitalized
        default: return state
        }
    }
}
