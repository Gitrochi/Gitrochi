import SwiftUI

/// Organization discovery has its own lifetime so a failed page never hides personal projects.
@MainActor @Observable private final class ProjectOrganizationCatalog {
    var items: [HubItem] = []
    var loading = false
    var more = false
    var error: String?
    private var page = 0
    private var cursor: String?
    private var generation = UUID()
    private var accountID = ""

    func reset(account: HostAccount?) {
        generation = UUID(); accountID = account?.id ?? ""
        items = []; loading = false; more = false; error = nil; page = 0; cursor = nil
    }

    func load(_ account: HostAccount, append: Bool = false) async {
        guard !loading, accountID == account.id else { return }
        let request = generation, nextPage = append ? page + 1 : 1
        loading = true; error = nil
        defer { if generation == request { loading = false } }
        var credential: String?
        do {
            credential = await AccountStore.shared.loadToken(for: account)
            guard !Task.isCancelled, generation == request else { return }
            guard let token = credential else { throw HostingHubAPI.fail(AccountStore.shared.savedAccessMessage(for: account)) }
            let access = HubAccess(target: HostingHubAPI.projectTarget(nil, provider: account.provider, host: account.host, username: account.username, personal: true), token: token, apiBase: account.apiBase, me: account.username, isCurrent: { self.generation == request })
            let result = try await HostingHubAPI.page(access, section: .organizations, page: nextPage, cursor: append ? cursor : nil)
            guard !Task.isCancelled, generation == request else { return }
            // A GitLab group is chosen by its full path, which also tells subgroups with the same name apart.
            let found = account.provider == .gitlab ? result.items.filter { !$0.subtitle.isEmpty }.map { item in var group = item; group.id = item.subtitle; group.title = item.subtitle; return group } : result.items
            items = append ? items + found.filter { item in !items.contains { $0.id == item.id } } : found
            page = nextPage; cursor = result.cursor; more = result.more
        } catch {
            guard !Task.isCancelled, generation == request else { return }
            self.error = HostingHubAPI.error(error, token: credential)
        }
    }
}

/// The same owner menu is available in Projects, Home and project creation without a repository.
/// GitLab accounts choose between the open repository and their groups, since GitLab has no personal boards.
struct ProjectScopePicker: View {
    let account: HostAccount?
    let repositoryOwner: String?
    @Binding var selection: String
    @ViewState private var organizations = ProjectOrganizationCatalog()
    @ViewState private var enteringOrganization = false
    @ViewState private var organizationLogin = ""
    private var context: String { (account?.id ?? "") + "\0" + String(AccountStore.shared.revision) }
    private var provider: Provider { account?.provider ?? .github }
    private var gitlab: Bool { provider == .gitlab }
    private var entered: String? { HostingHubAPI.projectOrganization(scope: "organization:" + organizationLogin.trimmingCharacters(in: .whitespacesAndNewlines), provider: provider) }
    private var title: String {
        if let organization = HostingHubAPI.projectOrganization(scope: selection, provider: provider) { return (gitlab ? String(localized: "Group: {0}") : String(localized: "Organization: {0}")).replacingOccurrences(of: "{0}", with: organization) }
        if selection == "repository", let repositoryOwner { return repositoryOwner }
        return gitlab ? String(localized: "Choose a group") : String(localized: "My projects")
    }
    private func text(_ github: LocalizedStringKey, gitlab: LocalizedStringKey) -> LocalizedStringKey { self.gitlab ? gitlab : github }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Menu {
                if !gitlab { Button("My projects") { selection = "personal" } }
                if let repositoryOwner { Button(repositoryOwner) { selection = "repository" } }
                Divider()
                Section(text("Organizations", gitlab: "Groups")) {
                    ForEach(organizations.items) { organization in
                        Button(organization.title) { selection = "organization:" + organization.id }
                    }
                    if organizations.loading { Text(text("Loading organizations…", gitlab: "Loading…")) }
                    else if organizations.error != nil { Button(text("Retry organizations", gitlab: "Retry")) { loadOrganizations(append: !organizations.items.isEmpty) } }
                    else if organizations.items.isEmpty { Text(text("No organizations found", gitlab: "No groups found")) }
                    if organizations.more { Button(text("Load more organizations", gitlab: "Load more")) { loadOrganizations(append: true) }.disabled(organizations.loading) }
                }
                Button(text("Other organization…", gitlab: "Other group…")) { organizationLogin = ""; enteringOrganization = true }
            } label: {
                Text(title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityLabel("Project scope").accessibilityValue(title)
            .popover(isPresented: $enteringOrganization) {
                VStack(alignment: .leading, spacing: 12) {
                    TextField(text("Organization login", gitlab: "Group path"), text: $organizationLogin).textFieldStyle(.roundedBorder)
                    Button(text("Open organization", gitlab: "Open")) {
                        guard let login = entered else { return }
                        selection = "organization:" + login; enteringOrganization = false
                    }.disabled(entered == nil)
                }.padding(16).frame(width: 260)
            }
            if organizations.error != nil {
                Text(text("Organizations could not be loaded. Your personal projects are still available.", gitlab: "Groups could not be loaded. Repository boards are still available."))
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .help(organizations.error ?? "")
            }
        }
        .task(id: context) {
            organizations.reset(account: account)
            if let account { await organizations.load(account) }
        }
        .onChange(of: account?.id) { old, new in
            if old != new, selection.hasPrefix("organization:") { selection = "personal" }
        }
    }

    private func loadOrganizations(append: Bool = false) {
        guard let account else { return }
        Task { await organizations.load(account, append: append) }
    }
}
