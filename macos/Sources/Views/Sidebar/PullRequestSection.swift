import SwiftUI
import AppKit

/// Keep search and selection consistent between the branch sidebar and request workspace.
struct PullRequestSection: View {
    @AppStorage(SidebarSections.key) private var collapsed = ""
    let target: RepoTarget

    var body: some View {
        Section(isExpanded: SidebarSections.binding($collapsed, "pullRequests")) {
            PullRequestBrowser(target: target, compact: true)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
        } header: { Text(target.provider.requestsTitle) }
    }
}

struct PullRequestBrowser: View {
    @Environment(RepoStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    @ViewState private var search = ""
    let target: RepoTarget
    var compact = false
    private var loading: Bool { store.prState == .loading }
    private var selected: Int? { if case .pullRequest(let n)? = store.selection { return n }; return nil }

    var body: some View {
        VStack(spacing: 0) {
            controls.padding(compact ? 4 : 16)
            if !compact { Divider() }
            if compact { results }
            else {
                ScrollView { results.padding(10) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { search = store.collaboration.query.search }
        .onChange(of: store.collaboration.query.search) { _, value in search = value }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if !compact {
                    Text(target.provider.requestsTitle).font(.system(size: 16, weight: .semibold))
                    if store.prState == .loaded {
                        Text("\(store.pullRequests.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .padding(.horizontal, 7).padding(.vertical, 3).background(.quaternary, in: Capsule())
                    }
                }
                Spacer(minLength: 0)
                Button { Task { await store.loadPullRequests() } } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 22, height: 22)
                }.buttonStyle(.plain).disabled(loading).help("Refresh list").accessibilityLabel("Refresh list")
                Button { store.sheet = .createPullRequest } label: {
                    Image(systemName: "plus").frame(width: 22, height: 22)
                }.buttonStyle(.plain).disabled(store.headBranch == nil)
                    .help("New \(target.provider.requestShort) from the current branch").accessibilityLabel("New request")
            }
            if !compact { Text(target.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(target.path) }
            HStack(spacing: 8) {
                Picker("Request filter", selection: Binding(get: { store.collaboration.query.scope }, set: { scope in submit(scope) })) {
                    Text("Open requests").tag("open"); Text("Closed").tag("closed"); Text("Merged").tag("merged")
                    Text("Created by me").tag("mine"); Text("Review requested").tag("reviewRequested")
                }.labelsHidden().frame(maxWidth: .infinity).disabled(loading)
                accountMenu
            }
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search requests", text: $search).textFieldStyle(.plain).onSubmit { submit() }
                if !search.isEmpty {
                    Button { search = ""; submit() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help("Clear search").accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.09)))
            if loading && !store.pullRequests.isEmpty { ProgressView().controlSize(.small) }
        }
    }

    @ViewBuilder private var accountMenu: some View {
        if let current = store.hostingAccount {
            Menu {
                Text(current.host)
                ForEach(AccountStore.shared.candidates(for: target)) { a in
                    Button { store.useAccount(a) } label: {
                        if a.id == current.id { Label("@\(a.username)", systemImage: "checkmark") } else { Text("@\(a.username)") }
                    }
                }
                Divider(); Button("Add account…") { openSettings() }
            } label: { Image(systemName: "person.crop.circle").font(.system(size: 16)) }
                .menuStyle(.borderlessButton).fixedSize().help("@\(current.username) · \(current.host)")
                .accessibilityLabel("Account for this repository")
        }
    }

    private var results: some View {
        LazyVStack(alignment: .leading, spacing: 6) {
            if let warning = store.collaboration.warning {
                Label(warning, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary).padding(10)
            }
            stateView
            ForEach(store.pullRequests) { pr in
                Button { store.select(.pullRequest(pr.number)) } label: { requestRow(pr) }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected == pr.number ? .isSelected : [])
                    .contextMenu {
                        Button("Check out branch") { Task { await store.checkoutPullRequest(pr) } }
                        Button("Open in browser") { if let u = URL(string: pr.url) { NSWorkspace.shared.open(u) } }
                        Button("Copy link") { store.copy(pr.url) }
                    }
            }
            if store.collaboration.more { Button("Load more") { Task { await store.loadPullRequests(append: true) } }.disabled(loading).frame(maxWidth: .infinity).padding(8) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var stateView: some View {
        switch store.prState {
        case .needsAccount:
            VStack(alignment: .leading, spacing: 10) {
                Label("Connect an account", systemImage: "person.crop.circle.badge.plus").font(.callout.weight(.semibold))
                Text("Connect an account to load requests, comments and checks.").font(.caption).foregroundStyle(.secondary)
                if let a = AccountStore.shared.accounts(for: target.provider).first {
                    Button { Task { await store.tryExistingAccounts() } } label: {
                        Label("Use @\(a.username)", systemImage: "person.crop.circle").lineLimit(1)
                    }.help(a.host)
                }
                Button("Connect account…") { openSettings() }.buttonStyle(.borderedProminent)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                Label("Could not load requests", systemImage: "exclamationmark.circle").font(.callout.weight(.semibold))
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Button("Retry") { Task { await store.loadPullRequests() } }
            }.padding(14)
        case .loading where store.pullRequests.isEmpty:
            HStack { ProgressView().controlSize(.small); Text("Loading requests…").font(.callout).foregroundStyle(.secondary) }.padding(18)
        case .loaded where store.pullRequests.isEmpty:
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "tray").font(.title2).foregroundStyle(.tertiary)
                Text("No matching requests").font(.callout.weight(.semibold))
                Text("Try another filter or search.").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
        default: EmptyView()
        }
    }

    private func requestRow(_ pr: PullRequest) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: pr.isDraft ? "doc.text" : "arrow.triangle.pull")
                .foregroundStyle(pr.isDraft ? Color.secondary : store.collaboration.query.scope == "merged" ? .purple : .green)
                .frame(width: 16).padding(.top, 2)
            VStack(alignment: .leading, spacing: 7) {
                Text(pr.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary).lineLimit(compact ? 1 : 2)
                HStack(spacing: 5) {
                    Text("#\(pr.number)").monospacedDigit()
                    Text("· @\(pr.author)").lineLimit(1)
                    Spacer(minLength: 0)
                    if pr.isDraft { Text("Draft").font(.caption2.weight(.medium)).padding(.horizontal, 5).background(.quaternary, in: Capsule()) }
                    if let sha = pr.headSHA, let ci = store.ciBySha[sha] { CIStatusIcon(status: ci.status, size: 11).help(ci.status.title) }
                }.font(.caption).foregroundStyle(.secondary)
                if !compact {
                    Label("\(pr.source) → \(pr.target)", systemImage: "arrow.triangle.branch")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(compact ? 8 : 12)
        .background(selected == pr.number ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected == pr.number ? Color.accentColor.opacity(0.3) : .clear))
        .contentShape(Rectangle())
    }

    private func submit(_ scope: String? = nil) {
        Task { await store.filterPullRequests(scope: scope ?? store.collaboration.query.scope, search: search) }
    }
}
