import SwiftUI
import AppKit

/// The repository's pull/merge requests: in the repository sidebar, and as the list of the Pull requests page (onPage)
struct PullRequestSection: View {
    @Environment(RepoStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    @ViewState private var search = ""
    let target: RepoTarget
    var onPage = false

    private var filters: [(value: String, title: String)] {
        [("open", WorkState.title("open")), ("closed", WorkState.title("closed")), ("merged", WorkState.title("merged")),
         ("mine", String(localized: "Created by me")), ("reviewRequested", String(localized: "Review requested"))]
    }

    var body: some View {
        SidebarSection("pullRequests") {
            if !onPage {
                let query = store.collaboration.query
                if query.scope != "open" || !query.search.isEmpty {
                    ListFilterCaption(filter: filters.first { $0.value == query.scope }?.title ?? query.scope, search: query.search) {
                        search = ""
                        Task { await store.filterPullRequests(scope: "open", search: "") }
                    }
                }
            } else {
            ListSearchRow(prompt: target.provider == .gitlab ? String(localized: "Search merge requests") : String(localized: "Search pull requests"),
                          text: $search, filters: filters, selection: store.collaboration.query.scope, defaultFilter: "open",
                          onSearch: { Task { await store.filterPullRequests(scope: store.collaboration.query.scope, search: search) } },
                          onFilter: { scope in Task { await store.filterPullRequests(scope: scope, search: search) } })
                .onAppear { search = store.collaboration.query.search }
            }
            if let warning = store.collaboration.warning { Text(warning).font(.caption).foregroundStyle(.secondary) }
            switch store.prState {
            case .authorizationRequired:
                if let account = store.pendingCredentialAccount { CredentialAccessNotice(account: account) }
            case .needsAccount:
                // An account on this very host cannot be an alias for it, so only other servers are worth a try.
                let others = AccountStore.shared.accounts(for: target.provider).filter { $0.host != target.host }
                if let a = others.first {
                    Button("Try with the connected account (@\(a.username) · \(a.host))") { Task { await store.tryExistingAccounts() } }
                        .buttonStyle(.link)
                        .help("If the same server is used under another address, an account you've already connected works there too")
                }
                Button(target.provider == .gitlab ? "Connect a self-hosted GitLab (\(target.host)) account…" : "Connect a GitHub account…") { openSettings() }
                    .buttonStyle(.link)
            case .failed(let m):
                Text(m).font(.caption).foregroundStyle(.red).lineLimit(3)
            case .loading where store.pullRequests.isEmpty:
                ProgressView().controlSize(.small)
            case .loaded where store.pullRequests.isEmpty:
                Text(target.provider == .gitlab ? "No merge requests match this filter." : "No pull requests match this filter.")
                    .font(.callout).foregroundStyle(.secondary).sidebarRow()
            default:
                EmptyView()
            }
            ForEach(store.pullRequests) { pr in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text("#\(pr.number)").foregroundStyle(.secondary).monospacedDigit()
                        Text(pr.title).lineLimit(1)
                        if let sha = pr.headSHA, let ci = store.ciBySha[sha] {
                            CIStatusIcon(status: ci.status, size: 10)
                                .help("CI: \(ci.status.title) · #\(ci.number)")
                        }
                    }
                    HStack(spacing: 4) {
                        if pr.isDraft { Text("Draft").font(.caption2.weight(.semibold)).foregroundStyle(.orange) }
                        Text("\(pr.source) → \(pr.target)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .sidebarRow()
                .contentShape(Rectangle())
                .onTapGesture { store.select(.pullRequest(pr.number)) }
                .background(onPage && store.selection == .pullRequest(pr.number) ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .contextMenu {
                    if !onPage {
                        Button(target.provider == .gitlab ? "Open in Merge requests" : "Open in Pull requests") {
                            store.navigate(.pullRequests, prepare: false); store.select(.pullRequest(pr.number))
                        }
                        Divider()
                    }
                    Button("Check out branch") { Task { await store.checkoutPullRequest(pr) } }
                    Button("Open in browser") { if let u = URL(string: pr.url) { NSWorkspace.shared.open(u) } }
                    Button("Copy link") { store.copy(pr.url) }
                }
            }
            if store.collaboration.more { Button("Load more") { Task { await store.loadPullRequests(append: true) } }.disabled(store.prState == .loading) }
        } header: {
            HStack {
                Text(verbatim: store.prState == .loaded ? "\(target.provider.requestsTitle) \(store.pullRequests.count)" : target.provider.requestsTitle)
                Spacer()
                // the account for this repository is chosen in the toolbar's account control
                if !onPage {
                    Button { store.navigate(.pullRequests) } label: { Image(systemName: "arrow.up.forward.square") }
                        .buttonStyle(.borderless)
                        .help(target.provider == .gitlab ? "Open in Merge requests" : "Open in Pull requests")
                }
                if onPage {
                    Button { Task { await store.loadPullRequests() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Refresh list")
                }
                Button { store.sheet = .createPullRequest } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .disabled(store.headBranch == nil)
                    .help("New \(target.provider.requestShort) from the current branch")
            }
        }
    }
}
