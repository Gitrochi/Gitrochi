import SwiftUI

enum ProjectManagementTab: String, CaseIterable, Identifiable {
    case overview, fields, views, newProject
    var id: String { rawValue }
    var title: String { switch self { case .overview: return String(localized: "Project settings"); case .fields: return String(localized: "Fields"); case .views: return String(localized: "Shared views"); case .newProject: return String(localized: "New project") } }
}
private struct ProjectManagementMutation: Identifiable {
    let id = UUID()
    let title: String
    let projectTitle: String
    let message: String
    let items: [String]
    let actionTitle: String
    let expected: String
    var destructive = false
    var refreshList = false
    var deletesLocal = false
    let action: (HubAccess) async throws -> Void
}

/// Settings save in place; consequential actions keep their scope beside the final button.
struct ProjectManagementSheet: View {
    @Bindable var store: RepoStore
    var initialTab: ProjectManagementTab = .overview
    var initialView: HubProjectView?
    let changed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @ViewState private var tab: ProjectManagementTab = .overview
    @ViewState private var title = ""
    @ViewState private var summary = ""
    @ViewState private var readme = ""
    @ViewState private var isPublic = false
    @ViewState private var closed = false
    @ViewState private var newTitle = ""
    @ViewState private var fieldName = ""
    @ViewState private var fieldKind: HubProjectFieldKind = .text
    @ViewState private var editingField: HubProjectField?
    @ViewState private var options: [HubProjectFieldOptionInput] = []
    @ViewState private var views: [HubProjectView] = []
    @ViewState private var viewName = ""
    @ViewState private var viewLayout: HubProjectViewLayout = .board
    @ViewState private var viewFilter = ""
    @ViewState private var visibleFields: [String] = []
    @ViewState private var editingView: HubProjectView?
    @ViewState private var viewsMore = false
    @ViewState private var viewsCursor: String?
    @ViewState private var reading = false
    @ViewState private var saving = false
    @ViewState private var error: String?
    @ViewState private var pending: ProjectManagementMutation?
    @ViewState private var origin = ""
    @ViewState private var projectID: String?
    @ViewState private var createdProject: HubItem?
    private var detail: HubDetail? { store.hostingHub.detail }
    private var locked: Bool { saving || store.hostingHub.busy || store.hostingHub.loading || store.hostingHub.detailLoading || reading || store.hostingHub.uncertainWrite }
    private var validContext: Bool { store.hubContextStamp == origin && (tab == .newProject || detail?.item.id == projectID) }
    private var primaryTitle: String {
        switch tab {
        case .overview: return String(localized: "Save changes")
        case .fields: return editingField == nil ? String(localized: "Create field") : String(localized: "Save changes")
        case .views: return editingView == nil ? String(localized: "Create shared view") : String(localized: "Save changes")
        case .newProject: return String(localized: "Review creation")
        }
    }
    private var canSave: Bool {
        guard validContext, !locked else { return false }
        switch tab {
        case .overview: return !title.trimmed.isEmpty
        case .fields: return !fieldName.trimmed.isEmpty && (fieldKind != .singleSelect || !options.isEmpty && !options.contains { $0.name.trimmed.isEmpty })
        case .views: return !viewName.trimmed.isEmpty
        case .newProject: return !newTitle.trimmed.isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: tab == .fields ? "list.bullet.rectangle" : tab == .views ? "rectangle.3.group" : "slider.horizontal.3")
                    .font(.system(size: 20, weight: .medium)).foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44).background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 6) {
                    Text(tab.title).font(.system(size: 19, weight: .semibold))
                    Text(detail?.item.title ?? store.hubProjectOwner).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }.padding(24)
            if detail != nil, tab != .newProject, !store.hubIsLocalProject {
                Picker("Project settings", selection: $tab) {
                    ForEach(ProjectManagementTab.allCases.filter { $0 != .newProject }) { value in Text(value.title).tag(value) }
                }.labelsHidden().pickerStyle(.segmented).padding(.horizontal, 24).padding(.bottom, 20).disabled(locked)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !validContext { errorMessage(String(localized: "The repository or account changed. Reopen this action.")) }
                    if let message = error ?? store.hostingHub.error { errorMessage(message) }
                    if tab == .newProject { newProjectForm }
                    else if let detail {
                        switch tab { case .overview: settingsForm(detail); case .fields: fieldsForm(detail); case .views: viewsForm(detail); case .newProject: EmptyView() }
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }.disabled(locked || !validContext)
            Divider()
            HStack(spacing: 12) {
                if locked { ProgressView().controlSize(.small) }
                if saving { Text("Saving changes…").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving || store.hostingHub.busy)
                Button(primaryTitle) { saveCurrentForm() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!canSave)
            }.controlSize(.large).padding(.horizontal, 24).padding(.vertical, 16)
        }.frame(width: 700, height: store.hubIsLocalProject && tab == .overview ? 430 : 650).background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(saving || store.hostingHub.busy)
        .onAppear {
            tab = detail == nil ? .newProject : initialTab; origin = store.hubContextStamp; projectID = detail?.item.id
            readSettings(); if let initialView { edit(initialView) }
        }
        .task(id: tab) { error = nil; if tab == .views { await loadViews() } }
        .sheet(item: $pending) { mutation in
            ProjectActionReviewSheet(title: mutation.title, project: mutation.projectTitle,
                                     summary: mutation.message, items: mutation.items, actionTitle: mutation.actionTitle, destructive: mutation.destructive) {
                await perform(mutation)
            }
        }
    }

    private var newProjectForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(store.hubProjectOwner, systemImage: "person.crop.square").font(.callout.weight(.semibold))
            fieldLabel("Project name") { TextField("Project name", text: $newTitle).textFieldStyle(.roundedBorder).controlSize(.large) }
            Text("The project will be created for the selected owner. You can configure fields and views after creating it.").font(.callout).foregroundStyle(.secondary)
        }
    }
    private func settingsForm(_ detail: HubDetail) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 16) {
                fieldLabel("Name") { TextField("Name", text: $title).textFieldStyle(.roundedBorder).controlSize(.large) }
                fieldLabel("Short description") { TextField("Short description", text: $summary, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder) }
                if !store.hubIsLocalProject {
                    fieldLabel("Project overview") {
                        TextEditor(text: $readme).font(.body).scrollContentBackground(.hidden).frame(height: 140).padding(8)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.15)))
                    }
                }
            }.padding(16).background(Color.secondary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            if !store.hubIsLocalProject {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Public project", isOn: $isPublic)
                    Text("Public projects are visible to everyone. Private repository items keep their repository permissions.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Divider()
                    Toggle("Closed project", isOn: $closed)
                }.padding(16).background(Color.secondary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            } else {
                HStack(alignment: .center, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Delete local project").font(.callout.weight(.semibold))
                        Text("This permanently deletes its tasks from this device.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("Delete local project…", role: .destructive) {
                        confirm("Delete local project?", message: String(localized: "This permanently deletes its tasks from this device."),
                                items: [detail.item.title], actionTitle: String(localized: "Delete local project"), destructive: true, refreshList: true, deletesLocal: true) { _ in
                            try await LocalProjectStore.shared.deleteProject(detail: detail)
                        }
                    }
                }.padding(16).background(Color.red.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
    private func fieldsForm(_ detail: HubDetail) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Fields define the information your team tracks on every task.").font(.callout).foregroundStyle(.secondary)
            VStack(spacing: 8) {
                ForEach(detail.fields.filter { [.text, .number, .date, .singleSelect].contains($0.kind) }) { field in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(field.name).font(.callout.weight(.medium))
                            Text(fieldTypeName(field.kind)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit") { edit(field) }
                        Button("Delete…", role: .destructive) {
                            confirm("Delete project field?", message: String(localized: "This removes the field and its values from the shared project."),
                                    items: [field.name], actionTitle: String(localized: "Delete field"), destructive: true) { c in
                                try await HostingHubAPI.deleteProjectCustomField(c, detail: detail, field: field)
                            }
                        }
                    }.padding(12).background(Color.secondary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(editingField == nil ? String(localized: "New field") : String(localized: "Edit field")).font(.headline)
                    Spacer()
                    if editingField != nil { Button("New field") { resetField() } }
                }
                fieldLabel("Field name") { TextField("Field name", text: $fieldName).textFieldStyle(.roundedBorder) }
                Picker("Field type", selection: $fieldKind) {
                    Text("Text").tag(HubProjectFieldKind.text); Text("Number").tag(HubProjectFieldKind.number)
                    Text("Date").tag(HubProjectFieldKind.date); Text("Single select").tag(HubProjectFieldKind.singleSelect)
                }.disabled(editingField != nil)
                if fieldKind == .singleSelect {
                    ForEach(options.indices, id: \.self) { index in
                        HStack {
                            TextField("Option name", text: Binding(get: { options[index].name }, set: { options[index].name = $0 })).textFieldStyle(.roundedBorder)
                            Button { options.remove(at: index) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("Remove option")
                        }
                    }
                    Button("Add option") { options.append(HubProjectFieldOptionInput(name: "")) }
                }
            }.padding(16).background(Color.secondary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        }
    }
    private func viewsForm(_ detail: HubDetail) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Shared views are saved in GitHub for your whole team.").font(.callout).foregroundStyle(.secondary)
            VStack(spacing: 8) {
                ForEach(views) { view in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(view.name).font(.callout.weight(.medium))
                            Text(view.filter.isEmpty ? layoutName(view.layout) : view.filter).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Button("Edit") { edit(view) }
                        Button("Delete…", role: .destructive) {
                            confirm("Delete shared view?", message: view.name, items: [], actionTitle: String(localized: "Delete shared view"), destructive: true) { c in
                                try await HostingHubAPI.deleteProjectView(c, detail: detail, view: view)
                            }
                        }
                    }.padding(12).background(Color.secondary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                }
                if viewsMore { Button("Load more views") { Task { await loadViews(append: true) } } }
            }
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(editingView == nil ? String(localized: "New shared view") : String(localized: "Edit shared view")).font(.headline)
                    Spacer()
                    if editingView != nil { Button("New shared view") { resetView() } }
                }
                fieldLabel("View name") { TextField("View name", text: $viewName).textFieldStyle(.roundedBorder) }
                Picker("Layout", selection: $viewLayout) { Text("Board").tag(HubProjectViewLayout.board); Text("Table").tag(HubProjectViewLayout.table); Text("Roadmap").tag(HubProjectViewLayout.roadmap) }
                fieldLabel("GitHub filter") { TextField("GitHub filter", text: $viewFilter, prompt: Text(verbatim: "is:issue assignee:@me")).textFieldStyle(.roundedBorder) }
                Text("GitHub filters are preserved exactly. Native search and metrics apply to loaded items; open the GitHub view to run its full filter.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Visible fields").font(.callout.weight(.semibold))
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                    ForEach(detail.fields) { field in
                        Toggle(field.name, isOn: Binding(get: { visibleFields.contains(field.id) }, set: {
                            if $0 { if !visibleFields.contains(field.id) { visibleFields.append(field.id) } }
                            else { visibleFields.removeAll { $0 == field.id } }
                        })).font(.callout)
                    }
                }
            }.padding(16).background(Color.secondary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        }
    }
    private func fieldLabel<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(title).font(.callout.weight(.semibold)); content() }
    }
    private func errorMessage(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }
    private func saveCurrentForm() {
        guard canSave else { return }
        switch tab {
        case .overview:
            guard let detail else { return }
            let input = HubProjectSettingsInput(title: title, shortDescription: summary, readme: readme, isPublic: isPublic, closed: closed)
            let action: (HubAccess) async throws -> Void = { c in try await HostingHubAPI.saveProjectSettings(c, detail: detail, input: input) }
            if !store.hubIsLocalProject, isPublic, detail.item.data["public"] as? Bool != true {
                confirm("Make project public?", message: String(localized: "Public projects are visible to everyone. Private repository items keep their repository permissions."),
                        items: [title], actionTitle: String(localized: "Make public"), action: action)
            } else { saveDirect(action: action) }
        case .fields:
            guard let detail else { return }
            let input = HubProjectFieldInput(name: fieldName, kind: fieldKind, options: fieldKind == .singleSelect ? options : []), previous = editingField
            saveDirect { c in try await HostingHubAPI.saveProjectCustomField(c, detail: detail, input: input, previous: previous) }
        case .views:
            guard let detail else { return }
            let input = HubProjectViewInput(name: viewName, layout: viewLayout, filter: viewFilter, visibleFieldIDs: visibleFields), previous = editingView
            saveDirect { c in try await HostingHubAPI.saveProjectView(c, detail: detail, input: input, previous: previous) }
        case .newProject:
            let name = newTitle
            confirm("Create project?", message: String(localized: "The project will be created for the selected owner. You can configure fields and views after creating it."),
                    items: [store.hubProjectOwner, name], actionTitle: String(localized: "Create project")) { c in
                createdProject = try await HostingHubAPI.createProject(c, title: name)
            }
        }
    }
    private func saveDirect(action: @escaping (HubAccess) async throws -> Void) {
        guard validContext, !locked else { return }
        let mutation = ProjectManagementMutation(title: "", projectTitle: detail?.item.title ?? store.hubProjectOwner, message: "", items: [], actionTitle: "", expected: store.hubActionStamp, action: action)
        Task { _ = await perform(mutation) }
    }
    private func confirm(_ title: String.LocalizationValue, message: String, items: [String], actionTitle: String, destructive: Bool = false,
                         refreshList: Bool = false, deletesLocal: Bool = false, action: @escaping (HubAccess) async throws -> Void) {
        guard validContext, !locked else { return }
        pending = ProjectManagementMutation(title: String(localized: title), projectTitle: detail?.item.title ?? store.hubProjectOwner, message: message, items: items, actionTitle: actionTitle, expected: store.hubActionStamp,
                                            destructive: destructive, refreshList: refreshList, deletesLocal: deletesLocal, action: action)
    }
    private func perform(_ mutation: ProjectManagementMutation) async -> String? {
        guard validContext, mutation.expected == store.hubActionStamp, !locked else {
            return String(localized: "The repository or account changed. Reopen this action.")
        }
        saving = true; error = nil
        let saved = await store.hostingHubAction(expected: mutation.expected, refreshList: mutation.refreshList || tab == .newProject, action: mutation.action)
        saving = false
        guard saved else {
            let message = store.hostingHub.error ?? String(localized: "The repository or account changed. Reopen this action.")
            error = message; return message
        }
        error = nil; changed()
        if mutation.deletesLocal { dismiss(); return nil }
        if let createdProject { await store.selectHostingHubItem(createdProject); dismiss(); return nil }
        readSettings()
        if tab == .views { await loadViews() }
        return nil
    }
    private func fieldTypeName(_ kind: HubProjectFieldKind) -> String {
        switch kind {
        case .text: return String(localized: "Text")
        case .number: return String(localized: "Number")
        case .date: return String(localized: "Date")
        case .singleSelect: return String(localized: "Single select")
        case .iteration: return String(localized: "Iteration")
        case .unsupported: return String(localized: "Not set")
        }
    }
    private func layoutName(_ layout: HubProjectViewLayout) -> String {
        switch layout { case .board: return String(localized: "Board"); case .table: return String(localized: "Table"); case .roadmap: return String(localized: "Roadmap") }
    }
    private func readSettings() {
        guard let detail else { return }; title = detail.item.title; summary = detail.item.body
        readme = detail.item.data["readme"] as? String ?? ""; isPublic = detail.item.data["public"] as? Bool ?? false; closed = detail.item.data["closed"] as? Bool ?? false
    }
    private func resetField() { editingField = nil; fieldName = ""; fieldKind = .text; options = [] }
    private func resetView() { editingView = nil; viewName = ""; viewLayout = .board; viewFilter = ""; visibleFields = [] }
    private func edit(_ field: HubProjectField) { editingField = field; fieldName = field.name; fieldKind = field.kind; options = field.options.map { HubProjectFieldOptionInput(id: $0.id, name: $0.name) } }
    private func edit(_ view: HubProjectView) { editingView = view; viewName = view.name; viewLayout = view.layout; viewFilter = view.filter; visibleFields = view.visibleFieldIDs }
    private func loadViews(append: Bool = false) async {
        guard let detail, validContext, !reading else { return }
        reading = true; defer { reading = false }
        do {
            let stamp = store.hubActionStamp, result = try await HostingHubAPI.projectViews(store.hubAccess(), detail: detail, cursor: append ? viewsCursor : nil)
            guard stamp == store.hubActionStamp, !Task.isCancelled else { return }
            views = append ? views + result.views.filter { value in !views.contains { $0.id == value.id } } : result.views; viewsMore = result.more; viewsCursor = result.cursor
        } catch { self.error = HostingHubAPI.error(error) }
    }
}
