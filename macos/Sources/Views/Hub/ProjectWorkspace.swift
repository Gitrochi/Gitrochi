import SwiftUI
import UniformTypeIdentifiers

private struct ProjectWorkspaceReview: Identifiable {
    let id = UUID()
    let title: String
    let project: String
    let summary: String
    let items: [String]
    let actionTitle: String
    let destructive: Bool
    let expected: String
    let action: (HubAccess) async throws -> Void
}

/// Projects keeps planning, task details and local Git actions in one workspace.
struct ProjectWorkspace: View {
    @Bindable var store: RepoStore
    @ViewState private var filter = ProjectWorkbenchFilter()
    @ViewState private var layout = "overview"
    @ViewState private var scheduleSettings = ProjectScheduleSettings()
    @ViewState private var groupID = ""
    @ViewState private var selectedID: String?
    @ViewState private var compactInspector = false
    @ViewState private var pendingInspectorAction: (() -> Void)?
    @ViewState private var width: CGFloat = 1200
    @ViewState private var composer: ProjectComposerRequest?
    @ViewState private var fieldEditor: ProjectFieldRequest?
    @ViewState private var permissionAccount: HostAccount?
    @ViewState private var showingReadme = false
    @ViewState private var lastViewKey = ""
    @ViewState private var selectingItems = false
    @ViewState private var selectedItems: Set<String> = []
    @ViewState private var creating = false
    @ViewState private var review: ProjectWorkspaceReview?
    @ViewState private var managing = false
    @ViewState private var managementTab: ProjectManagementTab = .overview
    @ViewState private var sharedViews: [HubProjectView] = []
    @ViewState private var sharedViewID: String?
    @ViewState private var viewsRead = UUID()
    @ViewState private var viewsError: String?
    private var isLocal: Bool { store.hubIsLocalProject }
    private var scheduleAccount: String { isLocal ? "local" : store.hubAccount?.id ?? "" }
    private var hub: HostingHubState { store.hostingHub }
    private var detail: HubDetail? { hub.detail }
    private var locked: Bool { hub.loading || hub.detailLoading || hub.busy || hub.allowingCredentialAccess || store.hubCredentialState == .loading }
    private var localRepository: String {
        guard let target = store.target, target.provider == store.hubProvider, target.host.caseInsensitiveCompare(store.hubAccount?.host ?? "") == .orderedSame else { return "" }
        return target.path
    }
    private var rows: [HubProjectRow] { filter.apply(detail?.rows ?? [], repository: localRepository, username: store.hubAccount?.username ?? "") }
    private var selected: HubProjectRow? { detail?.rows.first { $0.id == selectedID } }
    private var grouping: HubProjectField? { detail?.fields.first { $0.id == groupID && !$0.options.isEmpty } ?? detail?.fields.first { $0.name.lowercased() == "status" && !$0.options.isEmpty } ?? detail?.fields.first { !$0.options.isEmpty } }
    private var settingsKey: String { "projectWorkbench." + scheduleAccount + "." + (detail?.item.id ?? "") }
    private var sharedView: HubProjectView? { sharedViews.first { $0.id == sharedViewID } }
    private var tableFields: [HubProjectField] { guard let sharedView else { return detail?.fields ?? [] }; return sharedView.visibleFieldIDs.compactMap { id in detail?.fields.first { $0.id == id } } }

    var body: some View {
        VStack(spacing: 0) {
            header
            accessNotice
            if let detail {
                controls(detail)
                if selectingItems { bulkToolbar(detail) }
                Divider()
                workspace(detail)
                footer(detail)
            } else if hub.loading || hub.detailLoading || store.hubCredentialState == .loading {
                loadingState
            } else if hub.error == nil {
                ContentUnavailableView {
                    Label("Your next project starts here", systemImage: "rectangle.3.group")
                } description: {
                    if isLocal { Text("Create a local project and start organizing tasks, dates, and priorities without an account.") }
                    else { Text("Choose a project above, or change the account and project scope.") }
                } actions: {
                    if store.hubProvider == .github { Button("New project") { manage(.newProject) } }
                    if !isLocal { Button("Show my projects") { Task { await store.selectHubProjectScope("personal"); await selectInitialProject() } } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { Spacer(minLength: 20) }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { value in
            let wasWide = width >= 1080
            width = value
            if value >= 1080 { compactInspector = false }
            else if wasWide, selectedID != nil { compactInspector = true }
        }
        .task(id: store.hubContextStamp) {
            selectedItems = []; selectingItems = false
            if AccountStore.shared.accounts.isEmpty { store.hostingHub.projectSource = "local" }
            await store.activateHostingHub(.projects)
            await selectInitialProject()
            consumeRequestedRow()
        }
        .onChange(of: settingsKey, initial: true) { _, _ in
            guard detail != nil, lastViewKey != settingsKey else { return }
            lastViewKey = settingsKey
            selectedID = nil
            let saved = UserDefaults.standard.string(forKey: settingsKey + ".layout") ?? "overview"
            layout = store.hubProvider == .github || ["board", "table", "roadmap"].contains(saved) ? saved : "board"
            scheduleSettings = ProjectSchedulePreferences.load(accountID: scheduleAccount, projectID: detail?.item.id ?? "")
            groupID = UserDefaults.standard.string(forKey: settingsKey + ".group") ?? ""
            filter = ProjectWorkbenchFilter()
            selectedItems = []; selectingItems = false
            sharedViews = []; sharedViewID = nil
            consumeRequestedRow()
        }
        .task(id: detail?.item.id) { consumeRequestedRow(); await loadSharedViews() }
        .onChange(of: hub.items.map(\.id)) { _, _ in Task { await selectInitialProject() } }
        .onChange(of: hub.requestedProjectRowID) { _, _ in consumeRequestedRow() }
        .onChange(of: detail?.rows.map(\.id)) { _, _ in consumeRequestedRow() }
        .onChange(of: scheduleSettings) { _, value in
            ProjectSchedulePreferences.save(value, accountID: scheduleAccount, projectID: detail?.item.id ?? "")
        }
        .onChange(of: layout) { _, value in
            UserDefaults.standard.set(value, forKey: settingsKey + ".layout")
            if !["board", "table"].contains(value) { selectingItems = false; selectedItems = [] }
        }
        .onChange(of: groupID) { _, value in UserDefaults.standard.set(value, forKey: settingsKey + ".group") }
        .sheet(item: $permissionAccount) { account in
            GitHubBrowserLoginSheet(expectedLogin: account.username, capability: .projects) { _, _ in
                permissionAccount = nil
                Task { await store.activateHostingHub(.projects); await selectInitialProject() }
            }
        }
        .sheet(item: $composer) { request in
            ProjectItemComposer(store: store, request: request) { title, body, url in
                guard let detail, request.context == store.hubActionStamp else { return String(localized: "The repository or account changed. Reopen this action.") }
                return await save(expected: request.context) { c in
                    if request.mode == .link { try await HostingHubAPI.addIssue(c, detail: detail, issueURL: url) }
                    else { try await HostingHubAPI.saveProjectDraft(c, detail: detail, title: title, body: body, row: request.row) }
                }
            }
        }
        .sheet(item: $fieldEditor) { request in
            ProjectFieldEditor(request: request) { value in
                guard let detail, request.context == store.hubActionStamp else { return String(localized: "The repository or account changed. Reopen this action.") }
                return await save(expected: request.context) { c in
                    if !request.bulkRows.isEmpty { try await applyFields(c, field: request.field, rows: request.bulkRows, detail: detail, value: value); selectedItems = [] }
                    else if c.target.provider == .gitlab { try await HostingHubAPI.move(c, detail: detail, row: request.row, field: request.field, option: value ?? "__open") }
                    else { try await HostingHubAPI.updateProjectField(c, detail: detail, row: request.row, field: request.field, value: value) }
                }
            }
        }
        .sheet(item: $review) { request in
            ProjectActionReviewSheet(title: request.title, project: request.project, summary: request.summary, items: request.items,
                                     actionTitle: request.actionTitle, destructive: request.destructive) {
                await save(expected: request.expected, action: request.action)
            }
        }
        .sheet(isPresented: $compactInspector, onDismiss: {
            let action = pendingInspectorAction
            pendingInspectorAction = nil
            action?()
        }) {
            if let selected, let detail { inspector(selected, detail: detail).frame(width: 470, height: 650) }
        }
        .sheet(isPresented: $showingReadme) {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text("Project overview").font(.title2.bold()); Spacer(); Button("Done") { showingReadme = false } }
                ScrollView { MarkdownView(detail?.item.data["readme"] as? String ?? detail?.item.body ?? "") }
            }.padding(24).frame(width: 680, height: 540)
        }
        .onChange(of: LocalProjectStore.shared.revision) { _, _ in
            guard isLocal, !locked else { return }
            Task { if let detail { await store.selectHostingHubItem(detail.item) } else { await store.loadHostingHub(); await selectInitialProject() } }
        }
        .sheet(isPresented: $creating) { ProjectCreationSheet(store: store) { _ in } }
        .sheet(isPresented: $managing) {
            ProjectManagementSheet(store: store, initialTab: managementTab, initialView: managementTab == .views ? sharedView : nil) { Task { await loadSharedViews() } }
        }
    }

    private var header: some View {
        ProjectWorkspaceHeader(store: store, locked: locked, newProject: { creating = true },
            chooseProject: { item in Task { await store.selectHostingHubItem(item) } },
            refresh: { Task { if let detail { await store.selectHostingHubItem(detail.item); await loadSharedViews() } else { await store.loadHostingHub(); await selectInitialProject() } } },
            addTask: { compose(.draft) }, importItem: { compose(.link) }, overview: { showingReadme = true }, manage: manage,
            openBrowser: { if let url = detail?.item.url { open(url) } })
    }

    @ViewBuilder private var accessNotice: some View {
        if let error = hub.error {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.shield").foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).font(.callout).textSelection(.enabled)
                    if store.hubCredentialState == .authorizationRequired {
                        Button("Allow saved account access") { Task { await store.allowHubStoredAccess(); await selectInitialProject() } }.disabled(locked)
                    } else if hub.projectPermissionRequired, let account = store.hubAccount {
                        Button("Connect project access") { permissionAccount = account }.disabled(locked)
                    } else { Button("Retry") { Task { if let detail { await store.selectHostingHubItem(detail.item) } else { await store.loadHostingHub(); await selectInitialProject() } } }.disabled(locked) }
                }
                Spacer()
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color.accentColor.opacity(0.06))
        }
        if hub.allowingCredentialAccess { Label("Waiting for your macOS approval. You can continue using local Git tools.", systemImage: "key").font(.caption).padding(12) }
        if let notice = detail?.notice { Text(notice).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.bottom, 8) }
        if let sharedView, !sharedView.filter.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                VStack(alignment: .leading, spacing: 3) { Text(sharedView.filter).font(.caption.monospaced()); Text("This shared view has a GitHub filter. Native results use your loaded-item filters below.").font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
                Button("Open full GitHub view") { if let url = detail?.item.url { open(url + (sharedView.number.map { "/views/\($0)" } ?? "")) } }
            }.padding(.horizontal, 24).padding(.vertical, 10).background(Color.accentColor.opacity(0.04))
        }
    }

    private func controls(_ detail: HubDetail) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 22) {
                if store.hubProvider == .github {
                    navigationTab("overview", "Overview", symbol: "square.grid.2x2")
                    navigationTab("calendar", "Calendar", symbol: "calendar")
                }
                navigationTab("board", "Board", symbol: "rectangle.split.3x1")
                navigationTab("table", "Table", symbol: "tablecells")
                navigationTab("roadmap", "Roadmap", symbol: "chart.bar.xaxis")
                Spacer(minLength: 8)
                if !isLocal, store.hubProvider == .github {
                    Menu {
                        Button("Local view") { sharedViewID = nil }
                        ForEach(sharedViews) { view in Button(view.name) { apply(view) } }
                        Divider(); Button("Manage shared views…") { manage(.views) }
                        if viewsError != nil { Button("Retry loading views") { Task { await loadSharedViews() } } }
                    } label: { Text(sharedView?.name ?? String(localized: "Shared views")) }.menuStyle(.borderlessButton).fixedSize()
                }
                Text(verbatim: String(localized: "{0} tasks").replacingOccurrences(of: "{0}", with: rows.count.formatted())).font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 22).frame(height: 43)
            Divider()
            if width >= 760 {
                HStack(spacing: 12) { searchField.frame(maxWidth: 380); Spacer(minLength: 0); filterControls(detail) }.padding(.horizontal, 22).padding(.vertical, 10)
            } else {
                VStack(alignment: .leading, spacing: 10) { searchField; HStack(spacing: 12) { filterControls(detail); Spacer(minLength: 0) } }.padding(.horizontal, 22).padding(.vertical, 10)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).disabled(locked)
    }
    private func navigationTab(_ value: String, _ title: LocalizedStringKey, symbol: String) -> some View {
        Button { layout = value; sharedViewID = nil } label: {
            Label(title, systemImage: symbol).font(.system(size: 12, weight: layout == value ? .semibold : .medium))
                .foregroundStyle(layout == value ? Color.accentColor : Color.secondary).frame(height: 43)
                .overlay(alignment: .bottom) { if layout == value { Capsule().fill(Color.accentColor).frame(height: 2) } }
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(layout == value ? .isSelected : [])
    }
    private var searchField: some View {
        HStack(spacing: 8) { Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary); TextField("Search tasks", text: $filter.query).font(.callout).textFieldStyle(.plain); if !filter.query.isEmpty { Button { filter.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).help("Clear search") } }
            .padding(.horizontal, 10).frame(minWidth: 180).frame(height: 32).background(Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
    }
    @ViewBuilder private func filterControls(_ detail: HubDetail) -> some View {
        Menu {
            if !isLocal { Picker("Item type", selection: $filter.kind) { Text("All types").tag("all"); Text("Issues").tag("issue"); Text("Pull requests").tag("pullRequest"); Text("Drafts").tag("draft") }; Toggle("Current repository", isOn: $filter.onlyCurrentRepository).disabled(localRepository.isEmpty); Toggle("Assigned to me", isOn: $filter.onlyMine) }
            Toggle("Include archived", isOn: $filter.includeArchived)
            Divider()
            Picker("Sort by", selection: $filter.sort) { Text("Project order").tag("manual"); Text("Recently updated").tag("updated"); Text("Title").tag("title"); if !isLocal { Text("Number").tag("number") } }
        } label: { Label("Filters", systemImage: "line.3.horizontal.decrease") }.menuStyle(.borderlessButton).fixedSize()
        if ["board", "table"].contains(layout) {
            if let grouping {
                Menu { Picker("Group by", selection: Binding(get: { grouping.id }, set: { groupID = $0 })) { ForEach(detail.fields.filter { !$0.options.isEmpty }) { field in Text(field.name).tag(field.id) } } }
                    label: { Label(grouping.name, systemImage: "rectangle.3.group") }.menuStyle(.borderlessButton).fixedSize()
            }
            Toggle(isOn: $selectingItems) { Label("Select", systemImage: "checkmark.square") }.toggleStyle(.button).controlSize(.small)
        }
    }
    private func workspace(_ detail: HubDetail) -> some View {
        HStack(spacing: 0) {
            Group {
                if layout == "overview" { ProjectDashboard(rows: rows, fields: detail.fields, settings: $scheduleSettings, locked: locked || hub.uncertainWrite, select: select, editDate: editField, complete: complete, manageFields: { manage(isLocal ? .overview : .fields) }, addTask: { compose(.draft) }, openCalendar: { layout = "calendar" }) }
                else if layout == "calendar" { ProjectCalendar(rows: rows, fields: detail.fields, settings: $scheduleSettings, locked: locked || hub.uncertainWrite, select: select, editDate: editField, complete: complete, reschedule: reschedule, manageFields: { manage(isLocal ? .overview : .fields) }) }
                else if layout == "table" { ProjectTaskTable(rows: rows, fields: tableFields, selectedID: selectedID, selectedItems: selectedItems, select: select, edit: editField,
                    setField: { row, field, value in await saveField(row, field: field, detail: detail, value: value) }, canEdit: !locked && !hub.uncertainWrite).id(detail.item.id) }
                else if layout == "roadmap" { ProjectRoadmap(rows: rows, fields: detail.fields, settings: scheduleSettings, select: select, editDate: editField) }
                else { board(detail).id(detail.item.id) }
            }.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if width >= 1080, let selected { Divider(); inspector(selected, detail: detail).frame(width: 325) }
        }
    }
    private func board(_ detail: HubDetail) -> some View {
        var filtered = detail; filtered.rows = rows
        let field = grouping, stamp = store.hubActionStamp
        let columns = HostingHubAPI.projectColumns(filtered, fieldID: field?.id)
        return GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                        ProjectBoardColumn(column: column, index: index,
                            width: max(260, min(420, (geometry.size.width - 44 - CGFloat(max(0, min(columns.count, 3) - 1)) * 14) / CGFloat(max(1, min(columns.count, 3))))),
                            height: 210, localRepository: localRepository,
                            selectedID: selectedID, selectedItems: selectedItems, selectingItems: selectingItems, fields: detail.fields, settings: scheduleSettings, select: select,
                            add: { compose(store.hubProvider == .github ? .draft : .link) },
                            move: { identifiers in
                                guard !locked, let field = grouping, let identifier = identifiers.first,
                                      let row = detail.rows.first(where: { $0.id == identifier }) else { return false }
                                updateField(field, row: row, detail: detail, value: column.id.isEmpty ? nil : column.id)
                                return true
                            }, quickAdd: store.hubProvider == .github ? { title in
                                await save(expected: stamp) { c in
                                    try await HostingHubAPI.createProjectTask(c, detail: detail, title: title, field: field, option: column.id.isEmpty ? nil : column.id)
                                }
                            } : nil, canEdit: !locked && !hub.uncertainWrite)
                    }
                }.padding(22).frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
            }.accessibilityLabel("Project board")
        }
    }
    private func inspector(_ row: HubProjectRow, detail: HubDetail) -> some View {
        let stamp = store.hubActionStamp
        return ProjectTaskInspector(store: store, detail: detail, row: row, close: { selectedID = nil; compactInspector = false }, editField: { field in editField(row, field) }, editDraft: { compose(.draft, row: row) }, archive: {
            write(row.archived ? "Restore archived item?" : "Archive project item?", message: row.title, actionTitle: row.archived ? "Restore" : "Archive") { c in try await HostingHubAPI.archiveProjectItem(c, detail: detail, row: row, archived: !row.archived) }
        }, remove: {
            write("Remove item from project?", message: row.title + (isLocal ? "" : "\n" + String(localized: "The issue or pull request is kept in its repository.")), actionTitle: "Remove", destructive: true) { c in try await HostingHubAPI.deleteProjectItem(c, detail: detail, row: row) }
        }, reorder: { after in
            guard stamp == store.hubActionStamp else { return }
            write("Move project item?", message: row.title + "\n" + (after?.title ?? String(localized: "Move to top")), actionTitle: "Move") { c in
                try await HostingHubAPI.moveProjectItem(c, detail: detail, row: row, afterRow: after)
                filter.sort = "manual"
            }
        }, convert: { repository in
            guard stamp == store.hubActionStamp else { store.hostingHub.error = String(localized: "The repository or account changed. Reopen this action."); return }
            write("Convert draft to issue?", message: row.title + "\n" + repository, actionTitle: "Convert to issue") { c in
                try await HostingHubAPI.convertProjectDraftToIssue(c, detail: detail, row: row, repository: repository)
            }
        }, setField: { field, value in
            await saveField(row, field: field, detail: detail, value: value)
        }, postComment: { text in
            await postComment(text, row: row, detail: detail, expected: stamp)
        })
    }
    private func saveField(_ row: HubProjectRow, field: HubProjectField, detail: HubDetail, value: String?) async -> String? {
        let expected = store.hubActionStamp
        return await save(expected: expected) { c in
            if c.target.provider == .gitlab { try await HostingHubAPI.move(c, detail: detail, row: row, field: field, option: value ?? "__open") }
            else { try await HostingHubAPI.updateProjectField(c, detail: detail, row: row, field: field, value: value) }
        }
    }
    private func postComment(_ text: String, row: HubProjectRow, detail: HubDetail, expected: String) async -> String? {
        guard !isLocal, [.issue, .pullRequest].contains(row.kind), let number = row.number, number > 0,
              !text.trimmed.isEmpty, detail.rows.contains(where: { $0.id == row.id }),
              row.repository.range(of: "^[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)+$", options: .regularExpression) != nil,
              !row.repository.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            return String(localized: "Select a loaded project field and item.")
        }
        return await save(expected: expected) { c in
            guard HostingHubAPI.safeURL(provider: c.target.provider, host: c.target.host, row.url) != nil else { throw HostingHubAPI.fail(String(localized: "The server returned an unsafe URL.")) }
            let target = RepoTarget(provider: c.target.provider, remote: "origin", host: c.target.host, path: row.repository)
            let access = ReviewAccess(target: target, token: c.token, apiBase: c.apiBase, me: c.me, isCurrent: c.isCurrent)
            let item = CollaborationInboxItem(id: row.id, kind: "issue", number: number, title: row.title, url: row.url, body: row.body, state: row.state, author: row.author ?? "", isRequest: row.kind == .pullRequest)
            do { try await CollaborationAPI.inboxAction(access, item: item, action: "comment", body: text) }
            catch let error as HostingError where (400..<500).contains(error.status) && error.status != 408 { throw error }
            catch { throw HubUncertainWriteError(message: String(localized: "The comment may have been posted. Refresh the conversation before trying again.")) }
        }
    }
    private func footer(_ detail: HubDetail) -> some View {
        HStack {
            Text(verbatim: String(localized: "{0} of {1} loaded items").replacingOccurrences(of: "{0}", with: rows.count.formatted()).replacingOccurrences(of: "{1}", with: detail.rows.count.formatted())).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if detail.more { Button("Load more items") { Task { await store.selectHostingHubItem(detail.item, append: true) } }.controlSize(.small).disabled(locked) }
            Label(isLocal ? String(localized: "Saved on this device") : String(localized: "Synced with GitHub"), systemImage: isLocal ? "internaldrive" : "checkmark.icloud").font(.caption).foregroundStyle(.secondary).opacity(store.hubProvider == .github ? 1 : 0)
        }.padding(.horizontal, 24).padding(.vertical, 10).background(Color.secondary.opacity(0.025))
    }
    private var loadingState: some View {
        VStack(spacing: 16) { ProgressView(); Text("Loading your project workspace…").font(.callout).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func consumeRequestedRow() {
        guard lastViewKey == settingsKey, let id = hub.requestedProjectRowID, detail?.rows.contains(where: { $0.id == id }) == true else { return }
        selectedID = id; selectingItems = false
        compactInspector = width < 1080
        store.hostingHub.requestedProjectRowID = nil
    }
    private func complete(_ row: HubProjectRow) {
        guard let detail else { return }
        let fields = ProjectSchedule.fields(detail.fields, settings: scheduleSettings)
        guard let status = fields.status, let option = status.options.first(where: { scheduleSettings.completedOptionIDs.contains($0.id) }) else { return }
        updateField(status, row: row, detail: detail, value: option.id)
    }
    private func reschedule(_ row: HubProjectRow, _ day: String) {
        guard let detail else { return }
        let captured = scheduleSettings
        let plan: [ProjectScheduleChange]
        do { plan = try ProjectSchedule.reschedule(row, fields: detail.fields, settings: captured, targetDay: day) }
        catch { store.hostingHub.error = String(localized: "Choose valid project date fields before scheduling this task."); return }
        let summary = plan.map { change in (detail.fields.first { $0.id == change.fieldID }?.name ?? "") + ": " + change.value }.joined(separator: "\n")
        write("Reschedule project task?", message: row.title + "\n" + summary, actionTitle: "Reschedule") { c in
            try await HostingHubAPI.rescheduleProjectItem(c, detail: detail, row: row, settings: captured, targetDay: day)
        }
    }
    private func select(_ row: HubProjectRow) {
        if selectingItems {
            if selectedItems.contains(row.id) { selectedItems.remove(row.id) } else { selectedItems.insert(row.id) }
        } else { selectedID = row.id; if width < 1080 { compactInspector = true } }
    }
    private func bulkToolbar(_ detail: HubDetail) -> some View {
        let items = detail.rows.filter { selectedItems.contains($0.id) && $0.kind != .redacted }
        return WorkbenchFlow(spacing: 12) {
            Text(verbatim: String(localized: "{0} selected").replacingOccurrences(of: "{0}", with: items.count.formatted())).font(.callout.weight(.semibold))
            Button("Select visible") { selectedItems = Set(rows.filter { $0.kind != .redacted }.map(\.id)) }
            Button("Clear selection") { selectedItems = [] }
            Menu("Set field") {
                ForEach(detail.fields.filter { $0.kind != .unsupported }) { field in
                    Button(field.name) {
                        guard let first = items.first else { return }
                        fieldEditor = ProjectFieldRequest(row: first, field: field, context: store.hubActionStamp, clearable: store.hubProvider == .github && !(isLocal && field.kind == .singleSelect), bulkRows: items.filter { !$0.archived })
                    }
                }
            }.disabled(items.isEmpty || items.allSatisfy(\.archived))
            if store.hubProvider == .github {
                Button("Archive selected") {
                    write("Archive selected items?", message: items.map(\.title).joined(separator: "\n"), actionTitle: "Archive selected") { c in
                        if c.local { _ = try await LocalProjectStore.shared.archiveMany(detail: detail, rows: items.filter { !$0.archived }, archived: true) }
                        else { try await performBatch(items.filter { !$0.archived }) { row in try await HostingHubAPI.archiveProjectItem(c, detail: detail, row: row, archived: true) } }
                        selectedItems = []
                    }
                }.disabled(items.isEmpty)
                if items.contains(where: \.archived) {
                    Button("Restore selected") {
                        write("Restore selected items?", message: items.map(\.title).joined(separator: "\n"), actionTitle: "Restore selected") { c in
                            if c.local { _ = try await LocalProjectStore.shared.archiveMany(detail: detail, rows: items.filter(\.archived), archived: false) }
                            else { try await performBatch(items.filter(\.archived)) { row in try await HostingHubAPI.archiveProjectItem(c, detail: detail, row: row, archived: false) } }
                            selectedItems = []
                        }
                    }
                }
                Button("Remove selected…", role: .destructive) {
                    write("Remove selected items from project?", message: items.map(\.title).joined(separator: "\n") + (isLocal ? "" : "\n" + String(localized: "The issue or pull request is kept in its repository.")), actionTitle: "Remove", destructive: true) { c in
                        if c.local { _ = try await LocalProjectStore.shared.removeMany(detail: detail, rows: items) }
                        else { try await performBatch(items) { row in try await HostingHubAPI.deleteProjectItem(c, detail: detail, row: row) } }
                        selectedItems = []
                    }
                }.disabled(items.isEmpty)
            }
        }.controlSize(.small).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 10).background(Color.accentColor.opacity(0.045)).disabled(locked || hub.uncertainWrite)
    }
    private func compose(_ mode: ProjectComposerRequest.Mode, row: HubProjectRow? = nil) {
        guard !hub.uncertainWrite else { return }
        let request = ProjectComposerRequest(mode: mode, row: row, context: store.hubActionStamp)
        presentAfterInspector {
            guard request.context == store.hubActionStamp else { return }
            composer = request
        }
    }
    private func presentAfterInspector(_ action: @escaping () -> Void) {
        if compactInspector { pendingInspectorAction = action; compactInspector = false }
        else { action() }
    }
    private func editField(_ row: HubProjectRow, _ field: HubProjectField) {
        guard !hub.uncertainWrite, !row.archived, row.kind != .redacted else { return }
        let request = ProjectFieldRequest(row: row, field: field, context: store.hubActionStamp, clearable: store.hubProvider == .github && !(isLocal && field.kind == .singleSelect))
        if compactInspector {
            pendingInspectorAction = { if request.context == store.hubActionStamp { fieldEditor = request } }
            compactInspector = false
        } else { fieldEditor = request }
    }
    private func selectInitialProject() async {
        guard store.hostingHub.section == .projects, store.hostingHub.detail == nil, !store.hostingHub.detailLoading, store.hostingHub.error == nil, let first = store.hostingHub.items.first else { return }
        await store.selectHostingHubItem(first)
    }
    private func manage(_ tab: ProjectManagementTab) { guard !locked else { return }; if tab == .newProject { creating = true; return }; managementTab = tab; managing = true }
    private func apply(_ view: HubProjectView) { sharedViewID = view.id; layout = view.layout == .board ? "board" : view.layout == .table ? "table" : "roadmap"; groupID = view.groupFieldIDs.first ?? "" }
    private func loadSharedViews() async {
        guard !isLocal, store.hubProvider == .github, let detail, store.hubCredentialState == .ready else { return }
        let read = UUID(), stamp = store.hubActionStamp; viewsRead = read
        do {
            let result = try await HostingHubAPI.projectViews(try await store.hubAccess(), detail: detail)
            guard read == viewsRead, store.hubActionStamp == stamp, !Task.isCancelled else { return }
            sharedViews = result.views; viewsError = nil
        } catch { if read == viewsRead, store.hubActionStamp == stamp { viewsError = HostingHubAPI.error(error) } }
    }
    private func open(_ value: String) { if let safe = HostingHubAPI.safeURL(provider: store.hubProvider, host: store.hubAccount?.host ?? "", value) { NSWorkspace.shared.open(safe) } }
    private func performBatch(_ rows: [HubProjectRow], action: (HubProjectRow) async throws -> Void) async throws {
        var completed = 0
        do {
            for row in rows { try await action(row); completed += 1 }
        } catch {
            if completed > 0 {
                throw HubUncertainWriteError(message: String(localized: "Some items were updated before this action stopped. Refresh the project before continuing."))
            }
            throw error
        }
    }
    private func applyFields(_ c: HubAccess, field: HubProjectField, rows: [HubProjectRow], detail: HubDetail, value: String?) async throws {
        if c.local { _ = try await LocalProjectStore.shared.updateFields(detail: detail, rows: rows, field: field, value: value); return }
        try await performBatch(rows) { row in
            if c.target.provider == .gitlab { try await HostingHubAPI.move(c, detail: detail, row: row, field: field, option: value ?? "__open") }
            else { try await HostingHubAPI.updateProjectField(c, detail: detail, row: row, field: field, value: value) }
        }
    }
    private func updateField(_ field: HubProjectField, row: HubProjectRow, detail: HubDetail, value: String?) {
        let stamp = store.hubActionStamp
        Task {
            _ = await save(expected: stamp) { c in
                if c.target.provider == .gitlab { try await HostingHubAPI.move(c, detail: detail, row: row, field: field, option: value ?? "__open") }
                else { try await HostingHubAPI.updateProjectField(c, detail: detail, row: row, field: field, value: value) }
            }
        }
    }
    private func save(expected: String, action: (HubAccess) async throws -> Void) async -> String? {
        guard expected == store.hubActionStamp, !locked, !hub.uncertainWrite else { return String(localized: "The repository or account changed. Reopen this action.") }
        let saved = await store.hostingHubAction(expected: expected, action: action)
        return saved ? nil : store.hostingHub.error ?? String(localized: "The change could not be saved. Refresh and try again.")
    }
    private func write(_ title: String.LocalizationValue, message: String, actionTitle: String.LocalizationValue? = nil, destructive: Bool = false, action: @escaping (HubAccess) async throws -> Void) {
        guard !locked, !hub.uncertainWrite else { return }
        let translated = String(localized: title)
        let label = actionTitle.map { String(localized: $0) } ?? (destructive ? String(localized: "Remove") : String(localized: "Apply changes"))
        let summary = destructive
            ? (isLocal ? String(localized: "These tasks will be permanently removed from this device.") : String(localized: "The issue or pull request is kept in its repository."))
            : String(localized: "Review the project and affected items before applying this change.")
        let request = ProjectWorkspaceReview(title: translated, project: detail?.item.title ?? "", summary: summary,
            items: message.components(separatedBy: .newlines).filter { !$0.isEmpty }, actionTitle: label,
            destructive: destructive, expected: store.hubActionStamp, action: action)
        presentAfterInspector {
            guard request.expected == store.hubActionStamp else { return }
            review = request
        }
    }
}
