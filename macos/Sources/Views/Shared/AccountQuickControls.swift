import SwiftUI

/// The toolbar's last item (docs/design.md, App shell): the 24 pt profile photo of the account this repository uses,
/// with a warning badge only while that account needs attention, opening the one account popover.
/// (Windows: widgets/toolbar/ui/AccountQuickControls.tsx)
struct AccountQuickControls: View {
    @Environment(RepoStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    @ViewState private var showing = false
    @ViewState private var sheet: AccountQuickSheet?
    @ViewState private var hovered = false
    private let accounts = AccountStore.shared

    private var account: HostAccount? { store.hostingAccount }
    /// In the order Settings lists them: GitHub first, then GitLab servers
    private var connected: [HostAccount] { accounts.accounts(for: .github) + accounts.accounts(for: .gitlab) }
    /// Without a repository account the photo is the account the Account page shows
    private var shown: HostAccount? {
        account ?? (store.target == nil ? connected.first { $0.id == store.hostingHub.selectedAccountID } ?? connected.first : nil)
    }
    private var badge: Bool { AccountPresentation.toolbarBadge(account.map { accounts.status(for: $0) }) }
    private var candidates: [HostAccount] { store.target.map { accounts.candidates(for: $0) } ?? [] }
    private var summary: String {
        let name = shown.map { "@\($0.username) · \($0.host)" } ?? String(localized: "No account")
        return badge ? name + "\n" + String(localized: "This repository's account needs attention") : name
    }

    var body: some View {
        // a credential that becomes readable, or stops being so, redraws the badge
        let _ = accounts.revision
        Button { showing.toggle() } label: {
            AccountButtonPhoto(account: shown, badge: badge)
                .frame(width: 36, height: 36)
                .background(Capsule().fill(Color.primary.opacity(showing || hovered ? 0.06 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel("Accounts")
        .accessibilityValue(Text(verbatim: summary))
        .help(summary)
        .popover(isPresented: $showing, arrowEdge: .bottom) { popover }
        .onChange(of: store.url) { _, _ in showing = false; sheet = nil }
        .sheet(item: $sheet) { request in
            switch request {
            case .add(let provider, let server):
                AddAccountSheet(provider: provider, server: server, signInWithBrowser: { sheet = .login(nil, .standard) }, onConnected: adopt)
            case .login(let expected, let capability):
                GitHubBrowserLoginSheet(expectedLogin: expected, capability: capability) { _, connected in adopt(connected) }
            }
        }
    }

    private var popover: some View {
        ScrollView {
            AccountPopover(repository: store.url == nil ? nil : AccountPopoverRepository(
                               target: store.target, account: account, candidates: candidates,
                               preferredID: accounts.preferredID(for: store.url?.path), identity: store.me,
                               managed: store.gitchStatus != nil, locked: store.gitchStatus?.lockedAccount != nil),
                           accounts: connected, status: { accounts.status(for: $0) },
                           actions: AccountPopoverActions(
                               choose: { store.useAccount($0) },
                               resolve: resolve,
                               inbox: { showing = false; store.navigate(.account) },
                               addAccount: { present(.add(store.target?.provider == .gitlab ? .gitlab : .github, nil)) },
                               manageAccounts: { showing = false; SettingsRoute.shared.tab = .accounts; openSettings() }))
        }
        .frame(maxHeight: 600)
    }

    /// A new or renewed account becomes this repository's when the repository has none, or it is the one in use
    private func adopt(_ connected: HostAccount) {
        if candidates.contains(where: { $0.id == connected.id }), account == nil || account?.id == connected.id {
            store.useAccount(connected)
        }
    }

    /// The system's approval happens in place; github.com accounts renew in the browser; a GitLab server takes a new
    /// token in the Add account sheet
    private func resolve(_ account: HostAccount, _ status: AccountStatus) {
        if status == .needsYourApproval {
            Task { try? await accounts.allowStoredAccess(for: account) }
        } else if account.provider == .github, account.host == "github.com" {
            present(.login(account.username, .standard))
        } else {
            present(.add(account.provider, account.server))
        }
    }

    private func present(_ request: AccountQuickSheet) { showing = false; sheet = request }
}

/// The button's picture: the profile photo, or the signed-out drawing, with the warning badge at its lower right
struct AccountButtonPhoto: View {
    let account: HostAccount?
    var badge = false

    var body: some View {
        Group {
            if let account {
                AccountAvatar(account: account, size: 24)
            } else {
                SymbolIcon("person.crop.circle").font(.system(size: 20)).foregroundStyle(HostedList.caption).frame(width: 24, height: 24)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if badge {
                Circle().fill(StudioStyle.Tone.waiting.text).frame(width: 12, height: 12)
                    .overlay(Text(verbatim: "!").font(.system(size: 9, weight: .bold)).foregroundStyle(Color(nsColor: .controlBackgroundColor)))
                    .overlay(Circle().stroke(Color(nsColor: .controlBackgroundColor), lineWidth: 1.5).padding(-0.75))
                    .offset(x: 3, y: 3)
                    .accessibilityHidden(true)
            }
        }
    }
}

private enum AccountQuickSheet: Identifiable {
    case add(Provider, String?)
    case login(String?, Gitch.GitHubLoginCapability)
    var id: String {
        switch self {
        case .add(let provider, let server): "add:\(provider.rawValue):\(server ?? "")"
        case .login(let expected, let capability): "login:\(expected ?? "new"):\(capability.rawValue)"
        }
    }
}
