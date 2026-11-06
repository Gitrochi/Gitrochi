import AppKit
import SwiftUI

/// The Account page, as the redesign's Account board draws it: underline tabs for the Inbox, My work and the
/// organizations, one row that chooses the account and refreshes, then a list column with the selected item beside it.
/// Releases and Projects have pages of their own. (Windows: pages/repo/ui/AccountWorkspacePanel.tsx)
struct AccountWorkspacePanel: View {
    @Environment(RepoStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    @AppStorage("accountPageSection") private var section = "inbox"
    @ViewState private var inbox = AccountWorkModel(inbox: true)
    @ViewState private var work = AccountWorkModel(inbox: false)

    private static let sections = ["inbox", "myWork", "organizations"]
    /// A section saved by an older version (Releases, Projects) opens the inbox
    private var current: String { Self.sections.contains(section) ? section : "inbox" }
    private var accounts: [HostAccount] { AccountStore.shared.accounts }
    /// The chosen account, else the open repository's, else the first one: the rule the organizations already follow
    /// (RepoStore.hubAccount), so the three sections always show the same account
    private var account: HostAccount? {
        accounts.first { $0.id == store.hostingHub.selectedAccountID } ?? store.hostingAccount ?? accounts.first
    }
    private var gitlab: Bool { (account?.provider ?? store.target?.provider) == .gitlab }
    private var hubLocked: Bool { store.hostingHub.loading || store.hostingHub.detailLoading || store.hostingHub.busy }
    private var busy: Bool { current == "organizations" ? hubLocked : current == "myWork" ? work.busy : inbox.busy }

    var body: some View {
        VStack(spacing: 0) {
            tabs
            AccountStyle.rule
            if let account {
                toolbar(account)
                AccountStyle.rule
                Group {
                    switch current {
                    case "myWork": MyWorkPanel(model: work, account: account)
                    case "organizations": HostingHubPanel(store: store, section: .organizations, onClone: clone, embedded: true)
                    default: WorkInboxPanel(model: inbox, account: account)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                // blocked: nothing on this page works without an account, so its one action is filled
                AccountState(symbol: "person.crop.circle", title: String(localized: "No account"),
                             caption: String(localized: "Add a GitHub or GitLab account for pull requests, issues and CI. Commits work without one."),
                             action: String(localized: "Connect account…"), filled: true) { openSettings() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // the board's page is the white surface, not the window's grey
        .background(StudioStyle.surface)
    }

    // MARK: Sections

    private var tabs: some View {
        HStack(spacing: 4) {
            AccountTab(title: String(localized: "Inbox"), on: current == "inbox") { section = "inbox" }
            AccountTab(title: String(localized: "My work"), on: current == "myWork") { section = "myWork" }
            AccountTab(title: gitlab ? String(localized: "Groups") : String(localized: "Organizations"), on: current == "organizations") { section = "organizations" }
            Spacer(minLength: 8)
            if current == "inbox", let account {
                Button("Mark all as read") { Task { await inbox.readAll(account) } }
                    .buttonStyle(AccountTextButtonStyle())
                    .disabled(inbox.busy || inbox.unread.isEmpty)
            }
        }
        .padding(.leading, 8).padding(.trailing, 20)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Account sections")
    }

    // MARK: Account and refresh

    private func toolbar(_ account: HostAccount) -> some View {
        HStack(spacing: 10) {
            AccountMenu {
                ForEach(accounts) { other in
                    Button { choose(other.id) } label: {
                        if other.id == account.id { Label(Self.title(other), systemImage: "checkmark") } else { Text(verbatim: Self.title(other)) }
                    }
                }
                Divider()
                Button("Account settings…") { openSettings() }
            } label: {
                HStack(spacing: 6) {
                    HostingAvatar(name: account.name ?? account.username, username: account.username,
                                  avatarURL: account.avatarURL.flatMap(URL.init(string:)), size: 20)
                    Text(verbatim: Self.title(account)).font(.system(size: 13)).foregroundStyle(Color.primary).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(StudioStyle.Rail.icon)
                }
                .padding(.leading, 4).padding(.trailing, 12)
            }
            .accessibilityLabel("Account and server")
            .disabled(current == "organizations" && hubLocked)
            Button { refresh(account) } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(AccountIconButtonStyle())
                .help("Refresh").accessibilityLabel("Refresh")
                .disabled(busy)
            if busy { ProgressView().controlSize(.small) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private static func title(_ account: HostAccount) -> String { "\(account.host) · @\(account.username)" }

    /// Choosing here never changes the Git identity of a repository; the organizations reload through the hub
    private func choose(_ id: String) {
        if current == "organizations" { Task { await store.selectHubAccount(id) } } else { store.hostingHub.selectedAccountID = id }
    }

    private func refresh(_ account: HostAccount) {
        Task {
            switch current {
            case "organizations": await store.loadHostingHub()
            case "myWork": await work.load(account)
            default: await inbox.load(account)
            }
        }
    }

    private func clone(_ url: String) { store.sheet = .cloneURL(url) }
}

// MARK: Parts the sections share

extension View {
    /// The board's button: 28 pt tall, which is the system's large size, with the 6 pt corners that size no longer has
    func accountButtonSize() -> some View { controlSize(.large).buttonBorderShape(.roundedRectangle(radius: 6)) }
}

enum AccountStyle {
    /// The hairline of the board's 28 pt controls
    static let edge = Color.primary.opacity(0.16)
    static var rule: some View { Rectangle().fill(StudioStyle.border).frame(height: 1) }
}

/// The page's list and detail side by side: a fixed 312 pt list column and a hairline, as the board draws them.
/// Under 680 pt the list sits above the detail.
struct AccountSplit<Leading: View, Detail: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var detail: Detail

    var body: some View {
        GeometryReader { geometry in
            let stacked = geometry.size.width < 680
            // only the arrangement changes, so the list and the detail keep what is typed and selected in them
            let layout = stacked ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
            layout {
                leading
                    .frame(width: stacked ? nil : 312, height: stacked ? min(320, geometry.size.height * 0.5) : nil)
                    .frame(maxWidth: stacked ? .infinity : nil, maxHeight: stacked ? nil : .infinity)
                Rectangle().fill(StudioStyle.border).frame(width: stacked ? nil : 1, height: stacked ? 1 : nil)
                detail.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// An underline tab (docs/design.md, Controls): medium text, the current one darker with a 2 pt accent underline, so
/// labels never shift. Text is never in the accent.
struct AccountTab: View {
    let title: String
    let on: Bool
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(on ? Color.primary : StudioStyle.Tone.neutral.text)
                .padding(.horizontal, 12)
                .frame(height: 37)
                .overlay(alignment: .bottom) { Rectangle().fill(on ? Color.accentColor : Color.clear).frame(height: 2) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// docs/design.md, Controls: an empty or blocked state is a 24 pt grey icon, one 15 pt semibold line, one 12 pt
/// caption and one action, filled only when the state blocks the user.
struct AccountState: View {
    let symbol: String
    /// Grey unless the icon itself says the state (a warning, a failure); never the accent
    var tint: Color = StudioStyle.Rail.icon
    let title: String
    var caption: String?
    var action: String?
    var filled = false
    var perform: () -> Void = {}

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(tint).frame(height: 24).accessibilityHidden(true)
            Text(verbatim: title).font(.system(size: 15, weight: .semibold)).multilineTextAlignment(.center)
            if let caption {
                Text(verbatim: caption).font(.system(size: 12)).foregroundStyle(StudioStyle.Rail.icon)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 380)
            }
            if let action {
                Group {
                    if filled { Button(action, action: perform).buttonStyle(.borderedProminent) } else { Button(action, action: perform) }
                }
                .accountButtonSize()
                .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// A notice (docs/design.md, Selection): white with a hairline, never tinted, so a tint keeps meaning selection
struct AccountNotice<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.surface))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(StudioStyle.border))
    }
}

/// A 28 pt bordered control whose whole frame opens a menu. A borderless menu keeps only one icon and one text of
/// its label and puts the icon first, so this one is a plain button, which draws the label as it is laid out (as the
/// toolbar's menus do). The label brings its own padding.
struct AccountMenu<Items: View, MenuLabel: View>: View {
    /// Takes the width it is offered instead of the label's own
    var fills = false
    @ViewBuilder let items: Items
    @ViewBuilder let label: MenuLabel

    var body: some View {
        Menu { items } label: {
            label
                .frame(maxWidth: fills ? .infinity : nil, alignment: .leading)
                .frame(height: 28)
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: !fills, vertical: true)
        .background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.surface))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(AccountStyle.edge))
    }
}

/// The board's segmented filter: equal segments that fill the width, 12 pt medium labels, the chosen one a white
/// thumb. The system's segmented picker keeps its own width, so it cannot fill the list column.
struct AccountSegments<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let on = option.value == selection
                Button { selection = option.value } label: {
                    Text(verbatim: option.title)
                        .font(.system(size: 12, weight: .medium)).lineLimit(1)
                        .foregroundStyle(on ? Color.primary : StudioStyle.Tone.neutral.text)
                        .frame(maxWidth: .infinity).frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 4).fill(on ? Color(nsColor: .controlColor) : Color.clear)
                            .shadow(color: .black.opacity(on ? 0.12 : 0), radius: 1, y: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.Tone.neutral.fill))
        .accessibilityElement(children: .contain)
    }
}

/// The board's 28 pt icon button: a glyph in a hairline frame. Disabled it turns neutral instead of fading.
struct AccountIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(enabled ? Color.primary : StudioStyle.Rail.blocked)
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(enabled ? StudioStyle.surface : StudioStyle.Tone.neutral.fill.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(enabled ? AccountStyle.edge : StudioStyle.border))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// A text button: 12 pt medium in the caption grey, at least 24 pt tall. Disabled it is the neutral grey of
/// disabled text, not a faded one.
struct AccountTextButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(enabled ? AnyShapeStyle(StudioStyle.Rail.icon) : AnyShapeStyle(.secondary))
            .frame(minHeight: 24)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}
