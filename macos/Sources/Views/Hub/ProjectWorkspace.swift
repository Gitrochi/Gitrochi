import SwiftUI
import UniformTypeIdentifiers

/// Projects keeps planning, task details and local Git actions in one workspace.
struct ProjectWorkspace: View {
    @Bindable var store: RepoStore
    @ViewState private var filter = ProjectWorkbenchFilter()
    @ViewState private var layout = "board"
    @ViewState private var groupID = ""
    @ViewState private var selectedID: String?
    @ViewState private var compactInspector = false
    @ViewState private var width: CGFloat = 1200
    @ViewState private var composer: ProjectComposerRequest?
    @ViewState private var fieldEditor: ProjectFieldRequest?
    @ViewState private var permissionAccount: HostAccount?
    @ViewState private var showingReadme = false
    @ViewState private var lastViewKey = ""
    @ViewState private var selectingItems = false
    @ViewState private var selectedItems: Set<String> = []
    @ViewState private var managing = false
    @ViewState private var managementTab: ProjectManagementTab = .overview
    @ViewState private var sharedViews: [HubProjectView] = []
    @ViewState private var sharedViewID: String?
    @ViewState private var viewsRead = UUID()
    @ViewState private var viewsError: String?
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
    private var settingsKey: String { "projectWorkbench." + (store.hubAccount?.id ?? "") + "." + (detail?.item.id ?? "") }
    private var sharedView: HubProjectView? { sharedViews.first { $0.id == sharedViewID } }
    private var tableFields: [HubProjectField] { guard let sharedView, !sharedView.visibleFieldIDs.isEmpty else { return detail?.fields ?? [] }; return sharedView.visibleFieldIDs.compactMap { id in detail?.fields.first { $0.id == id } } }

    var body: some View {
        VStack(spacing: 0) {
            header
            accessNotice
            if let detail {
                metrics(detail)
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
                    Text("Choose a project above, or change the account and project scope.")
                } actions: {
                    if store.hubProvider == .github { Button("New project") { manage(.newProject) } }
                    Button("Show my projects") { Task { await store.selectHubProjectScope("personal"); await selectInitialProject() } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { Spacer(minLength: 20) }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task(id: store.hubContextStamp) {
            selectedID = nil
            selectedItems = []; selectingItems = false
            await store.activateHostingHub(.projects)
            await selectInitialProject()
        }
        .onChange(of: detail?.item.id) { _, _ in
            guard detail != nil, lastViewKey != settingsKey else { return }
            lastViewKey = settingsKey
            selectedID = nil
            layout = UserDefaults.standard.string(forKey: settingsKey + ".layout") ?? "board"
            groupID = UserDefaults.standard.string(forKey: settingsKey + ".group") ?? ""
            filter = ProjectWorkbenchFilter()
            selectedItems = []; selectingItems = false
            sharedViews = []; sharedViewID = nil
        }
        .task(id: detail?.item.id) { await loadSharedViews() }
        .onChange(of: layout) { _, value in UserDefaults.standard.set(value, forKey: settingsKey + ".layout") }
        .onChange(of: groupID) { _, value in UserDefaults.standard.set(value, forKey: settingsKey + ".group") }
        .sheet(item: $permissionAccount) { account in
            GitHubBrowserLoginSheet(expectedLogin: account.username, capability: .projects) { _, _ in
                permissionAccount = nil
                Task { await store.activateHostingHub(.projects); await selectInitialProject() }
            }
        }
        .sheet(item: $composer) { request in
            ProjectItemComposer(store: store, request: request) { title, body, url in
                composer = nil
                guard let detail, request.context == store.hubActionStamp else { store.hostingHub.error = String(localized: "The repository or account changed. Reopen this action."); return }
                if request.mode == .link {
                    write("Add item to project?", message: url) { c in try await HostingHubAPI.addIssue(c, detail: detail, issueURL: url) }
                } else {
                    write(request.row == nil ? "Create draft task?" : "Save draft changes?", message: title) { c in
                        try await HostingHubAPI.saveProjectDraft(c, detail: detail, title: title, body: body, row: request.row)
                    }
                }
            }
        }
        .sheet(item: $fieldEditor) { request in
            ProjectFieldEditor(request: request) { value in
                fieldEditor = nil
                guard let detail, request.context == store.hubActionStamp else { store.hostingHub.error = String(localized: "The repository or account changed. Reopen this action."); return }
                if request.bulkRows.isEmpty { updateField(request.field, row: request.row, detail: detail, value: value) }
                else { updateFields(request.field, rows: request.bulkRows, detail: detail, value: value) }
            }
        }
        .sheet(isPresented: $compactInspector) {
            if let selected, let detail { inspector(selected, detail: detail).frame(width: 470, height: 650) }
        }
        .sheet(isPresented: $showingReadme) {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text("Project overview").font(.title2.bold()); Spacer(); Button("Done") { showingReadme = false } }
                ScrollView { MarkdownView(detail?.item.data["readme"] as? String ?? detail?.item.body ?? "") }
            }.padding(24).frame(width: 680, height: 540)
        }
        .sheet(isPresented: $managing) {
            ProjectManagementSheet(store: store, initialTab: managementTab, initialView: managementTab == .views ? sharedView : nil) { Task { await loadSharedViews() } }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            WorkbenchFlow(spacing: 10) {
                Picker("Workspace account", selection: Binding(get: { store.hubAccount?.id ?? "" }, set: { id in Task { await store.selectHubAccount(id); await selectInitialProject() } })) {
                    ForEach(AccountStore.shared.accounts) { account in Text(verbatim: "@\(account.username) · \(account.host)").tag(account.id) }
                }.labelsHidden().frame(maxWidth: 245)
                if store.hubProvider == .github {
                    Picker("Project scope", selection: Binding(get: { store.hubProjectEffectiveScope }, set: { scope in Task { await store.selectHubProjectScope(scope); await selectInitialProject() } })) {
                        if let owner = store.hubProjectRepositoryOwner { Text(verbatim: owner).tag("repository") }
                        Text("My projects").tag("personal")
                    }.labelsHidden().frame(width: 170)
                }
                if store.url != nil { Label(store.headBranch ?? String(localized: "Detached HEAD"), systemImage: "arrow.triangle.branch").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1) }
            }.controlSize(.small).disabled(locked)
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Menu {
                        ForEach(hub.items) { item in Button(item.title) { Task { await store.selectHostingHubItem(item) } } }
                        if hub.more { Divider(); Button("Load more projects") { Task { await store.loadHostingHub(append: true) } } }
                    } label: {
                        HStack(spacing: 9) { Image(systemName: "rectangle.3.group.fill").foregroundStyle(Color.accentColor); Text(detail?.item.title ?? String(localized: "Choose a project")).font(.system(size: 22, weight: .bold)); Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                    }.menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true).disabled(locked || hub.items.isEmpty)
                    Text(detail?.item.body.isEmpty == false ? detail!.item.body : String(localized: "Plan the work. Build it here."))
                        .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button { Task { if let detail { await store.selectHostingHubItem(detail.item); await loadSharedViews() } else { await store.loadHostingHub(); await selectInitialProject() } } } label: { Image(systemName: "arrow.clockwise").frame(width: 22, height: 22) }.help("Refresh project").disabled(locked)
                if detail != nil {
                    Menu {
                        Button("Project overview") { showingReadme = true }
                        if store.hubProvider == .github {
                            Button("Project settings…") { manage(.overview) }
                            Button("Manage fields…") { manage(.fields) }
                            Button("Manage shared views…") { manage(.views) }
                            Divider()
                            Button("New project…") { manage(.newProject) }
                        }
                        Button("Open in GitHub") { if let url = detail?.item.url { open(url) } }
                    } label: { Image(systemName: "ellipsis").frame(width: 22, height: 22) }.help("Project actions")
                    Menu {
                        if store.hubProvider == .github { Button("Draft task") { compose(.draft) } }
                        Button("Existing issue or pull request") { compose(.link) }
                    } label: { Label("Add item", systemImage: "plus").fontWeight(.semibold) }
                        .menuStyle(.borderlessButton).tint(.white).padding(.horizontal, 14).padding(.vertical, 9).background(Color.accentColor, in: RoundedRectangle(cornerRadius: 9)).disabled(locked || hub.uncertainWrite)
                }
            }
        }.padding(.horizontal, 24).padding(.vertical, 19)
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

    private func metrics(_ detail: HubDetail) -> some View {
        let active = detail.rows.filter { !$0.archived }, done = active.filter { ["closed", "merged"].contains($0.state.lowercased()) }.count
        return HStack(spacing: 28) {
            metric("Loaded items", value: active.count, symbol: "square.stack.3d.up", color: .accentColor)
            metric("Issues", value: active.filter { $0.kind == .issue }.count, symbol: "circle.dotted", color: .green)
            metric("Pull requests", value: active.filter { $0.kind == .pullRequest }.count, symbol: "arrow.triangle.pull", color: .purple)
            metric("Closed items", value: done, symbol: "checkmark.circle", color: .teal)
            Spacer(minLength: 0)
            if hub.busy || hub.detailLoading { ProgressView().controlSize(.small) }
        }.padding(.horizontal, 24).padding(.vertical, 13).background(Color.secondary.opacity(0.035))
    }
    private func metric(_ title: LocalizedStringKey, value: Int, symbol: String, color: Color) -> some View {
        HStack(spacing: 9) { Image(systemName: symbol).foregroundStyle(color); Text(value.formatted()).font(.system(size: 20, weight: .bold, design: .rounded)); Text(title).font(.caption).foregroundStyle(.secondary) }
    }
    private func controls(_ detail: HubDetail) -> some View {
        WorkbenchFlow(spacing: 10) {
            HStack(spacing: 7) { Image(systemName: "magnifyingglass").foregroundStyle(.tertiary); TextField("Filter by title, repository, label or assignee", text: $filter.query).textFieldStyle(.plain) }.padding(9).frame(minWidth: 200, idealWidth: 285, maxWidth: 360).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.12)))
            Picker("Project view", selection: $layout) { Label("Board", systemImage: "rectangle.split.3x1").tag("board"); Label("Table", systemImage: "tablecells").tag("table"); Label("Roadmap", systemImage: "chart.bar.xaxis").tag("roadmap") }.labelsHidden().pickerStyle(.segmented).frame(width: 265)
            if store.hubProvider == .github {
                Menu {
                    Button("Local view") { sharedViewID = nil }
                    ForEach(sharedViews) { view in Button(view.name) { apply(view) } }
                    Divider()
                    Button("Manage shared views…") { manage(.views) }
                    if viewsError != nil { Button("Retry loading views") { Task { await loadSharedViews() } } }
                } label: { Label(sharedView?.name ?? String(localized: "Shared views"), systemImage: "rectangle.on.rectangle") }
            }
            Menu {
                Picker("Item type", selection: $filter.kind) { Text("All types").tag("all"); Text("Issues").tag("issue"); Text("Pull requests").tag("pullRequest"); Text("Drafts").tag("draft") }
                Toggle("Current repository", isOn: $filter.onlyCurrentRepository).disabled(localRepository.isEmpty)
                Toggle("Assigned to me", isOn: $filter.onlyMine)
                Toggle("Include archived", isOn: $filter.includeArchived)
                Divider()
                Picker("Sort by", selection: $filter.sort) { Text("Project order").tag("manual"); Text("Recently updated").tag("updated"); Text("Title").tag("title"); Text("Number").tag("number") }
            } label: { Label("Filters", systemImage: "line.3.horizontal.decrease") }
            Toggle(isOn: $selectingItems) { Label("Select items", systemImage: "checkmark.square") }.toggleStyle(.button).disabled(layout == "roadmap")
            if let grouping {
                Picker("Group by", selection: Binding(get: { grouping.id }, set: { groupID = $0 })) { ForEach(detail.fields.filter { !$0.options.isEmpty }) { field in Text(field.name).tag(field.id) } }.frame(maxWidth: 220)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 14).disabled(locked)
    }
    private func workspace(_ detail: HubDetail) -> some View {
        HStack(spacing: 0) {
            Group {
                if layout == "table" { ProjectTaskTable(rows: rows, fields: tableFields, selectedID: selectedID, selectedItems: selectedItems, select: select, edit: editField) }
                else if layout == "roadmap" { ProjectRoadmap(rows: rows, fields: detail.fields, select: select) }
                else { board(detail) }
            }.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            if width >= 1080, let selected { Divider(); inspector(selected, detail: detail).frame(width: 325) }
        }
    }
    private func board(_ detail: HubDetail) -> some View {
        var filtered = detail; filtered.rows = rows
        let columns = HostingHubAPI.projectColumns(filtered, fieldID: grouping?.id)
        return GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                        ProjectBoardColumn(column: column, index: index,
                            width: max(255, min(310, (geometry.size.width - 64) / CGFloat(max(1, min(columns.count, 3))) - 16)),
                            height: max(280, geometry.size.height - 40), localRepository: localRepository,
                            selectedID: selectedID, selectedItems: selectedItems, selectingItems: selectingItems, select: select,
                            add: { compose(store.hubProvider == .github ? .draft : .link) },
                            move: { identifiers in
                                guard !locked, let field = grouping, let identifier = identifiers.first,
                                      let row = detail.rows.first(where: { $0.id == identifier }) else { return false }
                                updateField(field, row: row, detail: detail, value: column.id.isEmpty ? nil : column.id)
                                return true
                            })
                    }
                }.padding(20)
            }.accessibilityLabel("Project board")
        }
    }
    private func inspector(_ row: HubProjectRow, detail: HubDetail) -> some View {
        let stamp = store.hubActionStamp
        return ProjectTaskInspector(store: store, detail: detail, row: row, close: { selectedID = nil; compactInspector = false }, editField: { field in editField(row, field) }, editDraft: { compose(.draft, row: row) }, archive: {
            write(row.archived ? "Restore archived item?" : "Archive project item?", message: row.title) { c in try await HostingHubAPI.archiveProjectItem(c, detail: detail, row: row, archived: !row.archived) }
        }, remove: {
            write("Remove item from project?", message: row.title + "\n" + String(localized: "The issue or pull request is kept in its repository."), destructive: true) { c in try await HostingHubAPI.deleteProjectItem(c, detail: detail, row: row) }
        }, reorder: { after in
            guard stamp == store.hubActionStamp else { return }
            write("Move project item?", message: row.title + "\n" + (after?.title ?? String(localized: "Move to top"))) { c in
                try await HostingHubAPI.moveProjectItem(c, detail: detail, row: row, afterRow: after)
                filter.sort = "manual"
            }
        }, convert: { repository in
            guard stamp == store.hubActionStamp else { store.hostingHub.error = String(localized: "The repository or account changed. Reopen this action."); return }
            write("Convert draft to issue?", message: row.title + "\n" + repository) { c in
                try await HostingHubAPI.convertProjectDraftToIssue(c, detail: detail, row: row, repository: repository)
            }
        })
    }
    private func footer(_ detail: HubDetail) -> some View {
        HStack {
            Text(verbatim: String(localized: "{0} of {1} loaded items").replacingOccurrences(of: "{0}", with: rows.count.formatted()).replacingOccurrences(of: "{1}", with: detail.rows.count.formatted())).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if detail.more { Button("Load more items") { Task { await store.selectHostingHubItem(detail.item, append: true) } }.controlSize(.small).disabled(locked) }
            Label("Synced with GitHub", systemImage: "checkmark.icloud").font(.caption).foregroundStyle(.secondary).opacity(store.hubProvider == .github ? 1 : 0)
        }.padding(.horizontal, 24).padding(.vertical, 10).background(Color.secondary.opacity(0.025))
    }
    private var loadingState: some View {
        VStack(spacing: 16) { ProgressView(); Text("Loading your project workspace…").font(.callout).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
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
                        fieldEditor = ProjectFieldRequest(row: first, field: field, context: store.hubActionStamp, clearable: store.hubProvider == .github, bulkRows: items.filter { !$0.archived })
                    }
                }
            }.disabled(items.isEmpty || items.allSatisfy(\.archived))
            if store.hubProvider == .github {
                Button("Archive selected") {
                    write("Archive selected items?", message: items.map(\.title).joined(separator: "\n")) { c in
                        try await performBatch(items.filter { !$0.archived }) { row in try await HostingHubAPI.archiveProjectItem(c, detail: detail, row: row, archived: true) }
                        selectedItems = []
                    }
                }.disabled(items.isEmpty)
                if items.contains(where: \.archived) {
                    Button("Restore selected") {
                        write("Restore selected items?", message: items.map(\.title).joined(separator: "\n")) { c in
                            try await performBatch(items.filter(\.archived)) { row in try await HostingHubAPI.archiveProjectItem(c, detail: detail, row: row, archived: false) }
                            selectedItems = []
                        }
                    }
                }
                Button("Remove selected…", role: .destructive) {
                    write("Remove selected items from project?", message: items.map(\.title).joined(separator: "\n") + "\n" + String(localized: "The issue or pull request is kept in its repository."), destructive: true) { c in
                        try await performBatch(items) { row in try await HostingHubAPI.deleteProjectItem(c, detail: detail, row: row) }
                        selectedItems = []
                    }
                }.disabled(items.isEmpty)
            }
        }.controlSize(.small).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 10).background(Color.accentColor.opacity(0.045)).disabled(locked || hub.uncertainWrite)
    }
    private func compose(_ mode: ProjectComposerRequest.Mode, row: HubProjectRow? = nil) { guard !hub.uncertainWrite else { return }; composer = ProjectComposerRequest(mode: mode, row: row, context: store.hubActionStamp) }
    private func editField(_ row: HubProjectRow, _ field: HubProjectField) { guard !hub.uncertainWrite, !row.archived, row.kind != .redacted else { return }; fieldEditor = ProjectFieldRequest(row: row, field: field, context: store.hubActionStamp, clearable: store.hubProvider == .github) }
    private func selectInitialProject() async {
        guard store.hostingHub.section == .projects, store.hostingHub.detail == nil, !store.hostingHub.detailLoading, store.hostingHub.error == nil, let first = store.hostingHub.items.first else { return }
        await store.selectHostingHubItem(first)
    }
    private func manage(_ tab: ProjectManagementTab) { guard !locked else { return }; managementTab = tab; managing = true }
    private func apply(_ view: HubProjectView) { sharedViewID = view.id; layout = view.layout == .board ? "board" : view.layout == .table ? "table" : "roadmap"; groupID = view.groupFieldIDs.first ?? "" }
    private func loadSharedViews() async {
        guard store.hubProvider == .github, let detail, store.hubCredentialState == .ready else { return }
        let read = UUID(), stamp = store.hubActionStamp; viewsRead = read
        do {
            let result = try await HostingHubAPI.projectViews(store.hubAccess(), detail: detail)
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
    private func updateFields(_ field: HubProjectField, rows: [HubProjectRow], detail: HubDetail, value: String?) {
        let option = field.options.first { $0.id == value }?.name ?? value ?? String(localized: "Not set")
        write("Update selected project items?", message: field.name + ": " + option + "\n" + rows.map(\.title).joined(separator: "\n")) { c in
            try await performBatch(rows) { row in
                if c.target.provider == .gitlab { try await HostingHubAPI.move(c, detail: detail, row: row, field: field, option: value ?? "__open") }
                else { try await HostingHubAPI.updateProjectField(c, detail: detail, row: row, field: field, value: value) }
            }
            selectedItems = []
        }
    }
    private func updateField(_ field: HubProjectField, row: HubProjectRow, detail: HubDetail, value: String?) {
        let option = field.options.first { $0.id == value }?.name ?? value ?? String(localized: "Not set")
        let reopening = store.hubProvider == .gitlab && (value == nil || value == "__open")
        let message = row.title + "\n" + field.name + ": " + option + (reopening ? "\n" + String(localized: "This reopens the issue and removes its board column labels.") : "")
        write(reopening ? "Move issue to the Open column?" : "Update project field?", message: message) { c in
            if c.target.provider == .gitlab { try await HostingHubAPI.move(c, detail: detail, row: row, field: field, option: value ?? "__open") }
            else { try await HostingHubAPI.updateProjectField(c, detail: detail, row: row, field: field, value: value) }
        }
    }
    private func write(_ title: String.LocalizationValue, message: String, destructive: Bool = false, action: @escaping (HubAccess) async throws -> Void) {
        guard !locked, !hub.uncertainWrite else { return }
        let stamp = store.hubActionStamp
        store.confirm = ConfirmRequest(title: String(localized: title), message: message, actionTitle: String(localized: "Confirm"), destructive: destructive) { await store.hostingHubAction(expected: stamp, action: action) }
    }
}
