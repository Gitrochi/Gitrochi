import SwiftUI

enum ProjectManagementTab: String, CaseIterable, Identifiable {
    case overview, fields, views, newProject
    var id: String { rawValue }
    var title: String { switch self { case .overview: return String(localized: "Project settings"); case .fields: return String(localized: "Fields"); case .views: return String(localized: "Shared views"); case .newProject: return String(localized: "New project") } }
}
private struct ProjectManagementMutation {
    let title: String
    let message: String
    let expected: String
    var destructive = false
    let action: (HubAccess) async throws -> Void
}

/// Shared settings are confirmed separately from local filters and view preferences.
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
    @ViewState private var error: String?
    @ViewState private var pending: ProjectManagementMutation?
    @ViewState private var origin = ""
    @ViewState private var projectID: String?
    @ViewState private var createdProject: HubItem?
    private var detail: HubDetail? { store.hostingHub.detail }
    private var locked: Bool { store.hostingHub.busy || store.hostingHub.loading || store.hostingHub.detailLoading || reading || store.hostingHub.uncertainWrite }
    private var validContext: Bool { store.hubContextStamp == origin && (tab == .newProject || detail?.item.id == projectID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { VStack(alignment: .leading, spacing: 5) { Text(tab.title).font(.title2.bold()); Text(detail?.item.title ?? store.hubProjectOwner).font(.callout).foregroundStyle(.secondary) }; Spacer(); if locked { ProgressView().controlSize(.small) }; Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(22)
            if detail != nil, tab != .newProject { Picker("Project settings", selection: $tab) { ForEach(ProjectManagementTab.allCases.filter { $0 != .newProject }) { value in Text(value.title).tag(value) } }.labelsHidden().pickerStyle(.segmented).padding(.horizontal, 22).padding(.bottom, 16) }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !validContext { Text("The repository or account changed. Reopen this action.").foregroundStyle(.red) }
                    if let error = error ?? store.hostingHub.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                    if tab == .newProject { newProjectForm }
                    else if let detail {
                        switch tab { case .overview: settingsForm(detail); case .fields: fieldsForm(detail); case .views: viewsForm(detail); case .newProject: EmptyView() }
                    }
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }.disabled(locked || !validContext)
        }.frame(width: 690, height: 650)
        .onAppear {
            tab = detail == nil ? .newProject : initialTab; origin = store.hubContextStamp; projectID = detail?.item.id
            readSettings(); if let initialView { edit(initialView) }
        }
        .task(id: tab) { if tab == .views { await loadViews() } }
        .alert(pending?.title ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Cancel", role: .cancel) { pending = nil }
            Button("Confirm", role: pending?.destructive == true ? .destructive : nil) {
                guard let mutation = pending else { return }; pending = nil
                Task {
                    let saved = await store.hostingHubAction(expected: mutation.expected, refreshList: tab == .newProject, action: mutation.action)
                    if saved {
                        error = nil
                        if let createdProject { await store.selectHostingHubItem(createdProject); dismiss() }
                        changed(); readSettings(); if tab == .views { await loadViews() }
                    }
                }
            }
        } message: { Text(pending?.message ?? "") }
    }

    private var newProjectForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(store.hubProjectOwner, systemImage: "person.crop.square").font(.callout.weight(.semibold))
            TextField("Project name", text: $newTitle).textFieldStyle(.roundedBorder)
            Text("The project will be created for the selected owner. You can configure fields and views after creating it.").font(.callout).foregroundStyle(.secondary)
            Button("Create project…") {
                confirm("Create project?", message: store.hubProjectOwner + "\n" + newTitle) { c in
                    createdProject = try await HostingHubAPI.createProject(c, title: newTitle)
                }
            }.buttonStyle(.borderedProminent).disabled(newTitle.trimmed.isEmpty)
        }
    }
    private func settingsForm(_ detail: HubDetail) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            fieldLabel("Name") { TextField("Name", text: $title).textFieldStyle(.roundedBorder) }
            fieldLabel("Short description") { TextField("Short description", text: $summary).textFieldStyle(.roundedBorder) }
            fieldLabel("Project overview") { TextEditor(text: $readme).font(.body).frame(height: 170).padding(6).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.18))) }
            Toggle("Public project", isOn: $isPublic)
            Text("Public projects are visible to everyone. Private repository items keep their repository permissions.").font(.caption).foregroundStyle(.secondary)
            Toggle("Closed project", isOn: $closed)
            Button("Review and save") {
                let input = HubProjectSettingsInput(title: title, shortDescription: summary, readme: readme, isPublic: isPublic, closed: closed)
                confirm("Save project settings?", message: title + "\n" + (isPublic ? String(localized: "Public project") : String(localized: "Private project"))) { c in try await HostingHubAPI.saveProjectSettings(c, detail: detail, input: input) }
            }.buttonStyle(.borderedProminent).disabled(title.trimmed.isEmpty)
        }
    }
    private func fieldsForm(_ detail: HubDetail) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Fields define the information your team tracks on every task.").font(.callout).foregroundStyle(.secondary)
            ForEach(detail.fields.filter { [.text, .number, .date, .singleSelect].contains($0.kind) }) { field in
                HStack { VStack(alignment: .leading, spacing: 3) { Text(field.name).fontWeight(.medium); Text(fieldTypeName(field.kind)).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Edit") { edit(field) }; Button("Delete…", role: .destructive) { confirm("Delete project field?", message: field.name + "\n" + String(localized: "This removes the field and its values from the shared project."), destructive: true) { c in try await HostingHubAPI.deleteProjectCustomField(c, detail: detail, field: field) } } }.padding(10).background(Color.secondary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            }
            Divider()
            HStack { Text(editingField == nil ? String(localized: "New field") : String(localized: "Edit field")).font(.headline); Spacer(); if editingField != nil { Button("New field") { editingField = nil; fieldName = ""; options = [] } } }
            TextField("Field name", text: $fieldName).textFieldStyle(.roundedBorder)
            Picker("Field type", selection: $fieldKind) { Text("Text").tag(HubProjectFieldKind.text); Text("Number").tag(HubProjectFieldKind.number); Text("Date").tag(HubProjectFieldKind.date); Text("Single select").tag(HubProjectFieldKind.singleSelect) }.disabled(editingField != nil)
            if fieldKind == .singleSelect {
                ForEach(options.indices, id: \.self) { index in
                    HStack { TextField("Option name", text: Binding(get: { options[index].name }, set: { options[index].name = $0 })).textFieldStyle(.roundedBorder); Button { options.remove(at: index) } label: { Image(systemName: "minus.circle") }.help("Remove option") }
                }
                Button("Add option") { options.append(HubProjectFieldOptionInput(name: "")) }
            }
            Button("Review and save") {
                let input = HubProjectFieldInput(name: fieldName, kind: fieldKind, options: fieldKind == .singleSelect ? options : [])
                let previous = editingField
                confirm(previous == nil ? "Create project field?" : "Update project field?", message: fieldName) { c in try await HostingHubAPI.saveProjectCustomField(c, detail: detail, input: input, previous: previous) }
            }.buttonStyle(.borderedProminent).disabled(fieldName.trimmed.isEmpty || fieldKind == .singleSelect && (options.isEmpty || options.contains { $0.name.trimmed.isEmpty }))
        }
    }
    private func viewsForm(_ detail: HubDetail) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Shared views are saved in GitHub for your whole team.").font(.callout).foregroundStyle(.secondary)
            ForEach(views) { view in
                HStack { VStack(alignment: .leading, spacing: 3) { Text(view.name).fontWeight(.medium); Text(view.filter.isEmpty ? layoutName(view.layout) : view.filter).font(.caption).foregroundStyle(.secondary).lineLimit(2) }; Spacer(); Button("Edit") { edit(view) }; Button("Delete…", role: .destructive) { confirm("Delete shared view?", message: view.name, destructive: true) { c in try await HostingHubAPI.deleteProjectView(c, detail: detail, view: view) } } }.padding(10).background(Color.secondary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            }
            if viewsMore { Button("Load more views") { Task { await loadViews(append: true) } } }
            Divider()
            HStack { Text(editingView == nil ? String(localized: "New shared view") : String(localized: "Edit shared view")).font(.headline); Spacer(); if editingView != nil { Button("New shared view") { editingView = nil; viewName = ""; viewFilter = ""; visibleFields = [] } } }
            TextField("View name", text: $viewName).textFieldStyle(.roundedBorder)
            Picker("Layout", selection: $viewLayout) { Text("Board").tag(HubProjectViewLayout.board); Text("Table").tag(HubProjectViewLayout.table); Text("Roadmap").tag(HubProjectViewLayout.roadmap) }
            TextField("GitHub filter", text: $viewFilter, prompt: Text("is:issue assignee:@me")).textFieldStyle(.roundedBorder)
            Text("GitHub filters are preserved exactly. Native search and metrics apply to loaded items; open the GitHub view to run its full filter.").font(.caption).foregroundStyle(.secondary)
            Text("Visible fields").font(.callout.weight(.medium))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading) {
                ForEach(detail.fields) { field in Toggle(field.name, isOn: Binding(get: { visibleFields.contains(field.id) }, set: { if $0 { if !visibleFields.contains(field.id) { visibleFields.append(field.id) } } else { visibleFields.removeAll { $0 == field.id } } })).font(.caption) }
            }
            Button("Review and save") {
                let input = HubProjectViewInput(name: viewName, layout: viewLayout, filter: viewFilter, visibleFieldIDs: visibleFields), previous = editingView
                confirm(previous == nil ? "Create shared view?" : "Save shared view?", message: viewName + "\n" + viewFilter) { c in try await HostingHubAPI.saveProjectView(c, detail: detail, input: input, previous: previous) }
            }.buttonStyle(.borderedProminent).disabled(viewName.trimmed.isEmpty)
        }
    }
    private func fieldLabel<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View { VStack(alignment: .leading, spacing: 6) { Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary); content() } }
    private func confirm(_ title: String.LocalizationValue, message: String, destructive: Bool = false, action: @escaping (HubAccess) async throws -> Void) {
        guard validContext, !locked else { return }
        pending = ProjectManagementMutation(title: String(localized: title), message: message, expected: store.hubActionStamp, destructive: destructive, action: action)
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
        switch layout {
        case .board: return String(localized: "Board")
        case .table: return String(localized: "Table")
        case .roadmap: return String(localized: "Roadmap")
        }
    }
    private func readSettings() {
        guard let detail else { return }; title = detail.item.title; summary = detail.item.body
        readme = detail.item.data["readme"] as? String ?? ""; isPublic = detail.item.data["public"] as? Bool ?? false; closed = detail.item.data["closed"] as? Bool ?? false
    }
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
