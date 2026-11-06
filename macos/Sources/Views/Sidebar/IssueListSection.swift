import SwiftUI
import AppKit

/// The repository's issues in the repository sidebar: a row opens the Issues page, which has the search, the filters and
/// its own rows (IssuesWorkspacePanel). The list itself lives in the store, so both show the same items.
/// (Windows: widgets/sidebar/ui/IssueListSection.tsx)
struct IssueListSection: View {
    @Environment(RepoStore.self) private var store
    @Environment(\.openSettings) private var openSettings

    private var filters: [(value: String, title: String)] {
        [("open", WorkState.title("open")), ("closed", WorkState.title("closed")), ("all", String(localized: "All")),
         ("assigned", String(localized: "Assigned to you"))]
    }

    var body: some View {
        @Bindable var list = store.issueList
        SidebarSection("issues") {
            if list.scope != "open" || !list.loadedSearch.isEmpty {
                ListFilterCaption(filter: filters.first { $0.value == list.scope }?.title ?? list.scope, search: list.loadedSearch) {
                    list.search = ""
                    Task { await store.filterIssues(scope: "open") }
                }
            }
            if store.collaborationAccess == nil {
                if let account = store.hostingAccount {
                    SavedAccountAccessNotice(account: account) { Task { await store.loadIssues() } }.sidebarRow()
                } else {
                    Button("Connect account…") { openSettings() }.buttonStyle(.link).sidebarRow()
                }
            }
            if let error = list.error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(3).textSelection(.enabled).sidebarRow()
            }
            if list.busy, list.items.isEmpty {
                ProgressView().controlSize(.small).sidebarRow()
            } else if list.items.isEmpty, list.page > 0 {
                Text("No issues match this filter.").font(.callout).foregroundStyle(.secondary).sidebarRow()
            }
            ForEach(list.items) { item in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text("#\(item.number)").foregroundStyle(.secondary).monospacedDigit()
                        Text(item.title).lineLimit(1)
                    }
                    Text(verbatim: "\(WorkState.title(item.state)) · @\(item.author)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .sidebarRow()
                .contentShape(Rectangle())
                .onTapGesture { store.openIssue(item) }
                .contextMenu {
                    Button("Open in browser") { if let u = URL(string: item.url) { NSWorkspace.shared.open(u) } }
                    Button("Copy link") { store.copy(item.url) }
                }
            }
            if list.more {
                Button("Load more") { Task { await store.loadIssues(append: true) } }.disabled(list.busy).sidebarRow()
            }
        } header: {
            HStack {
                Text(list.page > 0 ? "Issues \(list.items.count)" : "Issues")
                Spacer()
                if list.busy, !list.items.isEmpty { ProgressView().controlSize(.mini) }
                Button { store.navigate(.issues) } label: { DesignIconImage(icon: .external) }
                    .buttonStyle(.borderless)
                    .help("Open in Issues")
                Button { store.sheet = .issueEditor(number: nil, title: "", body: "") } label: { DesignIconImage(icon: .plus) }
                    .buttonStyle(.borderless)
                    .disabled(store.collaborationAccess == nil)
                    .help("New issue")
            }
        }
        .task(id: store.issueContextKey) { await store.prepareIssues() }
    }
}
