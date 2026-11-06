import AppKit
import SwiftUI

/// Issues, as the redesign's Issues board draws it: where the page is and its actions, what is assigned to you, then
/// the list column and the open issue beside it. The page fills the window; only the list column keeps its width.
/// (Windows: pages/repo/ui/IssuesWorkspace.tsx)
struct IssuesWorkspacePanel: View {
    @Environment(RepoStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    @ViewState private var width: CGFloat = 1000

    private var compact: Bool { width < HostedList.compact }
    private var detail: CollaborationInboxDetail? {
        guard let detail = store.collaboration.inboxDetail, detail.item.kind == "issue" else { return nil }
        return detail
    }

    var body: some View {
        Group {
            if let target = store.target {
                VStack(spacing: 0) {
                    HostedListHeader(target: target) {
                        Button { refresh() } label: { Label("Refresh", symbol: "arrow.clockwise") }
                            .buttonStyle(HostedListButtonStyle(iconOnly: true))
                            .disabled(store.issueList.busy)
                            .help("Refresh list")
                        Button { store.sheet = .issueEditor(number: nil, title: "", body: "") } label: { Label("New issue…", symbol: "plus") }
                            .buttonStyle(HostedListButtonStyle())
                            .disabled(store.collaborationAccess == nil)
                    }
                    if store.collaborationAccess == nil {
                        HostedAccountNeeded(target: target) { refresh() }
                    } else {
                        IssueSummaryCard(compact: compact)
                        Divider()
                        columns
                    }
                }
                .task(id: store.issueContextKey) { await store.prepareIssues() }
                .task(id: store.issueAccountKey) { await store.loadAssignedIssues() }
            } else {
                HostedListEmpty(symbol: "globe", title: String(localized: "No hosting remote"),
                                caption: String(localized: "Open a repository with a GitHub or GitLab remote to use this workspace."),
                                actionTitle: String(localized: "Open repository…"), filled: true) { store.presentOpenPanel() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // the page is the surface colour, as the board draws it; the list column is a shade off it
        .background(StudioStyle.surface)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    /// The list and the detail side by side; in a narrow window choosing a row replaces the list with the detail.
    /// The detail keeps its place in the tree either way, so a draft survives a resize.
    private var columns: some View {
        HStack(spacing: 0) {
            if !(compact && detail != nil) {
                IssueListColumn()
                    .frame(width: compact ? nil : HostedList.column)
                    .frame(maxWidth: compact ? .infinity : nil, maxHeight: .infinity, alignment: .top)
                    .background(StudioStyle.canvas)
                if !compact { Divider() }
            }
            if !compact || detail != nil {
                Group {
                    if let detail {
                        VStack(spacing: 0) {
                            if compact {
                                HStack {
                                    Button { store.collaboration.inboxDetail = nil } label: { Label("Back to issues", symbol: "chevron.left") }
                                        .buttonStyle(HostedListButtonStyle())
                                    Spacer()
                                }
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                Divider()
                            }
                            IssueDetailView(detail: detail)
                        }
                    } else {
                        let branchIssue = store.currentBranchIssue
                        HostedListEmpty(symbol: "sidebar.right", title: String(localized: "Select an issue"),
                                        caption: String(localized: "Search the list, then read the conversation and reply here."),
                                        actionTitle: branchIssue == nil ? nil : String(localized: "Show this branch's issue"), filled: true) {
                            if let task = branchIssue { open(task) }
                        }
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private func refresh() {
        Task {
            await store.loadIssues()
            await store.loadAssignedIssues()
        }
    }

    /// The issue the current branch was created for; the list may not have loaded it
    private func open(_ task: ProjectTaskReference) {
        guard let number = task.number else { return }
        let item = store.issueList.items.first { $0.number == number }
            ?? CollaborationInboxItem(id: "issue-\(number)", kind: "issue", number: number, title: task.title, url: task.url, body: "", state: "open", author: "")
        Task { await store.openInboxItem(item) }
    }
}

/// A hosted page without an account it can use: the saved account's own notice when there is one to restore, else the
/// one blocked state with its filled action
struct HostedAccountNeeded: View {
    @Environment(RepoStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    let target: RepoTarget
    let restored: () -> Void

    var body: some View {
        if let account = store.pendingCredentialAccount ?? store.hostingAccount {
            SavedAccountAccessNotice(account: account, restored: restored)
                .padding(24)
                .frame(maxWidth: 520, maxHeight: .infinity, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HostedListEmpty(symbol: "person.crop.circle.badge.plus",
                            title: String(localized: "Connect a \(target.provider == .gitlab ? "GitLab" : "GitHub") account"),
                            caption: String(localized: "\(target.path) is on \(target.host). Connect an account to see its pull requests, issues and runs."),
                            actionTitle: String(localized: "Connect account…"), filled: true) { openSettings() }
        }
    }
}

/// What is assigned to you: how far each issue's work is, as this repository knows it, and the one next step
private struct IssueSummaryCard: View {
    @Environment(RepoStore.self) private var store
    @Environment(\.locale) private var locale
    let compact: Bool

    private static let reviewColor = StudioStyle.Tone.waiting.text
    private static let progressColor = StudioStyle.Tone.info.text
    private static let idleColor = Color.primary.opacity(0.22)

    /// The assigned issues once they were read for this repository and account
    private var items: [CollaborationInboxItem]? {
        store.issueList.assignedKey == store.issueAccountKey ? store.issueList.assigned : nil
    }

    var body: some View {
        let items = items
        let assigned = (items ?? []).map { store.issueProgress($0) }
        let summary = IssuePage.summary(assigned)
        let next = IssuePage.next(assigned, currentBranch: store.headBranch)
        HostedListSummary(compact: compact) {
            HostedListSummaryCaption(text: String(localized: "Assigned to you"))
            if items == nil {
                HostedListSummaryCaption(text: pending)
            } else if let first = summary.lines.first {
                Text(verbatim: first).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                if summary.lines.count > 1 { HostedListSummaryCaption(text: summary.lines.dropFirst().joined(separator: " · ")) }
            } else {
                Text("No open issues are assigned to you").font(.system(size: 15, weight: .semibold)).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } middle: {
            if summary.total > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    bar(summary)
                    HStack(spacing: 24) {
                        if !summary.inReview.isEmpty {
                            legend(Self.reviewColor, "In review", note: reviewOnThisBranch(assigned) ? String(localized: "on this branch") : nil)
                        }
                        if !summary.inProgress.isEmpty { legend(Self.progressColor, "In progress", note: nil) }
                        if !summary.notStarted.isEmpty { legend(Self.idleColor, "Not started", note: nil) }
                    }
                    .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if items != nil, let open = openCount {
                HostedListSummaryCaption(text: String(localized: "\(open) issues are open in \(store.target?.path ?? "")."))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Color.clear
            }
        } trail: {
            action(next, items: items ?? [])
            if case .createBranch(let number)? = next, let item = items?.first(where: { $0.number == number }),
               let date = ListDate.parse(item.createdAt) {
                HostedListSummaryCaption(text: String(localized: "Oldest, opened \(ListDate.day(date, locale: locale))"))
            } else if case .createRequest(_, let branch)? = next {
                HostedListSummaryCaption(text: branch)
            }
        } strip: {
            SymbolIcon("smallcircle.filled.circle").font(.system(size: 13)).foregroundStyle(HostedList.caption).accessibilityHidden(true)
            HostedListSummaryCaption(text: String(localized: "Assigned to you")).fixedSize()
            Text(verbatim: items == nil ? pending : summary.total == 0 ? String(localized: "No open issues are assigned to you") : summary.counts.replacingOccurrences(of: ", ", with: " · "))
                .font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 8)
            action(next, items: items ?? [])
        }
        .accessibilityLabel("Issues assigned to you")
    }

    /// What stands in for the summary until the assigned issues are read: still on their way, or out of reach
    private var pending: String {
        store.issueList.assignedFailed ? String(localized: "Couldn't reach \(store.target?.host ?? "")") : String(localized: "Loading…")
    }

    /// The number of open issues, when the list shows all of them
    private var openCount: Int? {
        let list = store.issueList
        return list.scope == "open" && list.page > 0 && !list.more && list.loadedSearch.trimmed.isEmpty && list.error == nil ? list.items.count : nil
    }

    private func reviewOnThisBranch(_ assigned: [IssuePage.Assigned]) -> Bool {
        guard let branch = store.headBranch else { return false }
        return assigned.contains { $0.progress == .inReview && $0.branch == branch }
    }

    @ViewBuilder private func action(_ next: IssuePage.Next?, items: [CollaborationInboxItem]) -> some View {
        switch next {
        case .createBranch(let number)?:
            if let item = items.first(where: { $0.number == number }) {
                Button { store.requestIssueBranch(item) } label: { Label(String(localized: "Create branch for #\(String(number))"), symbol: "arrow.triangle.branch") }
                    .buttonStyle(HostedListButtonStyle())
                    .disabled(store.busy != nil || store.headHash == nil)
            }
        case .createRequest(let number, _)?:
            if let item = items.first(where: { $0.number == number }) {
                Button { store.requestIssuePullRequest(item) } label: {
                    Label(store.target?.provider == .gitlab ? String(localized: "Create merge request for #\(String(number))…") : String(localized: "Create pull request for #\(String(number))…"),
                          symbol: "arrow.triangle.pull")
                }
                .buttonStyle(HostedListButtonStyle())
                .disabled(store.busy != nil)
            }
        case nil:
            if items.isEmpty, self.items != nil, store.issueList.scope != "open" {
                Button("Show open issues") { Task { await store.filterIssues(scope: "open") } }.buttonStyle(HostedListButtonStyle())
            }
        }
    }

    /// One bar, a part for each group as wide as its share; the legend under it says which is which
    private func bar(_ summary: IssuePage.Summary) -> some View {
        GeometryReader { geometry in
            let parts: [(Color, Int)] = [(Self.reviewColor, summary.inReview.count), (Self.progressColor, summary.inProgress.count), (Self.idleColor, summary.notStarted.count)].filter { $0.1 > 0 }
            let unit = (geometry.size.width - CGFloat(max(0, parts.count - 1)) * 4) / CGFloat(max(1, summary.total))
            HStack(spacing: 4) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    Rectangle().fill(part.0).frame(width: max(0, unit * CGFloat(part.1)))
                }
            }
        }
        .frame(height: 8)
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary.counts)
    }

    private func legend(_ color: Color, _ title: LocalizedStringKey, note: String?) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).font(.system(size: 12, weight: .semibold))
            if let note { Text(verbatim: note).font(.system(size: 12)).foregroundStyle(HostedList.caption) }
        }
        .lineLimit(1)
    }
}

/// The Issues page's list column: search and order, the three filters, then the rows
private struct IssueListColumn: View {
    @Environment(RepoStore.self) private var store
    @Environment(\.locale) private var locale

    private static let sorts: [(value: String, title: String)] = [
        ("updated", String(localized: "Recently updated")), ("created", String(localized: "Newest first")), ("oldest", String(localized: "Oldest first")),
    ]

    private var host: String { store.target?.host ?? "" }

    var body: some View {
        @Bindable var list = store.issueList
        VStack(alignment: .leading, spacing: 10) {
            if let error = list.error, !list.items.isEmpty {
                HostedListNotice(title: String(localized: "Couldn't reach \(host)"), caption: hostedListAge(list.loadedAt, locale: locale)) { reload() }
                    .help(error)
            }
            HostedListSearch(prompt: String(localized: "Search issues"), text: $list.search,
                             menuTitle: String(localized: "Sort") + ": " + (Self.sorts.first { $0.value == list.sort }?.title ?? ""),
                             onSearch: { reload() }) {
                Picker("Sort", selection: Binding(get: { list.sort }, set: { sort in Task { await store.sortIssues(sort) } })) {
                    ForEach(Self.sorts, id: \.value) { Text(verbatim: $0.title).tag($0.value) }
                }
                .pickerStyle(.inline)
            }
            HostedListSegments(options: [
                (value: "open", title: WorkState.title("open"), count: nil),
                (value: "assigned", title: String(localized: "Assigned to you"), count: assignedCount),
                (value: "closed", title: WorkState.title("closed"), count: nil),
            ], selection: list.scope) { scope in Task { await store.filterIssues(scope: scope) } }
            content
        }
        .padding(12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Issue list")
    }

    /// Only this segment counts: it is the one that needs your attention
    private var assignedCount: String? {
        let list = store.issueList
        guard list.assignedKey == store.issueAccountKey, let assigned = list.assigned else { return nil }
        return IssuePage.count(assigned.count, more: list.assignedMore)
    }

    @ViewBuilder private var content: some View {
        let list = store.issueList
        if list.items.isEmpty, let error = list.error {
            HostedListEmpty(symbol: "xmark.circle.fill", title: String(localized: "Couldn't reach \(host)"), caption: error,
                            actionTitle: String(localized: "Retry"), failed: true) { reload() }
        } else if list.items.isEmpty, list.busy || list.page == 0 {
            HostedListLoading(caption: String(localized: "Loading issues…"))
            Spacer(minLength: 0)
        } else if list.items.isEmpty {
            empty
        } else {
            let requests = store.issueRequests(list.items)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(list.items) { row($0, request: requests[$0.number]) }
                    if list.more {
                        Button("Show more") { Task { await store.loadIssues(append: true) } }
                            .buttonStyle(HostedListTextButtonStyle())
                            .frame(maxWidth: .infinity, minHeight: 32)
                            .disabled(list.busy)
                    }
                }
            }
        }
    }

    @ViewBuilder private var empty: some View {
        let list = store.issueList, search = list.loadedSearch.trimmed
        if !search.isEmpty {
            HostedListEmpty(symbol: "magnifyingglass", title: String(localized: "No issues match “\(search)”"),
                            actionTitle: String(localized: "Clear search")) {
                list.search = ""
                reload()
            }
        } else if list.scope == "closed" {
            HostedListEmpty(symbol: "smallcircle.filled.circle", title: String(localized: "No closed issues"),
                            actionTitle: String(localized: "Show open issues")) { Task { await store.filterIssues(scope: "open") } }
        } else if list.scope == "assigned" {
            HostedListEmpty(symbol: "smallcircle.filled.circle", title: String(localized: "No open issues are assigned to you"),
                            actionTitle: String(localized: "Show open issues")) { Task { await store.filterIssues(scope: "open") } }
        } else {
            HostedListEmpty(symbol: "smallcircle.filled.circle", title: String(localized: "No open issues"),
                            caption: String(localized: "Nothing is open in \(store.target?.path ?? ""). Closed issues are under Closed."),
                            actionTitle: String(localized: "Show closed issues")) { Task { await store.filterIssues(scope: "closed") } }
        }
    }

    /// A row ends with its comment count and its author's avatar, like a pull request row. The state is not repeated:
    /// the segment already says it.
    private func row(_ item: CollaborationInboxItem, request: PullRequest?) -> some View {
        let selected = store.collaboration.inboxDetail?.item.id == item.id
        let secondary = HostedList.secondary(selected: selected)
        return HostedListRow(selected: selected) { Task { await store.openInboxItem(item) } } content: {
            HostedListRowTitle(title: item.title, when: ListDate.parse(item.updatedAt).map { ListDate.when($0, locale: locale) }, selected: selected)
            HStack(spacing: 6) {
                Text(verbatim: "#\(item.number)").font(.system(size: 11, design: .monospaced)).foregroundStyle(secondary)
                if let request {
                    HostedListChip(title: "#\(request.number)", symbol: "arrow.triangle.pull", selected: selected)
                }
                Spacer(minLength: 6)
                if let comments = item.comments, comments > 0 {
                    HStack(spacing: 4) {
                        DesignIconImage(icon: .comment, size: 10)
                        Text(verbatim: String(comments)).font(.system(size: 11))
                    }
                    .foregroundStyle(secondary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(comments == 1 ? String(localized: "1 comment") : String(localized: "\(comments) comments"))
                }
                if !item.author.isEmpty {
                    Avatar(name: item.author, email: item.author, size: 16)
                        .help("@" + item.author)
                        .accessibilityLabel("@" + item.author)
                }
            }
        }
        .contextMenu {
            Button("Open in browser") { if let url = URL(string: item.url) { NSWorkspace.shared.open(url) } }
            Button("Copy link") { store.copy(item.url) }
        }
    }

    private func reload() { Task { await store.loadIssues() } }
}
