import SwiftUI

/// Search repositories on a connected GitHub or GitLab account and clone one; shown on the Home page
struct RemoteRepositorySearch: View {
    @Environment(RepoStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    @ViewState private var accountID = ""
    @ViewState private var query = ""
    @ViewState private var repos: [RemoteRepo] = []
    @ViewState private var busy = false
    @ViewState private var error: String?
    @ViewState private var page = 0
    @ViewState private var more = false
    @ViewState private var generation = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Repositories on a server").font(.headline)
                if AccountStore.shared.accounts.isEmpty {
                    Text("Connect a GitHub or GitLab account to search its repositories.").font(.caption).foregroundStyle(.secondary)
                    Button("Connect account…") { openSettings() }.controlSize(.small)
                } else {
                    Picker("Account and server", selection: $accountID) {
                        Text("Choose an account and server").tag("")
                        ForEach(AccountStore.shared.accounts) { a in Text("\(a.host) · @\(a.username)").tag(a.id) }
                    }.labelsHidden()
                    HStack(spacing: 6) {
                        TextField("Search remote repositories", text: $query).textFieldStyle(.roundedBorder)
                            .onSubmit { Task { await search() } }
                        Button("Search") { Task { await search() } }.disabled(accountID.isEmpty || busy)
                        if busy { ProgressView().controlSize(.small) }
                    }
                    Text("An empty search lists repositories you belong to.").font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            }
            .padding(16)
            if !repos.isEmpty || more {
                Divider()
                List {
                    ForEach(repos) { r in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.fullName).fontWeight(.medium).lineLimit(1)
                                Text(r.isPrivate ? "Private" : "Public").font(.caption).foregroundStyle(.secondary)
                                if let summary = r.summary { Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                            }
                            Spacer()
                            Button("Clone…") { store.sheet = .cloneURL(r.cloneURL) }.controlSize(.small)
                        }.padding(.vertical, 3)
                    }
                    if more { Button("Load more") { Task { await search(append: true) } }.disabled(busy) }
                }.listStyle(.sidebar)
            } else if page > 0, !busy {
                Text("No repositories found.").foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 12)
            }
        }
        .onChange(of: accountID) { _, _ in invalidate() }
        .onChange(of: query) { _, _ in invalidate() }
        .onChange(of: AccountStore.shared.revision) { _, _ in invalidate() }
        .onDisappear { generation = UUID() }
    }

    private func invalidate() {
        generation = UUID(); repos = []; page = 0; more = false; busy = false; error = nil
    }

    private func search(append: Bool = false) async {
        guard let a = AccountStore.shared.accounts.first(where: { $0.id == accountID }),
              let token = AccountStore.shared.token(for: a) else { return }
        let id = UUID()
        let revision = AccountStore.shared.revision
        generation = id
        busy = true
        error = nil
        defer { if generation == id { busy = false } }
        let c = ReviewAccess(target: RepoTarget(provider: a.provider, remote: "", host: a.host, path: ""),
                             token: token, apiBase: a.apiBase, me: a.username,
                             isCurrent: { generation == id && AccountStore.shared.revision == revision })
        do {
            let (items, next) = try await WorkspaceOperations.repositories(c, search: query, page: append ? page + 1 : 1)
            guard generation == id, c.isCurrent?() != false else { return }
            repos = append ? repos + items.filter { item in !repos.contains { $0.id == item.id } } : items
            more = next
            page = append ? page + 1 : 1
        } catch { if generation == id { self.error = error.localizedDescription } }
    }
}
