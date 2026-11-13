import SwiftUI

// An account's state where a row shows it. Each state has its own drawing: a shield for the organization's approval,
// a key for the system's and a warning for an expired sign-in; the lock is kept for an identity the repository's rules fix.
// (Windows: features/account-connection/ui/AccountStatusLabel.tsx)

private extension AccountStatus {
    var tone: StudioStyle.Tone { self == .signedIn ? .passed : self == .checking ? .neutral : .waiting }
}

/// A row's second line: the state's 12 pt icon and its words in the state's tone
struct AccountStatusLabel: View {
    let status: AccountStatus

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            SymbolIcon(status.symbol).font(.system(size: 12)).accessibilityHidden(true)
            Text(verbatim: status.title).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(status.tone.text)
        .accessibilityElement(children: .combine)
    }
}

/// The same state as a badge, where a row has room for one
struct AccountStatusPill: View {
    let status: AccountStatus

    var body: some View { StatusPill(title: status.title, symbol: status.symbol, tone: status.tone) }
}
