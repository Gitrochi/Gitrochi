import SwiftUI
import AppKit

/// The repository's issues: in the repository sidebar (a row opens the Issues page), and as the list of the Issues page (onPage).
/// (Windows: widgets/sidebar/ui/IssueListSection.tsx)
struct IssueListSection: View {
    @Environment(RepoStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    var onPage = false

    private var filters: [(value: String, title: String)] {
        [("open", WorkState.title("open")), ("closed", WorkState.title("closed")), ("all", String(localized: "All"))]
    }

    var body: some View {
        @Bindable var list = store.issueList
        SidebarSection("issues") {
            ListSearchRow(prompt: String(localized: "Search issues"), text: $list.search, filters: filters,
                          selection: list.scope, defaultFilter: "open",
                          onSearch: { Task { await store.loadIssues() } },
                          onFilter: { scope in Task { await store.filterIssues(scope: scope) } })
            if store.collaborationAccess == nil {
                Button("Connect account…") { openSettings() }.buttonStyle(.link).sidebarRow()
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
                .background(onPage && store.collaboration.inboxDetail?.item.id == item.id ? Color.accentColor.opacity(0.15) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .onTapGesture {
                    if onPage { Task { await store.openInboxItem(item) } } else { store.openIssue(item) }
                }
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
                if !onPage {
                    Button { store.navigate(.issues) } label: { Image(systemName: "arrow.up.forward.square") }
                        .buttonStyle(.borderless)
                        .help("Open in Issues")
                }
                Button { Task { await store.loadIssues() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh list")
                Button { store.sheet = .issueEditor(number: nil, title: "", body: "") } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .disabled(store.collaborationAccess == nil)
                    .help("New issue")
            }
        }
        .task(id: store.issueContextKey) { await store.prepareIssues() }
    }
}
