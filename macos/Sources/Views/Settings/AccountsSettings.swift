import SwiftUI
import AppKit

/// Settings › Accounts (docs/design.md, App shell): the hosting accounts and the Git identities, each listed once.
/// Accounts are added here or from the account popover, with the same sheet, and removed only here.
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
        Form {
            Section {
                if hosting.isEmpty {
                    Text("Add a GitHub or GitLab account for pull requests, issues and CI. Commits work without one.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(hosting) { account in
                    HostingAccountRow(account: account, status: accounts.status(for: account), busy: accounts.isBusy(account),
                                      failure: accounts.accessError(for: account), resolve: { resolve(account) }, present: { sheet = $0 },
                                      remove: { removing = account })
                }
            } header: {
                header("Hosting accounts", action: "Add account…", identifier: "accounts-settings-add") { sheet = .add(.github, nil) }
            }

            Section {
                if identities.isEmpty {
                    Text("A Git identity is the author name, email and SSH key commits and pushes use.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(identities) { identity in
                    GitIdentityRow(identity: identity) { sheet = .identity(identity.id) }
                }
            } header: {
                header("Git identities", action: "Add identity…", identifier: "accounts-settings-add-identity") { sheet = .identity(nil) }
            } footer: {
                Text("An account used under several host labels (HTTPS, SSH on port 443) is listed once.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Commit graph") {
                Toggle("Show author profile pictures", isOn: Binding(get: { AvatarStore.shared.enabled }, set: { AvatarStore.shared.enabled = $0 }))
                HStack {
                    Text("Looks for a GitHub profile, then a connected self-hosted GitLab profile, then Gravatar, and uses initials if none is found. An email hash is sent to Gravatar.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Download again") { AvatarStore.shared.refresh() }.controlSize(.small)
                }
            }

            Section {
                Text("Tokens are stored per account in the macOS Keychain and used to view and create PRs/MRs, list repositories, and authenticate HTTPS push and pull.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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

    private func header(_ title: LocalizedStringKey, action: LocalizedStringKey, identifier: String, run: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button(action: run) { Label(action, symbol: "plus") }.controlSize(.small).accessibilityIdentifier(identifier)
        }
    }

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

/// One hosting account: its photo, name and server, its state with the action that settles it, and ⋯ whose last item
/// removes it
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
    }

    private var row: some View {
        HStack(spacing: 10) {
            AccountAvatar(account: account, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "@" + account.username).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
                Text(verbatim: [account.host, account.name ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            AccountStatusPill(status: status)
            if busy {
                ProgressView().controlSize(.small)
            } else if let action = status.action {
                Button(action, action: resolve).fixedSize()
            }
            Menu {
                if gitHub {
                    Button("Renew browser connection…") { present(.login(account.username, .standard)) }
                    Button("Connect project access…") { present(.login(account.username, .projects)) }
                }
                Button("Copy username") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(account.username, forType: .string)
                }
                Divider()
                Button("Remove account…", role: .destructive, action: remove)
            } label: {
                SymbolIcon("ellipsis").frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("More actions for \("@" + account.username)")
            .help("More")
        }
    }
}

/// One Git identity: the photo of the hosting account it belongs to, its name and email, and where it is used
struct GitIdentityRow: View {
    let identity: Gitch.Account
    let connect: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            GitAccountAvatar(account: identity, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                (Text(verbatim: identity.id).fontWeight(.medium) + Text(verbatim: identity.email.isEmpty ? "" : " <\(identity.email)>").foregroundStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Text(verbatim: [identity.hosts, identity.rules ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                Button("Connect with SSH…", action: connect)
                Button("Copy email") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(identity.email, forType: .string)
                }.disabled(identity.email.isEmpty)
            } label: {
                SymbolIcon("ellipsis").frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("More actions for \(identity.id)")
            .help("More")
        }
    }
}
