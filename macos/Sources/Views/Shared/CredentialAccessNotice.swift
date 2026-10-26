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
            VStack(alignment: .leading, spacing: 8) {
                if state == .loading && !allowing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Checking saved account access…").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Allow access to the saved account to use repository services.").font(.caption).foregroundStyle(.secondary)
                }
                if allowing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for your macOS approval. You can continue using local Git tools.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("Allow saved account access") { allow() }.disabled(allowing)
                if let failure { Text(failure).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            }
            .accessibilityElement(children: .contain)
        }
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
