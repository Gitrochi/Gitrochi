import SwiftUI

/// Where the saved account's keychain item stands, with the approval button next to the feature that needs it.
/// Draws nothing once the token is readable, so it can sit next to any account. Windows has no counterpart:
/// the Credential Manager never asks, so a missing token there is handled by the connect-account prompts.
struct CredentialAccessNotice: View {
    let account: HostAccount
    @ViewState private var allowing = false
    @ViewState private var failure: String?
    private let accounts = AccountStore.shared

    var body: some View {
        let state = accounts.credentialState(for: account)
        if state != .ready {
            NoticeBlock(symbol: "key", title: String(localized: "Saved sign-in needs your approval"), caption: caption(loading: state == .loading),
                        actions: [NoticeAction(title: String(localized: "Allow saved account access"), run: allow)],
                        busy: allowing || state == .loading)
        }
    }

    private func caption(loading: Bool) -> String {
        if let failure { return failure }
        if allowing { return String(localized: "Waiting for your macOS approval. You can continue using local Git tools.") }
        if loading { return String(localized: "Checking saved account access…") }
        return String(localized: "Allow access to the saved account to use repository services.")
    }

    private func allow() {
        allowing = true; failure = nil
        Task {
            do { try await accounts.allowStoredAccess(for: account) }
            catch { failure = AccountConnectionFailure.message(for: error) }
            allowing = false
        }
    }
}
