import SwiftUI
import AppKit

/// Issues keep the local branch handoff alongside server-reported request links.
struct IssueDevelopmentPanel: View {
    @Environment(RepoStore.self) private var store
    let item: CollaborationInboxItem
    @ViewState private var requests: [IssueLinkedRequest] = []
    @ViewState private var page = 0
    @ViewState private var more = false
    @ViewState private var loading = false
    @ViewState private var error: String?
    private var context: String { [store.url?.path ?? "", store.target?.host ?? "", store.target?.path ?? "", store.hostingAccount?.id ?? "", item.id].joined(separator: "|") }
    var body: some View {
        if let task = store.issueTask(item) {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Label("Development", systemImage: "arrow.triangle.branch").font(.subheadline.weight(.semibold)); Spacer(); Button { load() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh linked requests").accessibilityLabel("Refresh linked requests").disabled(loading) }
                WorkbenchFlow {
                    Button { store.requestIssueBranch(item) } label: { Label("Create branch", systemImage: "arrow.triangle.branch") }.disabled(store.busy != nil || store.headHash == nil)
                    Button { store.requestIssuePullRequest(item) } label: { Label(store.target?.provider == .gitlab ? String(localized: "Create merge request") : String(localized: "Create pull request"), systemImage: "arrow.triangle.pull") }.disabled(store.busy != nil || store.headBranch == nil)
                }
                Text("Keep the issue linked from branch to pull request.").font(.caption).foregroundStyle(.secondary)
                if let path = store.url?.path {
                    ForEach(ProjectTaskLinks.issueBranches(task, repositoryPath: path).filter { name in store.localBranches.contains { $0.name == name } }, id: \.self) { name in
                        Button { if let branch = store.localBranches.first(where: { $0.name == name }) { Task { await store.checkout(branch) } } } label: {
                            HStack { Image(systemName: "arrow.triangle.branch"); Text(name).font(.caption.monospaced()); if name == store.headBranch { Text("Current").font(.caption2).foregroundStyle(Color.accentColor) } }
                        }.disabled(store.busy != nil || name == store.headBranch)
                    }
                }
                ForEach(requests) { request in
                    Button { if let url = URL(string: request.url) { NSWorkspace.shared.open(url) } } label: {
                        HStack(alignment: .top, spacing: 8) { Image(systemName: "arrow.triangle.pull"); VStack(alignment: .leading, spacing: 5) { Text("#\(request.number) \(request.title)").font(.callout.weight(.medium)); Text(WorkState.title(request.state)).font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "arrow.up.right") }
                    }.buttonStyle(.plain).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.background, in: RoundedRectangle(cornerRadius: 8))
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                if page == 0 { Button(loading ? String(localized: "Loading…") : String(localized: "Load linked requests")) { load() }.disabled(loading) }
                if page > 0 && requests.isEmpty { Text("No linked requests on loaded pages.").font(.caption).foregroundStyle(.secondary) }
                if more { Button("Load more linked requests") { load(append: true) }.disabled(loading) }
            }.padding(14).background(Color.secondary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.15)))
            .onChange(of: context) { _, _ in requests = []; page = 0; more = false; loading = false; error = nil }
        }
    }
    private func load(append: Bool = false) {
        guard !loading, let access = store.issueAccess else { return }
        let stamp = context, next = append ? page + 1 : 1
        loading = true; error = nil
        Task {
            defer { if context == stamp { loading = false } }
            do {
                let result = try await CollaborationAPI.issueLinkedRequests(access, item: item, page: next)
                guard context == stamp, access.isCurrent?() != false else { return }
                requests = append ? requests + result.0.filter { value in !requests.contains { $0.id == value.id } } : result.0
                more = result.1; page = next
            } catch { if context == stamp { self.error = error.localizedDescription } }
        }
    }
}
