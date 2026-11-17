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

    /// One action sits on the right; when the credential can't be read at all, Account settings joins it below
    private var note: some View {
        let accounts = AccountStore.shared, state = accounts.credentialState(for: account)
        var actions: [NoticeAction] = []
        if state != .loading {
            actions.append(NoticeAction(title: String(localized: "Restore saved account access"), run: allow))
            if state == .unavailable { actions.append(NoticeAction(title: String(localized: "Account settings…")) { openSettings() }) }
        }
        return NoticeBlock(symbol: "key", title: String(localized: "Saved sign-in needs your approval"),
                           caption: error ?? accounts.savedAccessMessage(for: account), actions: actions, busy: allowing || state == .loading)
    }
}
