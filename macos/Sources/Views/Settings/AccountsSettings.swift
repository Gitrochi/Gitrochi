import SwiftUI
import AppKit

/// Settings › Accounts, as the Settings board draws it (docs/design.md, App shell): the hosting accounts and the Git
/// identities, each a bordered list of 52 pt rows under its title and add button. Accounts are added here or from the
/// account popover, with the same sheet, and removed only here.
/// (Windows: widgets/settings/ui/AccountsSettings.tsx)
struct AccountsSettings: View {
    private let accounts = AccountStore.shared
    @ViewState private var sheet: AccountsSettingsSheet?
    @ViewState private var removing: HostAccount?
    @ViewState private var identities: [Gitch.Account] = []

    /// GitHub first, then GitLab servers
    private var hosting: [HostAccount] { accounts.accounts(for: .github) + accounts.accounts(for: .gitlab) }

    var body: some View {
        // a credential that becomes readable, or stops being so, redraws the rows' states
        let _ = accounts.revision
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                section("Hosting accounts", action: "Add account…", identifier: "accounts-settings-add", run: { sheet = .add(.github, nil) }) {
                    if hosting.isEmpty {
                        note("Add a GitHub or GitLab account for pull requests, issues and CI. Commits work without one.")
                    }
                    ForEach(hosting) { account in
                        if account.id != hosting.first?.id { rule }
                        HostingAccountRow(account: account, status: accounts.status(for: account), busy: accounts.isBusy(account),
                                          failure: accounts.accessError(for: account), resolve: { resolve(account) }, present: { sheet = $0 },
                                          remove: { removing = account })
                    }
                }
                section("Git identities", action: "Add identity…", identifier: "accounts-settings-add-identity", run: { sheet = .identity(nil) }) {
                    if identities.isEmpty {
                        note("A Git identity is the author name, email and SSH key commits and pushes use.")
                    }
                    ForEach(identities) { identity in
                        if identity.id != identities.first?.id { rule }
                        GitIdentityRow(identity: identity) { sheet = .identity(identity.id) }
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    DesignIconImage(icon: .people, size: 13).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                    Text("An account used under several host labels (HTTPS, SSH on port 443) is listed once.")
                        .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(HostedList.caption)
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { identities = await Gitch.accounts() }
        .sheet(item: $sheet) { request in
            switch request {
            case .add(let provider, let server):
                AddAccountSheet(provider: provider, server: server, signInWithBrowser: { sheet = .login(nil, .standard) })
            case .login(let expected, let capability):
                GitHubBrowserLoginSheet(expectedLogin: expected, capability: capability) { _, _ in }
            case .identity(let id):
                GitchAccountSetupSheet(accountID: id) { Task { identities = await Gitch.accounts() } }
            }
        }
        // removing deletes the token, so it asks first
        .alert(Text("Remove @\(removing?.username ?? "")?"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { account in
            Button("Remove", role: .destructive) { accounts.disconnect(account) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Gitrochi forgets this account and deletes its token from the Keychain. Repositories that used it go back to another account on the same server, if there is one.")
        }
    }

    /// A 13 pt semibold title with its add button on the right, over one bordered list
    private func section<Rows: View>(_ title: LocalizedStringKey, action: LocalizedStringKey, identifier: String, run: @escaping () -> Void,
                                     @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button(action: run) {
                    HStack(spacing: 6) { DesignIconImage(icon: .plus, size: 13); Text(action).fontWeight(.medium) }
                }
                .buttonStyle(HostedListButtonStyle()).accessibilityIdentifier(identifier)
            }
            .frame(minHeight: 28)
            VStack(alignment: .leading, spacing: 0) { rows() }
                .background(RoundedRectangle(cornerRadius: 10).fill(StudioStyle.surface))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(StudioStyle.border))
        }
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(HostedList.caption).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
    }

    private var rule: some View { StudioStyle.border.frame(height: 1) }

    /// The system's approval and a second read happen in place, and the row says what went wrong; github.com accounts
    /// renew in the browser; a GitLab server takes a new token in the Add account sheet
    private func resolve(_ account: HostAccount) {
        let status = accounts.status(for: account)
        if status == .needsYourApproval || status == .unreadable {
            Task { await accounts.restoreAccess(for: account) }
        } else if account.provider == .github, account.host == "github.com" {
            sheet = .login(account.username, .standard)
        } else {
            sheet = .add(account.provider, account.server)
        }
    }
}

enum AccountsSettingsSheet: Identifiable {
    case add(Provider, String?)
    case login(String?, Gitch.GitHubLoginCapability)
    /// A Git identity's SSH setup, or a new identity
    case identity(String?)
    var id: String {
        switch self {
        case .add(let provider, let server): "add:\(provider.rawValue):\(server ?? "")"
        case .login(let expected, let capability): "login:\(expected ?? "new"):\(capability.rawValue)"
        case .identity(let id): "identity:\(id ?? "new")"
        }
    }
}

/// The ⋯ at a row's end: a 28 pt square with the 14 pt dots
private struct AccountRowMenu<Items: View>: View {
    @ViewBuilder let items: Items

    var body: some View {
        Menu { items } label: {
            DesignIconImage(icon: .more, size: 14).frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("More")
    }
}

/// One hosting account: its 24 pt photo, name and server, its state with the action that settles it, and ⋯ whose last
/// item removes it
struct HostingAccountRow: View {
    let account: HostAccount
    let status: AccountStatus
    var busy = false
    /// Why the last attempt to restore this account's saved sign-in failed
    var failure: String? = nil
    let resolve: () -> Void
    let present: (AccountsSettingsSheet) -> Void
    let remove: () -> Void

    private var gitHub: Bool { account.provider == .github && account.host == "github.com" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row
            // what went wrong sits right under the account it concerns
            if let failure {
                NoticeBlock(symbol: "xmark.circle.fill", tone: .failed, title: String(localized: "Couldn't use the saved sign-in"), caption: failure)
            }
        }
        .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 6)
        .frame(minHeight: 52)
    }

    private var row: some View {
        HStack(spacing: 10) {
            AccountAvatar(account: account, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "@" + account.username).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Text(verbatim: [account.host, account.name ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(HostedList.caption).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            AccountStatusPill(status: status)
            if busy {
                ProgressView().controlSize(.small)
            } else if let action = status.action {
                Button(action: resolve) { Text(verbatim: action).fontWeight(.medium) }.buttonStyle(HostedListButtonStyle()).fixedSize()
            }
            AccountRowMenu {
                if gitHub {
                    Button("Renew browser connection…") { present(.login(account.username, .standard)) }
                    Button("Connect project access…") { present(.login(account.username, .projects)) }
                }
                Button("Copy username") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(account.username, forType: .string)
                }
                Divider()
                Button("Remove account…", role: .destructive, action: remove)
            }
            .accessibilityLabel("More actions for \("@" + account.username)")
        }
    }
}

/// One Git identity: the photo of the hosting account it belongs to, its name and email, and where it is used
struct GitIdentityRow: View {
    let identity: Gitch.Account
    let connect: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            GitAccountAvatar(account: identity, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                (Text(verbatim: identity.id).fontWeight(.semibold) + Text(verbatim: identity.email.isEmpty ? "" : " <\(identity.email)>"))
                    .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Text(verbatim: [identity.hosts, identity.rules ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(HostedList.caption).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            AccountRowMenu {
                Button("Connect with SSH…", action: connect)
                Button("Copy email") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(identity.email, forType: .string)
                }.disabled(identity.email.isEmpty)
            }
            .accessibilityLabel("More actions for \(identity.id)")
        }
        .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 6)
        .frame(minHeight: 52)
    }
}
