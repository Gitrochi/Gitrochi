import SwiftUI

enum ProjectTaskStyle {
    static func color(_ index: Int) -> Color { [.gray, .blue, .orange, .green, .purple, .teal][index % 6] }
    static func symbol(_ row: HubProjectRow) -> String {
        if row.archived { return "archivebox" }
        switch row.kind { case .issue: return row.state.lowercased() == "closed" ? "checkmark.circle.fill" : "circle.dotted"; case .pullRequest: return "arrow.triangle.pull"; case .draft: return "note.text"; case .redacted: return "lock" }
    }
    static func color(_ row: HubProjectRow) -> Color { row.kind == .pullRequest ? .purple : row.kind == .draft ? .secondary : .green }
    static func kind(_ row: HubProjectRow) -> String { switch row.kind { case .issue: return String(localized: "Issue"); case .pullRequest: return String(localized: "Pull request"); case .draft: return String(localized: "Draft"); case .redacted: return String(localized: "Private item") } }
    static func value(_ row: HubProjectRow, field: HubProjectField) -> String {
        let raw = row.values[field.id] ?? row.statuses[field.id] ?? ""
        return field.options.first { $0.id == raw }?.name ?? raw
    }
}

struct ProjectTaskCard: View {
    let row: HubProjectRow
    let selected: Bool
    let local: Bool
    var selectingItems = false
    let select: () -> Void
    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 6) { Image(systemName: selectingItems ? selected ? "checkmark.square.fill" : "square" : ProjectTaskStyle.symbol(row)).foregroundStyle(ProjectTaskStyle.color(row)); Text(row.repository.isEmpty ? ProjectTaskStyle.kind(row) : row.repository).lineLimit(1).truncationMode(.middle); Spacer(minLength: 0); if let number = row.number { Text("#\(number)").monospacedDigit() } }.font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Text(row.title).font(.system(size: 13, weight: .semibold)).lineLimit(3).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(.primary)
                if !row.labels.isEmpty {
                    HStack(spacing: 5) { ForEach(Array(row.labels.prefix(2)), id: \.self) { label in Text(label).font(.system(size: 10, weight: .medium)).padding(.horizontal, 6).padding(.vertical, 3).background(Color.accentColor.opacity(0.07), in: Capsule()) }; if row.labels.count > 2 { Text("+\(row.labels.count - 2)").font(.caption2) } }.foregroundStyle(Color.accentColor)
                }
                HStack {
                    if local { Label("Local repository", systemImage: "laptopcomputer").font(.system(size: 10)) }
                    Spacer(minLength: 0)
                    if let name = row.assignees.first { Text("@" + name).font(.system(size: 10, weight: .medium)).lineLimit(1) }
                }.foregroundStyle(.secondary)
            }.padding(13).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.13), lineWidth: selected ? 1.5 : 1))
                .shadow(color: .black.opacity(0.025), radius: 3, y: 2).contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).accessibilityLabel(row.title).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ProjectBoardColumn: View {
    let column: HubProjectColumn
    let index: Int
    let width: CGFloat
    let height: CGFloat
    let localRepository: String
    let selectedID: String?
    var selectedItems: Set<String> = []
    var selectingItems = false
    let select: (HubProjectRow) -> Void
    let add: () -> Void
    let move: ([String]) -> Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(ProjectTaskStyle.color(index)).frame(width: 8, height: 8)
                Text(column.title).font(.callout.weight(.semibold))
                Text(column.rows.count.formatted()).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }.padding(.horizontal, 5).padding(.vertical, 6)
            ForEach(column.rows) { row in
                ProjectTaskCard(row: row, selected: selectingItems ? selectedItems.contains(row.id) : selectedID == row.id,
                    local: !row.repository.isEmpty && row.repository.caseInsensitiveCompare(localRepository) == .orderedSame,
                    selectingItems: selectingItems,
                    select: { select(row) })
                    .onDrag { NSItemProvider(object: row.id as NSString) }
            }
            if column.rows.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray").font(.title2)
                    Text("No tasks here yet").font(.caption)
                    Button("Add item", action: add).buttonStyle(.borderless)
                }.foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 40)
            }
            Spacer(minLength: 18)
        }
        .padding(12).frame(width: width).frame(minHeight: height, alignment: .topLeading)
        .background(ProjectTaskStyle.color(index).opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.1)))
        .dropDestination(for: String.self) { identifiers, _ in move(identifiers) }
    }
}

struct ProjectTaskInspector: View {
    @Bindable var store: RepoStore
    let detail: HubDetail
    let row: HubProjectRow
    let close: () -> Void
    let editField: (HubProjectField) -> Void
    let editDraft: () -> Void
    let archive: () -> Void
    let remove: () -> Void
    let reorder: (HubProjectRow?) -> Void
    let convert: (String) -> Void
    @ViewState private var conversation: CollaborationInboxDetail?
    @ViewState private var conversationError: String?
    @ViewState private var reading = false
    private var local: Bool { !row.repository.isEmpty && store.target?.path.caseInsensitiveCompare(row.repository) == .orderedSame && store.target?.host == store.hubAccount?.host }
    private var locked: Bool { store.hostingHub.busy || store.hostingHub.detailLoading || store.hostingHub.uncertainWrite }
    private var linkedBranches: [Branch] {
        let names = ProjectTaskLinks.branches(taskID: row.id, repositoryPath: store.url?.path ?? "", repository: row.repository, host: store.hubAccount?.host ?? "")
        return store.localBranches.filter { names.contains($0.name) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Label(ProjectTaskStyle.kind(row), systemImage: ProjectTaskStyle.symbol(row)).font(.caption.weight(.medium)).foregroundStyle(ProjectTaskStyle.color(row)); Spacer(); Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Close details") }.padding(18)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) { if !row.repository.isEmpty { Text(row.repository + (row.number.map { " #\($0)" } ?? "")).font(.caption.monospaced()).foregroundStyle(.secondary) }; Text(row.title).font(.system(size: 20, weight: .bold)).fixedSize(horizontal: false, vertical: true) }
                    if local {
                        VStack(alignment: .leading, spacing: 11) {
                            Label("Build this task", systemImage: "hammer").font(.callout.weight(.semibold))
                            if row.kind == .issue {
                                Button {
                                    let reference = ProjectTaskReference(id: row.id, title: row.title, url: row.url, number: row.number, repository: row.repository, host: store.hubAccount?.host ?? "")
                                    store.sheet = .newBranch(start: store.headHash ?? "HEAD", label: store.headBranch ?? "HEAD", suggestedName: ProjectWorkbench.suggestedBranch(number: row.number, title: row.title), projectTask: reference)
                                } label: { Label("Start work in a branch", systemImage: "arrow.triangle.branch").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
                            }
                            if row.kind == .pullRequest, let number = row.number {
                                Button { store.navigate(.pullRequests); store.select(.pullRequest(number)) } label: { Label("Review in Gitrochi", systemImage: "arrow.triangle.pull").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
                            }
                            Button { store.navigate(.changes) } label: { Label("Open local changes", systemImage: "square.and.pencil") }
                            Label(store.headBranch ?? String(localized: "Detached HEAD"), systemImage: "arrow.triangle.branch").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                            ForEach(linkedBranches) { branch in
                                Button { Task { await store.checkout(branch) } } label: { Label(branch.name, systemImage: branch.isCurrent ? "checkmark.circle.fill" : "arrow.triangle.branch").font(.caption.monospaced()) }.disabled(branch.isCurrent || store.busy != nil)
                            }
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Properties").font(.callout.weight(.semibold))
                        if !row.state.isEmpty { property("State", value: row.state.lowercased().capitalized) }
                        if !row.assignees.isEmpty { property("Assignees", value: row.assignees.map { "@" + $0 }.joined(separator: ", ")) }
                        if !row.labels.isEmpty { property("Labels", value: row.labels.joined(separator: ", ")) }
                        ForEach(detail.fields.filter { $0.kind != .unsupported }) { field in
                            HStack(alignment: .firstTextBaseline) {
                                Text(field.name).font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                                Button { editField(field) } label: { HStack { Text(ProjectTaskStyle.value(row, field: field).isEmpty ? String(localized: "Not set") : ProjectTaskStyle.value(row, field: field)).lineLimit(2); Spacer(minLength: 4); Image(systemName: "pencil").font(.system(size: 9)) } }.buttonStyle(.borderless).font(.caption).disabled(locked || row.archived || row.kind == .redacted)
                            }
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 10) { Text("Description").font(.callout.weight(.semibold)); if row.body.isEmpty { Text("No description yet.").font(.callout).foregroundStyle(.secondary) } else { MarkdownView(row.body).font(.callout) } }
                    if !conversationComments.isEmpty {
                        Divider(); Text("Conversation").font(.callout.weight(.semibold))
                        ForEach(conversationComments) { comment in VStack(alignment: .leading, spacing: 7) { Text("@" + comment.author).font(.caption.weight(.semibold)); MarkdownView(comment.body).font(.callout) }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9)) }
                    }
                    if reading { ProgressView().controlSize(.small) }
                    if let conversationError { Text(conversationError).font(.caption).foregroundStyle(.secondary) }
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        if store.hubProvider == .github, row.kind != .redacted, !row.archived {
                            ProjectTaskActions(detail: detail, row: row, repository: store.target?.host == store.hubAccount?.host ? store.target?.path ?? "" : "", reorder: reorder, convert: convert)
                        }
                        if row.kind == .draft { Button("Edit draft", action: editDraft).disabled(row.archived) }
                        if store.hubProvider == .github, row.kind != .redacted {
                            Button(row.archived ? String(localized: "Restore archived item") : String(localized: "Archive item"), action: archive)
                            Button("Remove from project…", role: .destructive, action: remove)
                        }
                        if let safe = HostingHubAPI.safeURL(provider: store.hubProvider, host: store.hubAccount?.host ?? "", row.url) { Link(destination: safe) { Label("Open in browser", systemImage: "arrow.up.right.square") } }
                    }.font(.callout).disabled(locked)
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.background(Color(nsColor: .controlBackgroundColor))
            .task(id: row.id + store.hubContextStamp) { await readConversation() }
    }
    private var conversationComments: [CollaborationInboxComment] { conversation?.comments ?? [] }
    private func property(_ label: LocalizedStringKey, value: String) -> some View { HStack(alignment: .firstTextBaseline) { Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .leading); Text(value).font(.caption).textSelection(.enabled) } }
    private func readConversation() async {
        conversation = nil; conversationError = nil
        guard row.kind == .issue, let number = row.number, !row.repository.isEmpty, let account = store.hubAccount, let token = AccountStore.shared.token(for: account) else { return }
        let stamp = store.hubContextStamp, identifier = row.id
        let target = RepoTarget(provider: account.provider, remote: "origin", host: account.host, path: row.repository)
        let access = ReviewAccess(target: target, token: token, apiBase: account.apiBase, me: account.username, isCurrent: { store.hubContextStamp == stamp })
        let item = CollaborationInboxItem(id: "issue-\(number)", kind: "issue", number: number, title: row.title, url: row.url, body: row.body, state: row.state, author: "")
        reading = true
        defer { if row.id == identifier { reading = false } }
        do { let value = try await CollaborationAPI.detail(access, item: item, page: 1); guard !Task.isCancelled, store.hubContextStamp == stamp else { return }; conversation = value }
        catch { if !Task.isCancelled, store.hubContextStamp == stamp { conversationError = HostingHubAPI.error(error, token: token) } }
    }
}

struct ProjectTaskTable: View {
    let rows: [HubProjectRow]
    let fields: [HubProjectField]
    let selectedID: String?
    var selectedItems: Set<String> = []
    let select: (HubProjectRow) -> Void
    let edit: (HubProjectRow, HubProjectField) -> Void
    private var columns: [HubProjectField] { fields.filter { $0.kind != .unsupported } }
    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) { header("Task", width: 340); header("Repository", width: 180); ForEach(columns) { field in Text(field.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(12).frame(width: 150, alignment: .leading) } }.background(Color.secondary.opacity(0.05))
                ForEach(rows) { row in
                    HStack(spacing: 0) {
                        Button { select(row) } label: { HStack { Image(systemName: ProjectTaskStyle.symbol(row)).foregroundStyle(ProjectTaskStyle.color(row)); Text(row.title).lineLimit(2).multilineTextAlignment(.leading); Spacer(minLength: 0); if let n = row.number { Text("#\(n)").font(.caption).foregroundStyle(.secondary) } }.padding(12).frame(width: 340, alignment: .leading) }.buttonStyle(.plain)
                        Text(row.repository.isEmpty ? "—" : row.repository).font(.caption).foregroundStyle(.secondary).padding(12).frame(width: 180, alignment: .leading).lineLimit(1)
                        ForEach(columns) { field in Button { edit(row, field) } label: { Text(ProjectTaskStyle.value(row, field: field).isEmpty ? "—" : ProjectTaskStyle.value(row, field: field)).font(.caption).lineLimit(1).frame(width: 126, alignment: .leading).padding(12) }.buttonStyle(.plain).disabled(row.archived || row.kind == .redacted) }
                    }.background(selectedID == row.id || selectedItems.contains(row.id) ? Color.accentColor.opacity(0.065) : Color.clear)
                    Divider()
                }
                if rows.isEmpty { Text("No items match these filters.").font(.callout).foregroundStyle(.secondary).padding(24) }
            }.padding(20)
        }.accessibilityLabel("Project table")
    }
    private func header(_ title: LocalizedStringKey, width: CGFloat) -> some View { Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(12).frame(width: width, alignment: .leading) }
}
