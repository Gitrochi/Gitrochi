import SwiftUI

/// What the popover shows of the open repository
struct AccountPopoverRepository {
    /// The GitHub or GitLab remote, if the repository has one
    var target: RepoTarget?
    var account: HostAccount?
    /// The accounts Change… offers
    var candidates: [HostAccount] = []
    /// The account the user chose for this repository
    var preferredID: String?
    var identity: Identity?
    /// The repository's Git identity follows gitch's rules
    var managed = false
    var locked = false
}

/// What the popover asks its owner to do; the owner closes the popover and opens the sheet or page
struct AccountPopoverActions {
    var choose: (HostAccount) -> Void = { _ in }
    /// Settle an account's state: renew it, approve it or sign in again
    var resolve: (HostAccount, AccountStatus) -> Void = { _, _ in }
    var inbox: () -> Void = {}
    var addAccount: () -> Void = {}
    var manageAccounts: () -> Void = {}
}

/// The account button's popover (docs/design.md, App shell): this repository's account with the reason it was chosen
/// and Change…, the Git identity commits use, the other accounts, then Inbox, Add account… and Manage accounts….
/// (Windows: widgets/toolbar/ui/AccountPopover.tsx)
struct AccountPopover: View {
    /// nil while no repository is open
    let repository: AccountPopoverRepository?
    let accounts: [HostAccount]
    let status: (HostAccount) -> AccountStatus
    let actions: AccountPopoverActions

    static let width: CGFloat = 360

    private var others: [HostAccount] { accounts.filter { $0.id != repository?.account?.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if accounts.isEmpty {
                if let repository {
                    heading(String(localized: "This repository"))
                    identity(repository)
                    divider
                }
                HostedListEmpty(symbol: "person.crop.circle", title: String(localized: "No account"),
                                caption: String(localized: "Add a GitHub or GitLab account for pull requests, issues and CI. Commits work without one."),
                                actionTitle: String(localized: "Add account…"), filled: true, action: actions.addAccount)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if let repository { own(repository) } else {
                    heading(String(localized: "Accounts"))
                    Text("Open a repository to see which account it uses.").font(.system(size: 12)).foregroundStyle(HostedList.caption)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 14).padding(.bottom, 6)
                }
                if !others.isEmpty {
                    if repository != nil {
                        divider
                        heading(repository?.account == nil ? String(localized: "Accounts") : String(localized: "Other accounts"))
                    }
                    ForEach(others) { account in AccountPopoverRow(account: account, status: status(account), resolve: actions.resolve) }
                }
                divider
                AccountPopoverAction(symbol: "tray", title: String(localized: "Inbox"), run: actions.inbox)
                AccountPopoverAction(symbol: "plus", title: String(localized: "Add account…"), run: actions.addAccount)
                AccountPopoverAction(symbol: "gearshape", title: String(localized: "Manage accounts…"), run: actions.manageAccounts)
            }
        }
        .padding(.vertical, 6)
        .frame(width: Self.width, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Accounts")
    }

    @ViewBuilder private func own(_ repository: AccountPopoverRepository) -> some View {
        if let account = repository.account { attention(account) }
        heading(String(localized: "This repository"))
        if let account = repository.account, let target = repository.target {
            let reason = AccountPresentation.reason(account: account, target: target, candidates: repository.candidates, preferredID: repository.preferredID)
            // the notice above carries this account's action, so the row keeps Change… only
            AccountPopoverRow(account: account, status: status(account), size: 32, caption: reason.text, ownAction: false, resolve: actions.resolve) {
                Menu {
                    Picker("Account for this repository", selection: Binding(get: { account.id }, set: { id in
                        if let next = repository.candidates.first(where: { $0.id == id }) { actions.choose(next) }
                    })) {
                        ForEach(repository.candidates) { next in Text(verbatim: "@\(next.username) · \(next.host)").tag(next.id) }
                    }
                    .pickerStyle(.inline).labelsHidden()
                    Divider()
                    Button("Add account…", action: actions.addAccount)
                } label: {
                    // drawn like the buttons beside it: a menu takes no custom button style
                    Text("Change…").font(.system(size: 13)).padding(.horizontal, 12).frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.surface))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(HostedList.edge))
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .accessibilityIdentifier("account-popover-change")
            }
        } else if let target = repository.target {
            HStack(spacing: 10) {
                AccountPopoverGlyph(symbol: "person", size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("No account").font(.system(size: 13))
                    Text("Connect an account on \(target.host) to use repository services.").font(.system(size: 12)).foregroundStyle(HostedList.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14).padding(.vertical, 4).frame(minHeight: 52)
        }
        identity(repository)
    }

    /// This repository's own account needs the user: the shared notice, with the one action that settles it
    @ViewBuilder private func attention(_ account: HostAccount) -> some View {
        let state = status(account)
        if state == .needsYourApproval {
            SavedAccountAccessNotice(account: account, popover: true).padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 4)
        } else if let action = state.action {
            NoticeBlock(symbol: state.symbol, title: state.title, caption: state.caption,
                        actions: [NoticeAction(title: action) { actions.resolve(account, state) }])
                .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 4)
        }
    }

    /// The author commits in this repository carry, and whether the repository's rules fix it
    private func identity(_ repository: AccountPopoverRepository) -> some View {
        HStack(spacing: 10) {
            AccountPopoverGlyph(symbol: "person", size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Group {
                    if let identity = repository.identity, !(identity.name.isEmpty && identity.email.isEmpty) {
                        Text(verbatim: identity.name) + Text(verbatim: identity.email.isEmpty ? "" : " <\(identity.email)>").foregroundStyle(HostedList.caption)
                    } else {
                        Text("Not configured")
                    }
                }
                .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if repository.locked {
                    LockedLabel(text: String(localized: "Locked by this repository's rules"))
                } else if repository.managed {
                    Text("Author and SSH follow this repository's rules").font(.system(size: 12)).foregroundStyle(HostedList.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14).padding(.vertical, 4).frame(minHeight: 48)
        .accessibilityIdentifier("account-popover-identity")
    }

    private func heading(_ title: String) -> some View {
        Text(verbatim: title).font(.system(size: 11, weight: .semibold)).foregroundStyle(HostedList.caption)
            .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private var divider: some View { StudioStyle.border.frame(height: 1).padding(.horizontal, 14).padding(.vertical, 6) }
}

/// One account: its photo, "@name · host", and on the second line the caption (why it was chosen, or that it is signed
/// in) or the state it is in with the one action that settles it. The words wrap; they are never cut short.
struct AccountPopoverRow<Trailing: View>: View {
    let account: HostAccount
    let status: AccountStatus
    var size: CGFloat = 24
    var caption: String? = nil
    /// false where a notice above the row already carries the action
    var ownAction = true
    let resolve: (HostAccount, AccountStatus) -> Void
    @ViewBuilder let trailing: Trailing

    private var service: String { account.provider == .gitlab ? String(localized: "Self-hosted GitLab") : account.provider.title }

    var body: some View {
        HStack(spacing: 10) {
            AccountAvatar(account: account, size: size)
            VStack(alignment: .leading, spacing: 2) {
                (Text(verbatim: "@" + account.username).fontWeight(.semibold) + Text(verbatim: " · " + account.host).foregroundStyle(HostedList.caption))
                    .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                if status == .signedIn {
                    Text(verbatim: caption ?? String(localized: "Signed in") + " · " + service).font(.system(size: 12)).foregroundStyle(HostedList.caption)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    AccountStatusLabel(status: status)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if ownAction, let action = status.action {
                Button(action) { resolve(account, status) }.buttonStyle(HostedListButtonStyle()).fixedSize()
                    .accessibilityLabel(Text(verbatim: action + " @" + account.username))
            }
            trailing
        }
        .padding(.horizontal, 14).padding(.vertical, 4)
        .frame(minHeight: size > 24 ? 52 : 44)
        .accessibilityElement(children: .contain)
    }
}

extension AccountPopoverRow where Trailing == EmptyView {
    init(account: HostAccount, status: AccountStatus, size: CGFloat = 24, caption: String? = nil, ownAction: Bool = true,
         resolve: @escaping (HostAccount, AccountStatus) -> Void) {
        self.init(account: account, status: status, size: size, caption: caption, ownAction: ownAction, resolve: resolve) { EmptyView() }
    }
}

/// A neutral round slot where a row has no photo
private struct AccountPopoverGlyph: View {
    let symbol: String
    let size: CGFloat

    var body: some View {
        Circle().fill(StudioStyle.canvas).frame(width: size, height: size)
            .overlay(SymbolIcon(symbol).font(.system(size: 14)).foregroundStyle(HostedList.caption))
            .accessibilityHidden(true)
    }
}

/// A 28 pt menu row with its 14 pt icon
private struct AccountPopoverAction: View {
    let symbol: String
    let title: String
    let run: () -> Void
    @ViewState private var hovered = false

    var body: some View {
        Button(action: run) {
            HStack(spacing: 8) {
                SymbolIcon(symbol).font(.system(size: 13)).foregroundStyle(HostedList.caption).frame(width: 14)
                Text(verbatim: title).font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? StudioStyle.hover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .padding(.horizontal, 6)
    }
}
