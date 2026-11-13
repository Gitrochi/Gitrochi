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
    /// The Git account and its rules are being read again
    var refreshing = false
}

/// What the popover asks its owner to do; the owner closes the popover and opens the sheet or page
struct AccountPopoverActions {
    var choose: (HostAccount) -> Void = { _ in }
    /// Settle an account's state: renew it, approve it or sign in again
    var resolve: (HostAccount, AccountStatus) -> Void = { _, _ in }
    /// Read the repository's Git account and rules again
    var refreshIdentity: () -> Void = {}
    var inbox: () -> Void = {}
    var addAccount: () -> Void = {}
    var manageAccounts: () -> Void = {}
}

/// The account button's popover, as the Accounts board draws it (docs/design.md, App shell): this repository's account
/// with the reason it was chosen and Change…, the Git identity commits use, the other accounts, then Inbox,
/// Add account… and Manage accounts…. (Windows: widgets/toolbar/ui/AccountPopover.tsx)
struct AccountPopover: View {
    /// nil while no repository is open
    let repository: AccountPopoverRepository?
    let accounts: [HostAccount]
    let status: (HostAccount) -> AccountStatus
    /// A read of the saved sign-in, or its approval, is under way
    var busy: (HostAccount) -> Bool = { _ in false }
    /// Why the last attempt to restore the saved sign-in failed
    var failure: (HostAccount) -> String? = { _ in nil }
    let actions: AccountPopoverActions

    static let width: CGFloat = 360
    /// The board's #3a3a3c: an email beside a name, the lock beside it
    fileprivate static let strong = StudioStyle.Tone.neutral.text

    private var others: [HostAccount] { accounts.filter { $0.id != repository?.account?.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if accounts.isEmpty {
                if let repository {
                    heading(String(localized: "This repository"))
                    identity(repository)
                    divider
                }
                empty
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
                    ForEach(others) { account in AccountPopoverRow(account: account, status: status(account), busy: busy(account), failure: failure(account), resolve: actions.resolve) }
                }
                divider
                AccountPopoverAction(icon: .inbox, title: String(localized: "Inbox"), run: actions.inbox)
                AccountPopoverAction(icon: .plus, title: String(localized: "Add account…"), run: actions.addAccount)
                AccountPopoverAction(icon: .people, title: String(localized: "Manage accounts…"), run: actions.manageAccounts)
            }
        }
        .padding(.vertical, 6)
        .frame(width: Self.width, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Accounts")
    }

    /// The blocked state: a 24 pt grey icon, one 15 pt semibold line, one 12 pt caption and the one filled action
    private var empty: some View {
        VStack(spacing: 0) {
            DesignIconImage(icon: .account, size: 24).foregroundStyle(HostedList.caption)
            Text("No account").font(.system(size: 15, weight: .semibold)).padding(.top, 8)
            Text("Add a GitHub or GitLab account for pull requests, issues and CI. Commits work without one.")
                .font(.system(size: 12)).foregroundStyle(HostedList.caption).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            Button("Add account…", action: actions.addAccount).hostedListFilledButton().padding(.top, 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16).padding(.vertical, 20)
    }

    @ViewBuilder private func own(_ repository: AccountPopoverRepository) -> some View {
        if let account = repository.account { attention(account) }
        heading(String(localized: "This repository"))
        if let account = repository.account, let target = repository.target {
            let reason = AccountPresentation.reason(account: account, target: target, candidates: repository.candidates, preferredID: repository.preferredID)
            // the notice above carries this account's action, so the row keeps Change… only
            AccountPopoverRow(account: account, status: status(account), own: true, caption: reason.text, busy: busy(account), resolve: actions.resolve) {
                Menu {
                    Picker("Account for this repository", selection: Binding(get: { account.id }, set: { id in
                        if let next = repository.candidates.first(where: { $0.id == id }) { actions.choose(next) }
                    })) {
                        ForEach(repository.candidates) { next in Text(verbatim: "@\(next.username) · \(next.host)").tag(next.id) }
                    }
                    .pickerStyle(.inline).labelsHidden()
                    Divider()
                    Button("Add account…", action: actions.addAccount)
                    // the board has no button for it, so reading the Git account again sits in the menus
                    if repository.managed { Button("Refresh account status", action: actions.refreshIdentity).disabled(repository.refreshing) }
                } label: {
                    // drawn like the buttons beside it: a menu takes no custom button style
                    Text("Change…").font(.system(size: 13, weight: .medium)).padding(.horizontal, 12).frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.surface))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(HostedList.edge))
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .accessibilityIdentifier("account-popover-change")
            }
        } else if let target = repository.target {
            HStack(spacing: 10) {
                AccountPopoverGlyph(icon: .account)
                VStack(alignment: .leading, spacing: 2) {
                    Text("No account").font(.system(size: 13))
                    Text("Connect an account on \(target.host) to use repository services.").font(.system(size: 12)).foregroundStyle(HostedList.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14).padding(.vertical, 3).frame(minHeight: 52)
        }
        identity(repository)
    }

    /// This repository's own account needs the user: the notice on top, its one filled action under the words. It
    /// stays through the attempt, with a spinner, and afterwards says what went wrong.
    @ViewBuilder private func attention(_ account: HostAccount) -> some View {
        let state = status(account), working = busy(account), problem = failure(account)
        if state.action != nil || problem != nil {
            NoticeBlock(symbol: state == .signedIn ? "exclamationmark.triangle.fill" : state.symbol,
                        title: state == .needsYourApproval ? String(localized: "Saved sign-in needs your approval") : state.title,
                        caption: problem ?? (state == .needsYourApproval
                            ? String(localized: "macOS asks before Gitrochi uses the saved sign-in for @\(account.username). Your drafts are kept.") : state.caption),
                        actions: working ? [] : state.action.map { [NoticeAction(title: $0, filled: true) { actions.resolve(account, state) }] } ?? [],
                        busy: working, stacked: true)
                .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 6)
        }
    }

    /// The author commits in this repository carry; a lock beside the name and on the second line when the rules fix it
    private func identity(_ repository: AccountPopoverRepository) -> some View {
        HStack(spacing: 10) {
            AccountPopoverGlyph(icon: .identity)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Group {
                        if let identity = repository.identity, !(identity.name.isEmpty && identity.email.isEmpty) {
                            Text(verbatim: identity.name) + Text(verbatim: identity.email.isEmpty ? "" : " <\(identity.email)>").foregroundStyle(Self.strong)
                        } else {
                            Text("Not configured")
                        }
                    }
                    .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    if repository.locked { DesignIconImage(icon: .lock, size: 12).foregroundStyle(Self.strong) }
                }
                if repository.locked {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        DesignIconImage(icon: .lock, size: 12).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                        Text("Locked by this repository's rules").font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(HostedList.caption)
                    .accessibilityIdentifier("account-popover-locked")
                } else if repository.managed {
                    Text("Author and SSH follow this repository's rules").font(.system(size: 12)).foregroundStyle(HostedList.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14).padding(.vertical, 3).frame(minHeight: 48)
        .contentShape(Rectangle())
        .contextMenu {
            if repository.managed { Button("Refresh account status", action: actions.refreshIdentity).disabled(repository.refreshing) }
        }
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
/// in) or the state it is in. The repository's own row is 52 pt with a 32 pt photo and a semibold name, and leaves its
/// action to the notice above; the others are 44 pt with a 24 pt photo and carry their action. The words wrap; they
/// are never cut short.
struct AccountPopoverRow<Trailing: View>: View {
    let account: HostAccount
    let status: AccountStatus
    /// This repository's account
    var own = false
    var caption: String? = nil
    var busy = false
    /// Why the last attempt to restore this account's saved sign-in failed
    var failure: String? = nil
    let resolve: (HostAccount, AccountStatus) -> Void
    @ViewBuilder let trailing: Trailing

    private var service: String { account.provider == .gitlab ? String(localized: "Self-hosted GitLab") : account.provider.title }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row
            // what went wrong sits right under the account it concerns
            if !own, let failure {
                NoticeBlock(symbol: "xmark.circle.fill", tone: .failed, title: String(localized: "Couldn't use the saved sign-in"), caption: failure)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 3)
        .frame(minHeight: own ? 52 : 44)
        .accessibilityElement(children: .contain)
    }

    private var row: some View {
        HStack(spacing: 10) {
            AccountAvatar(account: account, size: own ? 32 : 24)
            VStack(alignment: .leading, spacing: 2) {
                (Text(verbatim: "@" + account.username).fontWeight(own ? .semibold : .regular) + Text(verbatim: " · " + account.host).foregroundStyle(HostedList.caption))
                    .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                if status == .signedIn {
                    Text(verbatim: caption ?? String(localized: "Signed in") + " · " + service).font(.system(size: 12)).foregroundStyle(HostedList.caption)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    AccountStatusLabel(status: status)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !own, busy {
                ProgressView().controlSize(.small)
            } else if !own, let action = status.action {
                Button { resolve(account, status) } label: { Text(verbatim: action).fontWeight(.medium) }.buttonStyle(HostedListButtonStyle()).fixedSize()
                    .accessibilityLabel(Text(verbatim: action + " @" + account.username))
            }
            trailing
        }
    }
}

extension AccountPopoverRow where Trailing == EmptyView {
    init(account: HostAccount, status: AccountStatus, own: Bool = false, caption: String? = nil, busy: Bool = false, failure: String? = nil,
         resolve: @escaping (HostAccount, AccountStatus) -> Void) {
        self.init(account: account, status: status, own: own, caption: caption, busy: busy, failure: failure, resolve: resolve) { EmptyView() }
    }
}

/// The 32 pt neutral round slot where a row has no photo
private struct AccountPopoverGlyph: View {
    let icon: DesignIcon

    var body: some View {
        Circle().fill(StudioStyle.canvas).frame(width: 32, height: 32)
            .overlay(DesignIconImage(icon: icon, size: 16).foregroundStyle(HostedList.caption))
            .accessibilityHidden(true)
    }
}

/// A 28 pt menu row with its 14 pt icon
private struct AccountPopoverAction: View {
    let icon: DesignIcon
    let title: String
    let run: () -> Void
    @ViewState private var hovered = false

    var body: some View {
        Button(action: run) {
            HStack(spacing: 8) {
                DesignIconImage(icon: icon, size: 14).foregroundStyle(HostedList.caption)
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
