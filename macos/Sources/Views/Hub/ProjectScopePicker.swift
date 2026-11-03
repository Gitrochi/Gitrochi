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
        guard !loading, account.provider == .github, accountID == account.id else { return }
        let request = generation, nextPage = append ? page + 1 : 1
        loading = true; error = nil
        defer { if generation == request { loading = false } }
        var credential: String?
        do {
            credential = await AccountStore.shared.loadToken(for: account)
            guard !Task.isCancelled, generation == request else { return }
            guard let token = credential else { throw HostingHubAPI.fail(AccountStore.shared.savedAccessMessage(for: account)) }
            let access = HubAccess(target: HostingHubAPI.projectTarget(nil, provider: .github, host: account.host, username: account.username, personal: true), token: token, apiBase: account.apiBase, me: account.username, isCurrent: { self.generation == request })
            let result = try await HostingHubAPI.page(access, section: .organizations, page: nextPage, cursor: append ? cursor : nil)
            guard !Task.isCancelled, generation == request else { return }
            items = append ? items + result.items.filter { item in !items.contains { $0.id == item.id } } : result.items
            page = nextPage; cursor = result.cursor; more = result.more
        } catch {
            guard !Task.isCancelled, generation == request else { return }
            self.error = HostingHubAPI.error(error, token: credential)
        }
    }
}

/// The same owner menu is available in Projects, Home and project creation without a repository.
struct ProjectScopePicker: View {
    let account: HostAccount?
    let repositoryOwner: String?
    @Binding var selection: String
    @ViewState private var organizations = ProjectOrganizationCatalog()
    @ViewState private var enteringOrganization = false
    @ViewState private var organizationLogin = ""
    private var context: String { (account?.id ?? "") + "\0" + String(AccountStore.shared.revision) }
    private var title: String {
        if let organization = HostingHubAPI.projectOrganization(scope: selection) { return String(localized: "Organization: {0}").replacingOccurrences(of: "{0}", with: organization) }
        if selection == "repository", let repositoryOwner { return repositoryOwner }
        return String(localized: "My projects")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Menu {
                Button("My projects") { selection = "personal" }
                if let repositoryOwner { Button(repositoryOwner) { selection = "repository" } }
                Divider()
                Section("Organizations") {
                    ForEach(organizations.items) { organization in
                        Button(organization.title) { selection = "organization:" + organization.id }
                    }
                    if organizations.loading { Text("Loading organizations…") }
                    else if organizations.error != nil { Button("Retry organizations") { loadOrganizations(append: !organizations.items.isEmpty) } }
                    else if organizations.items.isEmpty { Text("No organizations found") }
                    if organizations.more { Button("Load more organizations") { loadOrganizations(append: true) }.disabled(organizations.loading) }
                }
                Button("Other organization…") { organizationLogin = ""; enteringOrganization = true }
            } label: {
                Text(title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityLabel("Project scope").accessibilityValue(title)
            .popover(isPresented: $enteringOrganization) {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Organization login", text: $organizationLogin).textFieldStyle(.roundedBorder)
                    Button("Open organization") {
                        guard let login = HostingHubAPI.projectOrganization(scope: "organization:" + organizationLogin.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
                        selection = "organization:" + login; enteringOrganization = false
                    }.disabled(HostingHubAPI.projectOrganization(scope: "organization:" + organizationLogin.trimmingCharacters(in: .whitespacesAndNewlines)) == nil)
                }.padding(16).frame(width: 260)
            }
            if organizations.error != nil {
                Text("Organizations could not be loaded. Your personal projects are still available.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .help(organizations.error ?? "")
            }
        }
        .task(id: context) {
            organizations.reset(account: account)
            if let account { await organizations.load(account) }
        }
        .onChange(of: account?.id) { old, new in
            if old != new, HostingHubAPI.projectOrganization(scope: selection) != nil { selection = "personal" }
        }
    }

    private func loadOrganizations(append: Bool = false) {
        guard let account else { return }
        Task { await organizations.load(account, append: append) }
    }
}
