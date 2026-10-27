import SwiftUI

/// An unreadable saved credential is different from a disconnected hosting account.
struct SavedAccountAccessNotice: View {
    let account: HostAccount
    var restored: () -> Void = {}
    @Environment(\.openSettings) private var openSettings
    @ViewState private var allowing = false
    @ViewState private var error: String?
    var body: some View {
        let accounts = AccountStore.shared
        VStack(alignment: .leading, spacing: 10) {
            Label("@" + account.username + " · " + account.host, systemImage: "person.crop.circle.badge.checkmark").font(.callout.weight(.medium))
            Text(accounts.savedAccessMessage(for: account)).font(.callout).foregroundStyle(.secondary)
            if accounts.credentialState(for: account) == .loading { ProgressView().controlSize(.small) }
            else {
                Button("Restore saved account access") {
                    guard !allowing else { return }; allowing = true; error = nil
                    Task {
                        defer { allowing = false }
                        do { try await accounts.allowStoredAccess(for: account); restored() }
                        catch { self.error = accounts.savedAccessErrorMessage(for: account, error: error) }
                    }
                }.disabled(allowing)
                if accounts.credentialState(for: account) == .unavailable { Button("Account settings…") { openSettings() } }
            }
            if allowing { ProgressView().controlSize(.small) }
            if let error { Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
