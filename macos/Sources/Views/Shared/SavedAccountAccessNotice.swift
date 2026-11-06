import SwiftUI

/// An unreadable saved credential is different from a disconnected hosting account.
struct SavedAccountAccessNotice: View {
    let account: HostAccount
    /// The whole page is waiting on it: the blocked state of docs/design.md, not a note among other things
    var page = false
    var restored: () -> Void = {}
    @Environment(\.openSettings) private var openSettings
    @ViewState private var allowing = false
    @ViewState private var error: String?
    private func allow() {
        guard !allowing else { return }; allowing = true; error = nil
        Task {
            defer { allowing = false }
            do { try await AccountStore.shared.allowStoredAccess(for: account); restored() }
            catch { self.error = AccountStore.shared.savedAccessErrorMessage(for: account, error: error) }
        }
    }

    var body: some View {
        if page { pageState } else { note }
    }

    @ViewBuilder private var pageState: some View {
        let accounts = AccountStore.shared, state = accounts.credentialState(for: account)
        if state == .loading || allowing {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if state == .unavailable {
            HostedListEmpty(symbol: "key", title: String(localized: "Saved sign-in needs your approval"), caption: error ?? accounts.savedAccessMessage(for: account),
                            actionTitle: String(localized: "Account settings…"), filled: true) { openSettings() }
        } else {
            HostedListEmpty(symbol: "key", title: String(localized: "Saved sign-in needs your approval"),
                            caption: error ?? String(localized: "macOS asks before Gitrochi uses the saved sign-in for @\(account.username). Your drafts are kept."),
                            actionTitle: String(localized: "Approve…"), filled: true, action: allow)
        }
    }

    private var note: some View {
        let accounts = AccountStore.shared
        return VStack(alignment: .leading, spacing: 10) {
            Label("@" + account.username + " · " + account.host, symbol: "person.crop.circle.badge.checkmark").font(.callout.weight(.medium))
            Text(accounts.savedAccessMessage(for: account)).font(.callout).foregroundStyle(.secondary)
            if accounts.credentialState(for: account) == .loading { ProgressView().controlSize(.small) }
            else {
                Button("Restore saved account access", action: allow).disabled(allowing)
                if accounts.credentialState(for: account) == .unavailable { Button("Account settings…") { openSettings() } }
            }
            if allowing { ProgressView().controlSize(.small) }
            if let error { Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
