import SwiftUI

enum ProjectTaskStyle {
    static func color(_ index: Int) -> Color { [.gray, .blue, .orange, .green, .purple, .teal][index % 6] }
    static func symbol(_ row: HubProjectRow) -> String {
        if row.archived { return "archivebox" }
        switch row.kind { case .issue: return row.state.lowercased() == "closed" ? "checkmark.circle.fill" : "circle.dotted"; case .pullRequest: return "arrow.triangle.pull"; case .draft: return "note.text"; case .redacted: return "lock" }
    }
    static func color(_ row: HubProjectRow) -> Color { row.kind == .pullRequest ? .purple : row.kind == .draft ? .secondary : .green }
    static func kind(_ row: HubProjectRow) -> String { if row.id.hasPrefix("local-task:") { return String(localized: "Task") }; switch row.kind { case .issue: return String(localized: "Issue"); case .pullRequest: return String(localized: "Pull request"); case .draft: return String(localized: "Draft"); case .redacted: return String(localized: "Private item") } }
    static func value(_ row: HubProjectRow, field: HubProjectField) -> String {
        let raw = row.values[field.id] ?? row.statuses[field.id] ?? ""
        return field.options.first { $0.id == raw }?.name ?? raw
    }
    static func fieldColor(_ row: HubProjectRow, field: HubProjectField) -> Color {
        let raw = row.values[field.id] ?? row.statuses[field.id] ?? ""
        switch raw {
        case "local-done": return .green
        case "local-progress": return .blue
        case "local-urgent": return .red
        case "local-high": return .orange
        case "local-normal": return .blue
        case "local-low", "local-todo": return .secondary
        default: return color(field.options.firstIndex { $0.id == raw } ?? 0)
        }
    }
}

struct ProjectTaskCard: View {
    let row: HubProjectRow
    let selected: Bool
    let local: Bool
    var selectingItems = false
    var fields: [HubProjectField] = []
    var settings = ProjectScheduleSettings()
    let select: () -> Void
    @ViewState private var hovering = false
    private var resolved: ProjectScheduleFields { ProjectSchedule.fields(fields, settings: settings) }
    private var entry: ProjectScheduleEntry? { ProjectSchedule.entries([row], fields: fields, settings: settings).first }
    private var priority: HubProjectField? { fields.first { $0.id == "local-priority" } ?? fields.first { $0.kind == .singleSelect && $0.name.lowercased() == "priority" } }

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: selectingItems ? selected ? "checkmark.square.fill" : "square" : entry?.completed == true ? "checkmark.circle.fill" : ProjectTaskStyle.symbol(row))
                        .font(.system(size: 13)).foregroundStyle(entry?.completed == true ? .green : ProjectTaskStyle.color(row)).padding(.top, 2)
                    Text(row.title).font(.system(size: 13, weight: .semibold)).lineLimit(3).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(.primary)
                    if let number = row.number { Text("#\(number)").font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary) }
                }
                WorkbenchFlow(spacing: 6) {
                    if let status = resolved.status, !ProjectTaskStyle.value(row, field: status).isEmpty {
                        badge(ProjectTaskStyle.value(row, field: status), symbol: "circle.fill", color: ProjectTaskStyle.fieldColor(row, field: status))
                    }
                    if let priority, !ProjectTaskStyle.value(row, field: priority).isEmpty {
                        badge(ProjectTaskStyle.value(row, field: priority), symbol: "flag", color: ProjectTaskStyle.fieldColor(row, field: priority))
                    }
                    if let entry, let day = entry.date {
                        badge(ProjectSchedulePresentation.date(day), symbol: entry.invalidRange ? "exclamationmark.triangle" : "calendar", color: ProjectSchedulePresentation.color(entry, today: ProjectSchedule.today()))
                    }
                    ForEach(Array(row.labels.prefix(2)), id: \.self) { label in badge(label, symbol: nil, color: .accentColor) }
                    if row.labels.count > 2 { Text("+\(row.labels.count - 2)").font(.caption2).foregroundStyle(.secondary) }
                }
                if !row.repository.isEmpty || !row.assignees.isEmpty {
                    HStack(spacing: 7) {
                        if !row.repository.isEmpty {
                            if local { Image(systemName: "laptopcomputer").help("Local repository") }
                            Text(row.repository).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                        if let name = row.assignees.first {
                            Image(systemName: "person.crop.circle").font(.system(size: 12))
                            Text(name).lineLimit(1)
                            if row.assignees.count > 1 { Text("+\(row.assignees.count - 1)") }
                        }
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.padding(13).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .background(selected ? Color.accentColor.opacity(0.04) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : Color.secondary.opacity(hovering ? 0.25 : 0.13), lineWidth: selected ? 1.5 : 1))
                .shadow(color: .black.opacity(hovering ? 0.055 : 0.025), radius: hovering ? 5 : 3, y: 2).contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).accessibilityLabel(row.title).accessibilityAddTraits(selected ? .isSelected : [])
            .onHover { hovering = $0 }
    }

    private func badge(_ title: String, symbol: String?, color: Color) -> some View {
        HStack(spacing: 4) { if let symbol { Image(systemName: symbol) }; Text(title).lineLimit(1) }
            .font(.system(size: 10, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 4).background(color.opacity(0.065), in: RoundedRectangle(cornerRadius: 5))
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
    var fields: [HubProjectField] = []
    var settings = ProjectScheduleSettings()
    let select: (HubProjectRow) -> Void
    let add: () -> Void
    let move: ([String]) -> Bool
    var quickAdd: ((String) async -> String?)? = nil
    var canEdit = true
    @ViewState private var adding = false
    @ViewState private var title = ""
    @ViewState private var creating = false
    @ViewState private var createError: String?
    @FocusState private var titleFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(ProjectTaskStyle.color(index)).frame(width: 7, height: 7)
                Text(column.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(column.rows.count.formatted()).font(.system(size: 10, weight: .medium)).monospacedDigit()
                    .foregroundStyle(.secondary).padding(.horizontal, 6).padding(.vertical, 3).background(Color.secondary.opacity(0.075), in: Capsule())
                Spacer(minLength: 0)
            }.padding(.horizontal, 3).padding(.vertical, 5)
            ForEach(column.rows) { row in
                ProjectTaskCard(row: row, selected: selectingItems ? selectedItems.contains(row.id) : selectedID == row.id,
                    local: !row.repository.isEmpty && row.repository.caseInsensitiveCompare(localRepository) == .orderedSame,
                    selectingItems: selectingItems, fields: fields, settings: settings,
                    select: { select(row) })
                    .onDrag { NSItemProvider(object: row.id as NSString) }
            }
            if column.rows.isEmpty {
                Label("No tasks here yet", systemImage: "tray").font(.system(size: 11)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 5).padding(.vertical, 18)
            }
            if adding { quickAddForm }
            else {
                Button {
                    guard canEdit else { return }
                    if quickAdd != nil { adding = true; createError = nil; titleFocused = true }
                    else { add() }
                } label: {
                    Label("Add item", systemImage: "plus").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6).padding(.vertical, 8).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(!canEdit)
            }
        }
        .padding(12).frame(width: width).frame(minHeight: min(210, max(180, height)), alignment: .topLeading)
        .background(Color.secondary.opacity(0.025), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.1)))
        .dropDestination(for: String.self) { identifiers, _ in move(identifiers) }
    }

    private var quickAddForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("New task").font(.system(size: 11, weight: .semibold)); Spacer(minLength: 4); Text(column.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            TextField("Task title", text: $title).textFieldStyle(.plain).font(.system(size: 12)).focused($titleFocused)
                .onSubmit { Task { await submitQuickAdd() } }.onExitCommand { cancelQuickAdd() }
                .padding(9).background(Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6)).disabled(creating || !canEdit)
            if let createError { Label(createError, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 8) {
                if creating { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
                Button("Cancel", action: cancelQuickAdd).buttonStyle(.borderless).disabled(creating)
                Button("Add task") { Task { await submitQuickAdd() } }.buttonStyle(.borderedProminent)
                    .disabled(creating || !canEdit || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.controlSize(.small)
        }.padding(11).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.3)))
    }
    private func cancelQuickAdd() {
        guard !creating else { return }
        adding = false; title = ""; createError = nil
    }
    private func submitQuickAdd() async {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canEdit, !creating, !value.isEmpty, let quickAdd else { return }
        creating = true; createError = nil
        let error = await quickAdd(value)
        creating = false
        if let error { createError = error; titleFocused = true }
        else { adding = false; title = "" }
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
    var setField: ((HubProjectField, String?) async -> String?)? = nil
    var postComment: ((String) async -> String?)? = nil
    @ViewState private var conversation: CollaborationInboxDetail?
    @ViewState private var conversationError: String?
    @ViewState private var reading = false
    @ViewState private var updatingField = false
    @ViewState private var fieldError: String?
    @ViewState private var converting = false
    @ViewState private var destination = ""
    @ViewState private var conversationRead = UUID()
    @ViewState private var conversationContext = ""
    @ViewState private var commentText = ""
    @ViewState private var postingComment = false
    @ViewState private var commentError: String?
    @ViewState private var commentPosted = false
    private var localProject: Bool { LocalProjectStore.isLocal(detail.item) }
    private var editableFields: [HubProjectField] { detail.fields.filter { $0.kind != .unsupported } }
    private var canEdit: Bool { !locked && !updatingField && !postingComment && !row.archived && row.kind != .redacted }
    private var hasConversation: Bool { !localProject && [.issue, .pullRequest].contains(row.kind) && row.number != nil && !row.repository.isEmpty }
    private var local: Bool { !row.repository.isEmpty && store.target?.path.caseInsensitiveCompare(row.repository) == .orderedSame && store.target?.host == store.hubAccount?.host }
    private var locked: Bool { store.hostingHub.busy || store.hostingHub.detailLoading || store.hostingHub.uncertainWrite }
    private var linkedBranches: [Branch] {
        let names = ProjectTaskLinks.branches(taskID: row.id, repositoryPath: store.url?.path ?? "", repository: row.repository, host: store.hubAccount?.host ?? "")
        return store.localBranches.filter { names.contains($0.name) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(ProjectTaskStyle.kind(row), systemImage: ProjectTaskStyle.symbol(row)).font(.caption.weight(.medium)).foregroundStyle(ProjectTaskStyle.color(row))
                if !localProject, !row.state.isEmpty {
                    Text(row.state.lowercased() == "merged" ? String(localized: "Merged") : row.state.lowercased() == "closed" ? String(localized: "Closed") : String(localized: "Open"))
                        .font(.caption2.weight(.medium)).padding(.horizontal, 7).padding(.vertical, 3)
                        .background(ProjectTaskStyle.color(row).opacity(0.1), in: Capsule())
                }
                Spacer()
                taskMenu
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Close details")
            }.padding(18)
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
                            Button { store.navigate(.repository); store.showArea(.changes) } label: { Label("Open local changes", systemImage: "square.and.pencil") }
                            Label(store.headBranch ?? String(localized: "Detached HEAD"), systemImage: "arrow.triangle.branch").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                            ForEach(linkedBranches) { branch in
                                Button { Task { await store.checkout(branch) } } label: { Label(branch.name, systemImage: branch.isCurrent ? "checkmark.circle.fill" : "arrow.triangle.branch").font(.caption.monospaced()) }.disabled(branch.isCurrent || store.busy != nil)
                            }
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
                    }
                    properties
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Description").font(.system(size: 12, weight: .semibold))
                        if row.body.isEmpty { Text("No description yet.").font(.callout).foregroundStyle(.secondary) }
                        else if hasConversation, let author = row.author { discussionCard(author: author, createdAt: row.createdAt, body: row.body) }
                        else { MarkdownView(row.body).font(.callout) }
                    }
                    if hasConversation { conversationSection }
                    if let safe = HostingHubAPI.safeURL(provider: store.hubProvider, host: store.hubAccount?.host ?? "", row.url) { Link(destination: safe) { Label("Open in browser", systemImage: "arrow.up.right.square") }.font(.callout) }
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.background(Color(nsColor: .controlBackgroundColor))
            .task(id: row.id + store.hubContextStamp) { await readConversation() }
            .sheet(isPresented: $converting) { conversionForm }
    }
    private var conversationComments: [CollaborationInboxComment] { conversation?.comments ?? [] }
    private var properties: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack { Text("Properties").font(.system(size: 12, weight: .semibold)); Spacer(); if updatingField { ProgressView().controlSize(.small) } }
            VStack(alignment: .leading, spacing: 0) {
                if !row.assignees.isEmpty && !editableFields.contains(where: { $0.id == "local-assignees" || ["assignee", "assignees"].contains($0.name.lowercased()) }) {
                    property("Assignees", value: row.assignees.map { "@" + $0 }.joined(separator: ", ")).padding(.vertical, 7)
                }
                ForEach(editableFields) { field in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(field.name).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
                        fieldControl(field)
                    }.padding(.vertical, 7)
                    if field.id != editableFields.last?.id { Divider().opacity(0.5) }
                }
                if !row.labels.isEmpty { property("Labels", value: row.labels.joined(separator: ", ")).padding(.top, 10) }
            }
            if let fieldError { Label(fieldError, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }.padding(14).background(Color.secondary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .contain)
    }
    @ViewBuilder private func fieldControl(_ field: HubProjectField) -> some View {
        let value = ProjectTaskStyle.value(row, field: field)
        let label = field.name + ": " + (value.isEmpty ? String(localized: "Not set") : value)
        if let setField, [.singleSelect, .iteration].contains(field.kind), !field.options.isEmpty {
            Menu {
                Button("Not set") { Task { await updateField(field, value: nil, using: setField) } }
                    .disabled(localProject && ["local-status", "local-priority"].contains(field.id))
                ForEach(field.options) { option in
                    Button { Task { await updateField(field, value: option.id, using: setField) } } label: {
                        if (row.values[field.id] ?? row.statuses[field.id]) == option.id { Label(option.name, systemImage: "checkmark") }
                        else { Text(option.name) }
                    }
                }
            } label: { propertyValue(value, color: ProjectTaskStyle.fieldColor(row, field: field), symbol: "chevron.down") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).disabled(!canEdit).accessibilityLabel(label)
        } else {
            Button { editField(field) } label: { propertyValue(value, color: .primary, symbol: field.kind == .date ? "calendar" : "pencil") }
                .buttonStyle(.plain).disabled(!canEdit).accessibilityLabel(label)
        }
    }
    private func propertyValue(_ value: String, color: Color, symbol: String) -> some View {
        HStack(spacing: 6) { Text(value.isEmpty ? String(localized: "Not set") : value).font(.system(size: 11, weight: .medium)).lineLimit(2); Spacer(minLength: 4); Image(systemName: symbol).font(.system(size: 9)).foregroundStyle(.secondary) }
            .foregroundStyle(value.isEmpty ? Color.secondary : color).contentShape(Rectangle())
    }
    private func updateField(_ field: HubProjectField, value: String?, using action: (HubProjectField, String?) async -> String?) async {
        guard canEdit else { return }
        let context = conversationContext
        updatingField = true; fieldError = nil
        let error = await action(field, value)
        if conversationContext == context { fieldError = error }
        updatingField = false
    }
    private var taskMenu: some View {
        Menu {
            if row.kind == .draft { Button(localProject ? String(localized: "Edit task") : String(localized: "Edit draft"), action: editDraft).disabled(row.archived) }
            if store.hubProvider == .github, row.kind != .redacted {
                if !row.archived {
                    Divider()
                    Button("Move to top…") { reorder(nil) }
                    Menu("Move after…") { ForEach(detail.rows.filter { $0.id != row.id && !$0.archived }) { other in Button(other.title) { reorder(other) } } }
                    if row.kind == .draft, !localProject { Button("Convert to issue…") { destination = store.target?.host == store.hubAccount?.host ? store.target?.path ?? "" : ""; converting = true } }
                }
                Divider()
                Button(row.archived ? String(localized: "Restore archived item") : String(localized: "Archive item"), action: archive)
                Button("Remove from project…", role: .destructive, action: remove)
            }
        } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("More").accessibilityLabel("More").disabled(locked || updatingField || postingComment)
    }
    private var conversionForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Convert draft to issue").font(.title2.weight(.semibold))
            Text(row.title).font(.callout).foregroundStyle(.secondary)
            TextField("Destination repository", text: $destination, prompt: Text(verbatim: "owner/name")).textFieldStyle(.roundedBorder)
            Text("Choose the repository where this draft will become an issue.").font(.callout).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Cancel") { converting = false }.keyboardShortcut(.cancelAction); Button("Review conversion") { let value = destination.trimmed; converting = false; convert(value) }.buttonStyle(.borderedProminent).disabled(destination.trimmed.isEmpty).keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 510).background(Color(nsColor: .windowBackgroundColor))
    }
    private var conversationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Conversation").font(.system(size: 12, weight: .semibold))
                if !conversationComments.isEmpty { Text(conversationComments.count.formatted()).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if reading { ProgressView().controlSize(.small) }
                Button { Task { await readConversation() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Refresh").disabled(reading)
            }
            if conversation != nil, conversationComments.isEmpty, !reading { Text("No comments yet.").font(.callout).foregroundStyle(.secondary) }
            ForEach(conversationComments) { comment in
                discussionCard(author: comment.author, createdAt: comment.createdAt, body: comment.body)
            }
            if let conversationError { Label(conversationError, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            if conversation?.more == true {
                Button("Load more comments") { Task { await readConversation(page: (conversation?.page ?? 1) + 1) } }.font(.callout).disabled(reading || postingComment)
            }
            if postComment != nil {
                VStack(alignment: .leading, spacing: 10) {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $commentText).font(.callout).scrollContentBackground(.hidden).frame(minHeight: 88, maxHeight: 160).padding(5).accessibilityLabel("Comment")
                            .onChange(of: commentText) { _, value in if !value.isEmpty { commentPosted = false } }
                        if commentText.isEmpty { Text("Write a comment…").font(.callout).foregroundStyle(.tertiary).padding(.horizontal, 10).padding(.vertical, 13).allowsHitTesting(false) }
                    }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.18))).disabled(postingComment || locked)
                    if let commentError { Label(commentError, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                    if commentPosted { Label("Comment posted", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green) }
                    HStack { if postingComment { ProgressView().controlSize(.small) }; Spacer(); Button("Comment") { Task { await submitComment() } }.buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command).disabled(postingComment || locked || commentText.trimmed.isEmpty) }
                }
            }
        }
    }
    private func discussionCard(author: String, createdAt: String?, body: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(String(author.prefix(1)).uppercased()).font(.system(size: 10, weight: .semibold)).frame(width: 23, height: 23).background(Color.accentColor.opacity(0.1), in: Circle())
                Text("@" + author).font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 0)
                if let date = Hosting.date(createdAt) { Text(Fmt.short(date)).font(.caption2).foregroundStyle(.secondary).help(Fmt.long(date)) }
            }.padding(10).background(Color.secondary.opacity(0.035))
            Divider()
            MarkdownView(body).font(.callout).padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.12)))
    }
    private func submitComment() async {
        let value = commentText.trimmed
        guard !postingComment, !locked, !value.isEmpty, let postComment else { return }
        let context = conversationContext
        postingComment = true; commentError = nil; commentPosted = false
        let error = await postComment(value)
        guard conversationContext == context else { postingComment = false; return }
        if let error { commentError = error }
        else { commentText = ""; await readConversation(); if conversationContext == context { commentPosted = true } }
        postingComment = false
    }
    private func property(_ label: LocalizedStringKey, value: String) -> some View { HStack(alignment: .firstTextBaseline) { Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .leading); Text(value).font(.caption).textSelection(.enabled) } }
    private func readConversation(page: Int = 1) async {
        let context = row.id + store.hubContextStamp
        if conversationContext != context { conversation = nil; conversationError = nil; conversationContext = context; commentText = ""; commentError = nil; commentPosted = false }
        guard hasConversation, let number = row.number, let account = store.hubAccount, let token = AccountStore.shared.token(for: account) else { return }
        let stamp = store.hubContextStamp, identifier = row.id
        let target = RepoTarget(provider: account.provider, remote: "origin", host: account.host, path: row.repository)
        let access = ReviewAccess(target: target, token: token, apiBase: account.apiBase, me: account.username, isCurrent: { store.hubContextStamp == stamp })
        let item = CollaborationInboxItem(id: "issue-\(number)", kind: row.kind == .pullRequest ? "pullRequest" : "issue", number: number, title: row.title, url: row.url, body: row.body, state: row.state, author: "", isRequest: row.kind == .pullRequest)
        let read = UUID(); conversationRead = read
        reading = true
        defer { if conversationRead == read { reading = false } }
        do {
            var value = try await CollaborationAPI.detail(access, item: item, page: page)
            guard !Task.isCancelled, store.hubContextStamp == stamp, row.id == identifier, conversationRead == read else { return }
            if page > 1 { var seen = Set<String>(); value.comments = (conversationComments + value.comments).filter { seen.insert($0.id).inserted } }
            conversation = value; conversationError = nil
        }
        catch { if !Task.isCancelled, store.hubContextStamp == stamp, conversationRead == read { conversationError = HostingHubAPI.error(error, token: token) } }
    }
}

struct ProjectTaskTable: View {
    let rows: [HubProjectRow]
    let fields: [HubProjectField]
    let selectedID: String?
    var selectedItems: Set<String> = []
    let select: (HubProjectRow) -> Void
    let edit: (HubProjectRow, HubProjectField) -> Void
    var setField: ((HubProjectRow, HubProjectField, String?) async -> String?)? = nil
    var canEdit = true
    @ViewState private var updatingField = false
    @ViewState private var fieldError: String?
    private var columns: [HubProjectField] { fields.filter { $0.kind != .unsupported } }
    private var showsRepository: Bool { rows.contains { !$0.repository.isEmpty } }
    private var tableWidth: CGFloat { 320 + (showsRepository ? 180 : 0) + CGFloat(columns.count) * 150 }

    var body: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(rows) { row in
                            HStack(spacing: 0) {
                                Button { select(row) } label: {
                                    HStack(spacing: 9) {
                                        Image(systemName: ProjectTaskStyle.symbol(row)).foregroundStyle(ProjectTaskStyle.color(row))
                                        Text(row.title).font(.system(size: 12, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
                                        Spacer(minLength: 0)
                                        if let n = row.number { Text("#\(n)").font(.caption).foregroundStyle(.secondary) }
                                    }.padding(.horizontal, 12).frame(width: 320, height: 46, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                if showsRepository { Text(row.repository.isEmpty ? "—" : row.repository).font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 12).frame(width: 180, height: 46, alignment: .leading).lineLimit(1) }
                                ForEach(columns) { field in
                                    fieldCell(row, field: field)
                                }
                                Spacer(minLength: 0)
                            }.frame(minWidth: max(tableWidth, geometry.size.width - 40), alignment: .leading)
                                .background(selectedID == row.id || selectedItems.contains(row.id) ? Color.accentColor.opacity(0.065) : Color.clear)
                                .accessibilityElement(children: .contain).accessibilityLabel(row.title)
                            Divider()
                        }
                        if rows.isEmpty {
                            Label("No items match these filters.", systemImage: "line.3.horizontal.decrease.circle").font(.callout).foregroundStyle(.secondary)
                                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } header: {
                        HStack(spacing: 0) {
                            header("Task", width: 320)
                            if showsRepository { header("Repository", width: 180) }
                            ForEach(columns) { field in Text(field.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 12).frame(width: 150, height: 36, alignment: .leading) }
                            Spacer(minLength: 0)
                        }.frame(minWidth: max(tableWidth, geometry.size.width - 40), alignment: .leading)
                            .background(Color(nsColor: .controlBackgroundColor)).overlay(alignment: .bottom) { Divider() }
                            .accessibilityElement(children: .contain).accessibilityLabel("Project table header")
                    }
                }.frame(minWidth: max(tableWidth, geometry.size.width - 40), alignment: .topLeading)
                    .padding(20).frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
            }.defaultScrollAnchor(.topLeading)
        }.accessibilityLabel("Project table").overlay(alignment: .bottomLeading) {
            if let fieldError { Label(fieldError, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red).padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8)).padding(20) }
        }
    }
    @ViewBuilder private func fieldCell(_ row: HubProjectRow, field: HubProjectField) -> some View {
        let value = ProjectTaskStyle.value(row, field: field)
        let label = field.name + ": " + (value.isEmpty ? String(localized: "Not set") : value)
        if let setField, [.singleSelect, .iteration].contains(field.kind), !field.options.isEmpty {
            Menu {
                Button("Not set") { Task { await updateField(row, field: field, value: nil, using: setField) } }
                    .disabled(row.id.hasPrefix("local-task:") && ["local-status", "local-priority"].contains(field.id))
                ForEach(field.options) { option in
                    Button { Task { await updateField(row, field: field, value: option.id, using: setField) } } label: {
                        if (row.values[field.id] ?? row.statuses[field.id]) == option.id { Label(option.name, systemImage: "checkmark") }
                        else { Text(option.name) }
                    }
                }
            } label: { cellValue(value, color: ProjectTaskStyle.fieldColor(row, field: field), menu: true) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).disabled(!canEdit || updatingField || row.archived || row.kind == .redacted).accessibilityLabel(label)
        } else {
            Button { edit(row, field) } label: { cellValue(value, color: .primary, menu: false) }
                .buttonStyle(.plain).disabled(!canEdit || updatingField || row.archived || row.kind == .redacted).accessibilityLabel(label)
        }
    }
    private func cellValue(_ value: String, color: Color, menu: Bool) -> some View {
        HStack(spacing: 6) { Text(value.isEmpty ? "—" : value).font(.system(size: 11)).lineLimit(1); Spacer(minLength: 0); if menu { Image(systemName: "chevron.down").font(.system(size: 8)).foregroundStyle(.tertiary) } }
            .foregroundStyle(color).padding(.horizontal, 12).frame(width: 150, height: 46, alignment: .leading).contentShape(Rectangle())
    }
    private func updateField(_ row: HubProjectRow, field: HubProjectField, value: String?, using action: (HubProjectRow, HubProjectField, String?) async -> String?) async {
        guard canEdit, !updatingField, !row.archived, row.kind != .redacted else { return }
        updatingField = true; fieldError = nil
        fieldError = await action(row, field, value)
        updatingField = false
    }
    private func header(_ title: LocalizedStringKey, width: CGFloat) -> some View { Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 12).frame(width: width, height: 36, alignment: .leading) }
}
