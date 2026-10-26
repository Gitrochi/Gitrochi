import AppKit
import SwiftUI

struct WorkInboxPanel: View {
    @Environment(RepoStore.self) private var store
    @ViewState private var scope = "repository"
    private var effectiveScope: String { store.target == nil ? "account" : scope }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Work scope", selection: Binding(get: { effectiveScope }, set: { scope = $0 })) {
                Text("Current repository").tag("repository")
                Text("Selected account · all repositories").tag("account")
            }.pickerStyle(.segmented).padding([.horizontal, .top], 20)
            if effectiveScope == "account" {
                AccountWorkPanel(inbox: true)
            } else {
                RepositoryWorkInboxPanel()
            }
        }
    }
}
struct MyWorkPanel: View {
    @Environment(RepoStore.self) private var store
    @ViewState private var scope = "repository"
    private var effectiveScope: String { store.target == nil ? "account" : scope }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Work scope", selection: Binding(get: { effectiveScope }, set: { scope = $0 })) {
                Text("Current repository").tag("repository")
                Text("Selected account · all repositories").tag("account")
            }.pickerStyle(.segmented).padding([.horizontal, .top], 20)
            if effectiveScope == "account" {
                AccountWorkPanel(inbox: false)
            } else {
                RepositoryMyWorkPanel()
            }
        }
    }
}
private struct AccountWorkPanel: View {
    @Environment(\.openSettings) private var openSettings
    let inbox: Bool
    @ViewState private var accountID = ""
    @ViewState private var kind = "mine"
    @ViewState private var items: [AccountWorkItem] = []
    @ViewState private var page = 0
    @ViewState private var more = false
    @ViewState private var busy = false
    @ViewState private var error: String?
    @ViewState private var generation = UUID()
    private var account: HostAccount? { AccountStore.shared.accounts.first { $0.id == accountID } }
    private var key: String { "\(accountID)|\(kind)|\(AccountStore.shared.revision)" }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(inbox ? "Inbox" : "My work").font(.largeTitle.bold())
                Text(
                    "Account scope uses the explicitly selected server and account. Repository Git identity stays unchanged."
                ).font(.callout).foregroundStyle(.secondary)
                HStack {
                    Picker(
                        "Account and server",
                        selection: Binding(
                            get: { accountID },
                            set: { value in
                                generation = UUID()
                                items = []
                                page = 0
                                more = false
                                busy = false
                                error = nil
                                accountID = value
                            })
                    ) {
                        Text("Choose an account and server").tag("")
                        ForEach(AccountStore.shared.accounts) { a in
                            Text("\(a.server) · @\(a.username)").tag(a.id)
                        }
                    }.frame(maxWidth: 430)
                    Button("Refresh") { Task { await load() } }.disabled(account == nil || busy)
                    if busy { ProgressView().controlSize(.small) }
                }
                if let account {
                    Text(
                        account.provider == .gitlab
                            ? "GitLab inbox shows pending To-Dos. Review requests depend on server version and permissions."
                            : "GitHub inbox shows notifications. My work searches open requests and issues across accessible repositories."
                    ).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Select an account to load work across its repositories.").foregroundStyle(
                        .secondary)
                }
                if AccountStore.shared.accounts.isEmpty {
                    Button("Connect account…") { openSettings() }
                }
                if let account, AccountStore.shared.awaitsAccess(account) { CredentialAccessNotice(account: account) }
                if !inbox {
                    Picker("Work category", selection: $kind) {
                        Text("Authored requests").tag("mine")
                        Text("Assigned requests").tag("assignedRequests")
                        Text("Review requested").tag("review")
                        Text("Assigned issues").tag("issues")
                        Text("Authored issues").tag("myIssues")
                    }.pickerStyle(.segmented).disabled(busy)
                }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                ForEach(items) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(
                                "\(item.unread ? "● ":"")\(item.number>0 ? "#\(item.number) ":"")\(item.title)"
                            ).font(.headline)
                            Text(
                                "\(item.host)/\(item.repository) · \(item.state)\(item.author.isEmpty ? "":" · @"+item.author)"
                            ).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if item.unread, item.readID != nil {
                            Button("Mark as read") { Task { await read(item) } }.disabled(busy)
                        }
                        if let url = URL(string: item.url) {
                            Link("Open details in browser", destination: url)
                        }
                    }.padding(12).background(
                        .quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                }
                if account != nil, page > 0, items.isEmpty, !busy {
                    Text("No items in this page.").foregroundStyle(.secondary)
                }
                if more { Button("Load more") { Task { await load(append: true) } }.disabled(busy) }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }.task(id: key) {
            generation = UUID()
            items = []
            page = 0
            more = false
            busy = false
            error = nil
            if account != nil { await load() }
        }.onDisappear { generation = UUID() }
    }
    private func access(_ id: UUID) -> ReviewAccess? {
        guard let a = account, let token = AccountStore.shared.token(for: a) else { return nil }
        let revision = AccountStore.shared.revision
        return ReviewAccess(
            target: RepoTarget(provider: a.provider, remote: "", host: a.host, path: ""),
            token: token, apiBase: a.apiBase, me: a.username,
            isCurrent: {
                generation == id && AccountStore.shared.revision == revision && accountID == a.id
            })
    }
    private func load(append: Bool = false) async {
        let id = UUID()
        generation = id
        guard let c = access(id) else { return }
        busy = true
        error = nil
        defer { if generation == id { busy = false } }
        do {
            let (next, hasMore) = try await AccountWorkAPI.page(
                c, kind: inbox ? "inbox" : kind, page: append ? page + 1 : 1, accountID: accountID)
            guard generation == id, c.isCurrent?() != false else { return }
            items =
                append ? items + next.filter { item in !items.contains { $0.id == item.id } } : next
            page = append ? page + 1 : 1
            more = hasMore
        } catch { if generation == id { self.error = error.localizedDescription } }
    }
    private func read(_ item: AccountWorkItem) async {
        guard !busy else { return }
        let id = UUID()
        generation = id
        guard let c = access(id) else { return }
        busy = true
        error = nil
        defer { if generation == id { busy = false } }
        do {
            try await AccountWorkAPI.read(c, item: item, accountID: accountID)
            guard generation == id, c.isCurrent?() != false else { return }
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index].unread = false
            }
        } catch { if generation == id { self.error = error.localizedDescription } }
    }
}

/// Everything that belongs to the account rather than the repository, on one page: the inbox and work lists,
/// and the hub's releases, projects and organizations
struct AccountWorkspacePanel: View {
    @Environment(RepoStore.self) private var store
    @AppStorage("accountPageSection") private var section = "inbox"

    var body: some View {
        let gitlab = store.target?.provider == .gitlab
        VStack(spacing: 0) {
            Picker("Section", selection: $section) {
                Text("Inbox").tag("inbox")
                Text("My work").tag("myWork")
                Text("Releases").tag("releases")
                Text("Projects").tag("projects")
                Text(gitlab ? "Groups" : "Organizations").tag("organizations")
            }
            .pickerStyle(.segmented).labelsHidden()
            .frame(maxWidth: 640)
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 10)
            Divider()
            Group {
                switch section {
                case "myWork": MyWorkPanel()
                case "releases": HostingHubPanel(store: store, section: .releases, onClone: clone)
                case "projects": HostingHubPanel(store: store, section: .projects, onClone: clone)
                case "organizations": HostingHubPanel(store: store, section: .organizations, onClone: clone)
                default: WorkInboxPanel()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func clone(_ url: String) { store.sheet = .cloneURL(url) }
}
