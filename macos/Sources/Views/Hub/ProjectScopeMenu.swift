import SwiftUI

/// One organization list per connected account, shared by the scope button and the strip that reports a failed read.
@MainActor @Observable final class ProjectScopeCatalogs {
    private(set) var byAccount: [String: ProjectOrganizationCatalog] = [:]

    func reset(_ accounts: [HostAccount]) {
        byAccount = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, ProjectOrganizationCatalog()) })
        for account in accounts { byAccount[account.id]?.reset(account: account) }
    }

    func failed(_ account: HostAccount?) -> Bool { account.flatMap { byAccount[$0.id]?.error } != nil }

    func load(_ account: HostAccount, append: Bool = false) async { await byAccount[account.id]?.load(account, append: append) }

    /// The accounts the page is not showing are read when the menu opens, not on every visit to the page.
    func loadMissing(_ accounts: [HostAccount]) {
        for account in accounts {
            guard let catalog = byAccount[account.id], !catalog.loaded, !catalog.loading, catalog.error == nil else { continue }
            Task { await catalog.load(account) }
        }
    }
}

/// The Projects page's scope button, as the redesign's Projects board draws it: whose projects are shown, with a menu of
/// every connected account, its own projects and its organizations. Local projects have no owner, so they get a fixed
/// label instead. (Windows: features/select-project-scope/ui/ProjectScopeMenu.tsx)
struct ProjectScopeMenu: View {
    @Bindable var store: RepoStore
    let catalogs: ProjectScopeCatalogs
    let locked: Bool
    @ViewState private var open = false
    @ViewState private var enteringOrganization = false
    @ViewState private var organizationLogin = ""
    @ViewState private var hovered: String?

    private var hub: HostingHubState { store.hostingHub }
    private var accounts: [HostAccount] { AccountStore.shared.accounts }
    private var account: HostAccount? { store.hubAccount }
    private var provider: Provider { account?.provider ?? .github }
    private var gitlab: Bool { provider == .gitlab }
    private var context: String { accounts.map(\.id).joined(separator: "\0") + "\0" + String(AccountStore.shared.revision) }
    private var scope: String { store.hubProjectEffectiveScope }
    private var organization: String? { HostingHubAPI.projectOrganization(scope: scope, provider: provider) }
    private var chosenOrganization: HubItem? {
        guard let organization, let account else { return nil }
        return catalogs.byAccount[account.id]?.items.first { $0.id.caseInsensitiveCompare(organization) == .orderedSame }
    }
    private var entered: String? { HostingHubAPI.projectOrganization(scope: "organization:" + organizationLogin.trimmingCharacters(in: .whitespacesAndNewlines), provider: provider) }
    private var title: String {
        if store.hubIsLocalProject { return String(localized: "This Mac") }
        if let organization { return chosenOrganization?.title ?? organization }
        if scope == "repository", let owner = store.hubProjectRepositoryLabel { return owner }
        return gitlab ? String(localized: "Choose a group") : String(localized: "My projects")
    }
    /// With several accounts the account leads, so it is the count that gives way when the line is short
    private var subtitle: String {
        let count = hub.loading && hub.items.isEmpty ? String(localized: "Loading…")
            : (hub.items.count == 1 && !hub.more ? String(localized: "1 project") : String(localized: "\(hub.items.count) projects") + (hub.more ? "+" : ""))
        guard !store.hubIsLocalProject, accounts.count > 1, let account else { return count }
        return "@" + account.username + " · " + count
    }

    var body: some View {
        Group {
            if store.hubIsLocalProject {
                label.frame(height: 40).accessibilityElement(children: .ignore).accessibilityLabel("Project scope").accessibilityValue(title + ", " + subtitle)
            } else {
                Button { enteringOrganization = false; open.toggle() } label: {
                    HStack(spacing: 8) {
                        label
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .medium)).foregroundStyle(StudioStyle.Rail.icon)
                    }
                    .padding(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 10))
                    .frame(width: accounts.count > 1 ? 280 : 240, height: 40)
                    .background(RoundedRectangle(cornerRadius: 8).fill(hovered == "scope" ? StudioStyle.hover : StudioStyle.surface))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.16)))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? "scope" : (hovered == "scope" ? nil : hovered) }
                .accessibilityLabel("Project scope").accessibilityValue(title + ", " + subtitle)
                .popover(isPresented: $open, arrowEdge: .bottom) {
                    if enteringOrganization { organizationForm } else { menu }
                }
            }
        }
        .task(id: context) {
            catalogs.reset(accounts)
            if let account, !store.hubIsLocalProject { await catalogs.load(account) }
        }
        .onChange(of: account?.id) { _, _ in
            if let account, catalogs.byAccount[account.id]?.loaded == false { Task { await catalogs.load(account) } }
        }
        .onChange(of: open) { _, shown in if shown { catalogs.loadMissing(accounts) } }
    }

    private var label: some View {
        HStack(spacing: 8) {
            if store.hubIsLocalProject {
                Image(systemName: "laptopcomputer").font(.system(size: 12)).foregroundStyle(StudioStyle.Tone.neutral.text)
                    .frame(width: 24, height: 24).background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.Tone.neutral.fill)).accessibilityHidden(true)
            } else if let organization {
                HostingAvatar(name: chosenOrganization?.title ?? organization, username: organization, avatarURL: chosenOrganization?.avatarURL, size: 24, style: .organization)
            } else if scope == "repository", let owner = store.hubProjectRepositoryOwner {
                HostingAvatar(name: owner, username: owner, size: 24, style: .organization)
            } else if let account {
                HostingAvatar(name: account.name ?? account.username, username: account.username, avatarURL: account.avatarURL.flatMap(URL.init(string:)), size: 24)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.tail)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(StudioStyle.Rail.icon).lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: store.hubIsLocalProject ? nil : .infinity, alignment: .leading)
        }
    }

    // MARK: Menu

    private var menu: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(accounts) { value in
                    section(value)
                    divider
                }
                action(key("Other organization…", group: "Other group…"), symbol: "building.2", id: "other") { organizationLogin = ""; enteringOrganization = true }
            }
            .padding(4)
        }
        .frame(width: 240)
        .frame(maxHeight: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func section(_ value: HostAccount) -> some View {
        let catalog = catalogs.byAccount[value.id], group = value.provider == .gitlab, several = accounts.count > 1
        if several { header("@" + value.username + " · " + value.host) }
        if !group {
            pick(String(localized: "My projects"), account: value, scope: "personal") {
                HostingAvatar(name: value.name ?? value.username, username: value.username, avatarURL: value.avatarURL.flatMap(URL.init(string:)), size: 20)
            }
        }
        if let owner = repositoryOwner(value) {
            pick(group ? store.target?.path ?? owner : owner, account: value, scope: "repository") {
                Image(systemName: "book.closed").font(.system(size: 12)).foregroundStyle(StudioStyle.Rail.icon)
            }
        }
        if !several { divider; header(group ? String(localized: "Groups") : String(localized: "Organizations")) }
        ForEach(catalog?.items ?? []) { item in
            pick(item.title, account: value, scope: "organization:" + item.id) {
                HostingAvatar(name: item.title, username: item.id, avatarURL: item.avatarURL, size: 20, style: .organization)
            }
        }
        if catalog?.loading == true {
            note(group ? "Loading…" : "Loading organizations…", loading: true)
        } else if catalog?.error != nil {
            action(group ? "Retry" : "Retry organizations", symbol: "arrow.clockwise", id: "retry:" + value.id) { Task { await catalogs.load(value, append: catalog?.items.isEmpty == false) } }
        } else if catalog?.loaded == true, catalog?.items.isEmpty == true {
            note(group ? "No groups found" : "No organizations found", loading: false)
        }
        if catalog?.more == true, catalog?.loading == false, catalog?.error == nil {
            action(group ? "Load more" : "Load more organizations", symbol: "arrow.down.to.line", id: "more:" + value.id) { Task { await catalogs.load(value, append: true) } }
        }
    }

    /// The owner of the open repository is offered only under the account that can reach it
    private func repositoryOwner(_ value: HostAccount) -> String? {
        guard let target = store.target, AccountStore.shared.candidates(for: target).contains(where: { $0.id == value.id }) else { return nil }
        return target.path.split(separator: "/").first.map(String.init)
    }

    private func pick<Icon: View>(_ title: String, account value: HostAccount, scope candidate: String, @ViewBuilder icon: () -> Icon) -> some View {
        let on = value.id == account?.id && candidate.caseInsensitiveCompare(scope) == .orderedSame, id = value.id + "\0" + candidate
        return Button {
            open = false
            Task { await store.selectHubProjectScope(candidate, account: value.id) }
        } label: {
            HStack(spacing: 8) {
                DesignIconImage(icon: .check, size: 11).opacity(on ? 1 : 0).frame(width: 13).accessibilityHidden(true)
                icon().frame(width: 20, height: 20)
                Text(title).font(.system(size: 13)).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
            }
            .modifier(ProjectScopeMenuRow(hovered: hovered == id))
        }
        .buttonStyle(.plain).disabled(locked)
        .onHover { hovered = $0 ? id : (hovered == id ? nil : hovered) }
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Retry and Load more keep the menu open: what they bring appears in it
    private func action(_ title: LocalizedStringKey, symbol: String, id: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 8) {
                Color.clear.frame(width: 13, height: 13)
                Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(StudioStyle.Rail.icon).frame(width: 20, height: 20).accessibilityHidden(true)
                Text(title).font(.system(size: 13)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }
            .modifier(ProjectScopeMenuRow(hovered: hovered == id))
        }
        .buttonStyle(.plain).disabled(locked)
        .onHover { hovered = $0 ? id : (hovered == id ? nil : hovered) }
    }

    private func note(_ title: LocalizedStringKey, loading: Bool) -> some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 13, height: 13)
            Group { if loading { ProgressView().controlSize(.small) } else { Color.clear } }.frame(width: 20, height: 20)
            Text(title).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 8).frame(height: 28).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func header(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(StudioStyle.Rail.icon).lineLimit(1).truncationMode(.middle)
            .padding(EdgeInsets(top: 6, leading: 29, bottom: 4, trailing: 8)).frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    /// A choice between two literals is a plain string unless its type says it is a key to translate
    private func key(_ organization: LocalizedStringKey, group: LocalizedStringKey) -> LocalizedStringKey { gitlab ? group : organization }

    private var divider: some View {
        Rectangle().fill(StudioStyle.border).frame(height: 1).padding(.horizontal, 6).padding(.vertical, 4)
    }

    private var organizationForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(key("Organization login", group: "Group path")).font(.system(size: 12)).foregroundStyle(StudioStyle.Rail.icon)
                TextField(key("Organization login", group: "Group path"), text: $organizationLogin).textFieldStyle(.roundedBorder).labelsHidden()
                    .onSubmit(openOrganization)
            }
            HStack {
                Spacer(minLength: 0)
                Button(key("Open organization", group: "Open"), action: openOrganization).disabled(entered == nil || locked)
            }
        }
        .padding(16).frame(width: 260)
    }

    private func openOrganization() {
        guard let login = entered, let account, !locked else { return }
        // The list's own spelling wins, so a typed login never looks like a second organization.
        let known = catalogs.byAccount[account.id]?.items.first { $0.id.caseInsensitiveCompare(login) == .orderedSame }?.id ?? login
        open = false; enteringOrganization = false
        Task { await store.selectHubProjectScope("organization:" + known, account: account.id) }
    }
}

/// A row of the scope menu: 28 pt tall, 8 pt at each side, with the hover fill every menu uses
private struct ProjectScopeMenuRow: ViewModifier {
    let hovered: Bool
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8).frame(height: 28).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? StudioStyle.hover : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// The strip under the scope row when the account's organizations could not be read: the page keeps working with the
/// user's own projects, so it says that and offers the retry.
struct ProjectScopeFailureStrip: View {
    let gitlab: Bool
    let retry: () -> Void
    private var lead: LocalizedStringKey { gitlab ? "Couldn't load groups." : "Couldn't load organizations." }
    private var caption: LocalizedStringKey { gitlab ? "Repository boards are still available." : "Your personal projects are still available." }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(StudioStyle.Tone.failed.text).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(lead).font(.system(size: 13, weight: .semibold))
                Text(caption).font(.system(size: 12)).foregroundStyle(StudioStyle.Rail.icon)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Retry", action: retry)
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 8))
        .background(RoundedRectangle(cornerRadius: 8).fill(StudioStyle.surface))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(StudioStyle.border))
        .accessibilityElement(children: .contain)
    }
}
