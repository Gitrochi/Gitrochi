import AppKit
import SwiftUI

/// A full-width page body; pages carry no big title (the page list and the rail already name the page)
private struct WorkspacePage<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
private struct WorkspaceCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }.padding(18).frame(
            maxWidth: .infinity, alignment: .leading
        ).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10)).overlay(
            RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
    }
}
@MainActor func workspaceAccess(_ store: RepoStore) -> ReviewAccess? {
    guard var c = store.collaborationAccess else { return nil }
    let url = store.url
    let context = store.collaboration.contextID
    let revision = AccountStore.shared.revision
    let account = store.hostingAccount?.id
    c.isCurrent = {
        store.url == url && store.collaboration.contextID == context
            && AccountStore.shared.revision == revision && store.hostingAccount?.id == account
    }
    return c
}
private struct WorkspaceAccountNotice: View {
    @Environment(RepoStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        if let account = store.pendingCredentialAccount {
            WorkspaceCard { CredentialAccessNotice(account: account) }
        } else if store.collaborationAccess == nil {
            WorkspaceCard {
                Text(
                    store.target == nil
                        ? "Open a repository with a GitHub or GitLab remote to use this workspace."
                        : "Connect an account to load this workspace."
                ).foregroundStyle(.secondary)
                if store.target == nil {
                    Button("Open repository…") { store.presentOpenPanel() }
                } else {
                    Button("Connect account…") { openSettings() }
                }
            }
        }
    }
}
struct RepositoryWorkInboxPanel: View {
    @Environment(RepoStore.self) private var store
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkspaceAccountNotice()
            if store.target != nil {
                CollaborationInboxPanel(initialKind: "mention", embedded: true)
            }
        }.padding(24)
    }
}
@MainActor @Observable private final class MyWorkModel {
    var mine: [PullRequest] = []
    var reviews: [CollaborationInboxItem] = []
    var issues: [CollaborationInboxItem] = []
    var more = false
    var busy = false
    var error: String?
    var id = UUID()
    func load(_ store: RepoStore) async {
        let id = UUID()
        self.id = id
        mine = []
        reviews = []
        issues = []
        more = false
        error = nil
        guard let c = workspaceAccess(store) else { return }
        busy = true
        defer { if self.id == id { busy = false } }
        do {
            async let m = CollaborationAPI.requests(c, RequestQuery(scope: "mine"))
            async let r = CollaborationAPI.inbox(c, kind: "review", page: 1)
            async let i = CollaborationAPI.inbox(c, kind: "issue", page: 1)
            let (mp, rp, ip) = try await (m, r, i)
            guard self.id == id, c.isCurrent?() != false else { return }
            mine = mp.0
            reviews = rp.0
            issues = ip.0
            more = mp.1 || rp.1 || ip.1
        } catch { if self.id == id { self.error = error.localizedDescription } }
    }
}
struct RepositoryMyWorkPanel: View {
    @Environment(RepoStore.self) private var store
    @ViewState private var model = MyWorkModel()
    private var key: String {
        "\(store.url?.path ?? "")|\(store.collaboration.contextID)|\(AccountStore.shared.revision)|\(store.hostingAccount?.id ?? "")"
    }
    var body: some View {
        WorkspacePage {
            WorkspaceAccountNotice()
            HStack {
                Button("Refresh") { Task { await model.load(store) } }.disabled(model.busy)
                if model.busy { ProgressView().controlSize(.small) }
            }
            if let error = model.error { Text(error).foregroundStyle(.red) }
            WorkspaceCard {
                Text("My pull requests").font(.headline)
                ForEach(model.mine) { item in
                    HStack {
                        Text("#\(item.number) \(item.title)")
                        Spacer()
                        Button("Browser") { open(item.url) }
                    }
                }
                if model.mine.isEmpty, !model.busy {
                    Text("No items in this page.").foregroundStyle(.secondary)
                }
            }
            group("Review requested", model.reviews)
            group("Assigned issues", model.issues)
            if model.more {
                Text(
                    "This overview shows the first page. Open Pull requests or Issues to search and load more."
                ).font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: key) { await model.load(store) }
        .onDisappear { model.id = UUID() }
    }
    private func group(_ title: LocalizedStringKey, _ items: [CollaborationInboxItem]) -> some View
    {
        WorkspaceCard {
            Text(title).font(.headline)
            ForEach(items) { item in
                HStack {
                    Text("#\(item.number) \(item.title)")
                    Spacer()
                    Button("Browser") { open(item.url) }
                }
            }
            if items.isEmpty, !model.busy {
                Text("No items in this page.").foregroundStyle(.secondary)
            }
        }
    }
    private func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}
/// Issues: the shared issue list on the left, the selected issue on the right, like the Pull requests page
struct IssuesWorkspacePanel: View {
    @Environment(RepoStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        if store.target != nil {
            AdaptiveWorkbenchSplit(listWidth: 290) {
                ScrollView { IssueListSection(onPage: true).padding(.vertical, 6) }
                    .environment(\.sidebarFlyout, true)
                    .background(Color(nsColor: .windowBackgroundColor))
            } detail: {
                Group {
                    if let detail = store.collaboration.inboxDetail, detail.item.kind == "issue" {
                        IssueDetailView(detail: detail)
                    } else {
                        ContentUnavailableView("Select an issue", systemImage: "circle.dotted",
                                               description: Text("Search the list, then read the conversation and reply here."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        } else {
            VStack(spacing: 14) {
                ContentUnavailableView("No hosting remote", systemImage: "circle.dotted", description: Text("Open a repository with a GitHub or GitLab remote to use this workspace."))
                Button("Connect account…") { openSettings() }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
/// Actions: the runs on the left, the selected run with its jobs and a job's log on the right, like the Pull requests page
struct ActionsWorkspacePanel: View {
    @Environment(RepoStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        if store.target != nil {
            AdaptiveWorkbenchSplit(listWidth: 300) {
                CIPanel().background(Color(nsColor: .windowBackgroundColor))
            } detail: {
                Group {
                    if let p = store.ciPipelines.first(where: { $0.id == store.ciSelected }) {
                        CIRunDetailView(pipeline: p)
                    } else {
                        ContentUnavailableView("Select a run", systemImage: "bolt.horizontal.circle",
                                               description: Text("Choose a run to see its jobs and read their logs."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        } else {
            VStack(spacing: 14) {
                ContentUnavailableView("No hosting remote", systemImage: "bolt.horizontal.circle", description: Text("Open a repository with a GitHub or GitLab remote to use this workspace."))
                Button("Connect account…") { openSettings() }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
