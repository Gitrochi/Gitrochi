import Foundation

// What the account button, its popover and Settings › Accounts say about an account (docs/design.md, App shell).
// Windows: entities/hosting/lib/account-presentation.ts — the same rules, keep both in step.

/// What a hosting account needs from the user
enum AccountStatus: Hashable {
    case signedIn
    /// The organization asks to approve access again in the browser
    case needsApproval
    /// The system must allow the saved sign-in
    case needsYourApproval
    /// The token expired or was revoked
    case expired

    /// Which drawing a state uses: the states that need the user never share one
    var symbol: String {
        switch self {
        case .signedIn: "checkmark"
        case .needsApproval: "lock.shield"
        case .needsYourApproval: "key"
        case .expired: "exclamationmark.triangle.fill"
        }
    }

    var title: String {
        switch self {
        case .signedIn: String(localized: "Signed in")
        case .needsApproval: String(localized: "Needs approval")
        case .needsYourApproval: String(localized: "Needs your approval")
        case .expired: String(localized: "Sign-in expired")
        }
    }

    /// The one action that settles a state, or nil when there is nothing to do
    var action: String? {
        switch self {
        case .signedIn: nil
        case .needsApproval: String(localized: "Renew…")
        case .needsYourApproval: String(localized: "Approve…")
        case .expired: String(localized: "Sign in again…")
        }
    }

    /// What the state means, for the notice above this repository's account; nil where the title says it all
    var caption: String? {
        switch self {
        case .needsApproval: String(localized: "The organization asks to approve access again in the browser.")
        case .expired: String(localized: "The token expired or was revoked.")
        case .signedIn, .needsYourApproval: nil
        }
    }
}

/// Why a repository uses its account
enum AccountReason: Equatable {
    case chosen
    case matches(repository: String)
    case first(host: String)
    case sameServer(host: String)

    var text: String {
        switch self {
        case .chosen: String(localized: "Chosen for this repository")
        case .matches(let repository): String(localized: "Matches \(repository)")
        case .first(let host): String(localized: "First account on \(host)")
        case .sameServer(let host): String(localized: "Same server as \(host)")
        }
    }
}

enum AccountPresentation {
    /// The toolbar's warning badge: only when the open repository's own account needs attention. Another account that
    /// needs something is flagged inside the popover, and a window without a repository account has no badge.
    static func toolbarBadge(_ repositoryAccountStatus: AccountStatus?) -> Bool {
        guard let repositoryAccountStatus else { return false }
        return repositoryAccountStatus != .signedIn
    }

    /// The user's own choice comes first; then an account reached through another address of the same server; then the
    /// first of several accounts on the host; otherwise the only account that matches the repository's host.
    static func reason(account: HostAccount, target: RepoTarget, candidates: [HostAccount], preferredID: String?) -> AccountReason {
        if preferredID == account.id { return .chosen }
        if account.host != target.host { return .sameServer(host: target.host) }
        if candidates.count > 1 { return .first(host: target.host) }
        return .matches(repository: target.path)
    }

    /// The letter an account without a photo shows: from its name, else its username
    static func initial(name: String?, username: String) -> String {
        let name = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let source = name.isEmpty ? username.trimmingCharacters(in: .whitespacesAndNewlines) : name
        return source.first.map { String($0).uppercased() } ?? "?"
    }
}
