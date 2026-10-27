import SwiftUI

struct ProjectComposerRequest: Identifiable {
    enum Mode { case draft, link }
    let id = UUID()
    let mode: Mode
    var row: HubProjectRow?
    var context = ""
}
struct ProjectFieldRequest: Identifiable {
    let id = UUID()
    let row: HubProjectRow
    let field: HubProjectField
    var context = ""
    var clearable = true
    var bulkRows: [HubProjectRow] = []
}

struct ProjectItemComposer: View {
    @Bindable var store: RepoStore
    let request: ProjectComposerRequest
    let save: (String, String, String) async -> String?
    @Environment(\.dismiss) private var dismiss
    @ViewState private var title = ""
    @ViewState private var bodyText = ""
    @ViewState private var url = ""
    @ViewState private var query = ""
    @ViewState private var candidates: [CollaborationInboxItem] = []
    @ViewState private var loading = false
    @ViewState private var saving = false
    @ViewState private var error: String?
    @ViewState private var more = false
    @ViewState private var page = 0
    private var linking: Bool { request.mode == .link }
    private var heading: String {
        if linking { return String(localized: "Add existing work") }
        if store.hubIsLocalProject { return request.row == nil ? String(localized: "New task") : String(localized: "Edit task") }
        return request.row == nil ? String(localized: "New draft task") : String(localized: "Edit draft")
    }
    private var actionTitle: String {
        if linking { return String(localized: "Add to project") }
        return request.row == nil ? String(localized: "Create task") : String(localized: "Save changes")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: linking ? "link" : "square.and.pencil")
                    .font(.system(size: 20, weight: .medium)).foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44).background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 6) {
                    Text(heading).font(.system(size: 19, weight: .semibold))
                    Text(store.hostingHub.detail?.item.title ?? "").font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if linking { linkForm } else { taskForm }
                    if let error {
                        Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }.disabled(saving)
            Divider()
            HStack(spacing: 12) {
                if saving { ProgressView().controlSize(.small); Text("Saving changes…").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button(actionTitle) { Task { await submit() } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(saving || (linking ? url.trimmed.isEmpty : title.trimmed.isEmpty))
            }.controlSize(.large).padding(.horizontal, 24).padding(.vertical, 16)
        }.frame(width: 590, height: 560).background(Color(nsColor: .windowBackgroundColor))
            .interactiveDismissDisabled(saving)
            .task { title = request.row?.title ?? ""; bodyText = request.row?.body ?? ""; if linking { await loadCandidates() } }
    }
    private var taskForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Capture an idea now. Keep its status, dates and notes beside the code.").font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text("Task title").font(.callout.weight(.semibold))
                TextField("Task title", text: $title).textFieldStyle(.roundedBorder).controlSize(.large)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Description").font(.callout.weight(.semibold))
                TextEditor(text: $bodyText).font(.body).scrollContentBackground(.hidden).padding(8).frame(minHeight: 180)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.15)))
                    .accessibilityLabel("Task description")
                Text("Markdown is supported.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var linkForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pick an issue from the current repository, or paste an issue or pull request URL.").font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("Search repository issues", text: $query).textFieldStyle(.roundedBorder).onSubmit { Task { await loadCandidates() } }
                Button("Search") { Task { await loadCandidates() } }.disabled(loading)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(candidates) { item in
                        Button { url = item.url } label: {
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: url == item.url ? "checkmark.circle.fill" : "circle").foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title).font(.callout.weight(.medium)).lineLimit(2)
                                    Text("#\(item.number) · \(item.state)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(url == item.url ? Color.accentColor.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                    }
                    if loading { HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }.padding(16) }
                    if more { Button("Load more") { Task { await loadCandidates(append: true) } }.disabled(loading).padding(8) }
                    if candidates.isEmpty && !loading { Text("No issues found in this repository.").font(.callout).foregroundStyle(.secondary).padding(16) }
                }
            }.frame(height: 190).background(Color.secondary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 8) {
                Text("Issue or pull request URL").font(.callout.weight(.semibold))
                TextField("Issue or pull request URL", text: $url).textFieldStyle(.roundedBorder)
            }
        }
    }
    private func submit() async {
        guard !saving else { return }
        saving = true; error = nil
        let result = await save(title, bodyText, url)
        saving = false
        if let result { error = result } else { dismiss() }
    }
    private func loadCandidates(append: Bool = false) async {
        guard !loading, !saving, request.context == store.hubActionStamp else { return }
        guard let target = store.target, let account = store.hubAccount, AccountStore.shared.candidates(for: target).contains(where: { $0.id == account.id }), let token = AccountStore.shared.token(for: account) else { return }
        let stamp = request.context, next = append ? page + 1 : 1
        let access = ReviewAccess(target: target, token: token, apiBase: account.apiBase, me: account.username, isCurrent: { store.hubActionStamp == stamp })
        loading = true; error = nil
        defer { loading = false }
        do {
            let result = try await WorkspaceOperations.issues(access, scope: "open", search: query, page: next)
            guard !Task.isCancelled, store.hubActionStamp == stamp else { return }
            candidates = append ? candidates + result.0.filter { item in !candidates.contains { $0.id == item.id } } : result.0
            more = result.1; page = next
        } catch { if store.hubActionStamp == stamp { self.error = HostingHubAPI.error(error, token: token) } }
    }
}

struct ProjectFieldEditor: View {
    let request: ProjectFieldRequest
    let save: (String?) async -> String?
    @Environment(\.dismiss) private var dismiss
    @ViewState private var value = ""
    @ViewState private var saving = false
    @ViewState private var error: String?
    private var invalidDate: Bool { request.field.kind == .date && !value.isEmpty && ProjectSchedule.parseDay(value) == nil }
    private var actionTitle: String { request.bulkRows.isEmpty ? String(localized: "Save changes") : String(localized: "Apply to selected") }
    private var symbol: String {
        switch request.field.kind { case .date: return "calendar"; case .number: return "number"; case .singleSelect, .iteration: return "list.bullet"; default: return "text.alignleft" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol).font(.system(size: 20, weight: .medium)).foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44).background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 6) {
                    Text(request.field.name).font(.system(size: 19, weight: .semibold))
                    Text(request.bulkRows.isEmpty ? request.row.title : String(localized: "{0} selected").replacingOccurrences(of: "{0}", with: request.bulkRows.count.formatted()))
                        .font(.callout).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }.padding(24)
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    if [.singleSelect, .iteration].contains(request.field.kind) {
                        Picker("Value", selection: $value) {
                            Text("Not set").tag("").disabled(!request.clearable)
                            ForEach(request.field.options) { option in Text(option.name).tag(option.id) }
                        }.pickerStyle(.menu)
                    } else if request.field.kind == .date { dateForm }
                    else {
                        Text("Value").font(.callout.weight(.semibold))
                        TextField("Value", text: $value).textFieldStyle(.roundedBorder).controlSize(.large)
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                if let error {
                    Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }.padding(.horizontal, 24).padding(.bottom, 24).disabled(saving)
            Divider()
            HStack(spacing: 12) {
                if request.clearable { Button("Clear value") { value = "" }.buttonStyle(.borderless).disabled(saving || value.isEmpty) }
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button(actionTitle) { Task { await submit() } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(saving || invalidDate || !request.clearable && value.isEmpty)
            }.controlSize(.large).padding(.horizontal, 24).padding(.vertical, 16)
        }.frame(width: 500).background(Color(nsColor: .windowBackgroundColor)).interactiveDismissDisabled(saving)
            .onAppear { value = request.row.values[request.field.id] ?? request.row.statuses[request.field.id] ?? "" }
    }
    private var dateForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            DatePicker("Task date", selection: Binding(get: {
                ProjectSchedule.parseDay(value) ?? ProjectSchedule.parseDay(ProjectSchedule.today()) ?? Date()
            }, set: { value = ProjectSchedule.dayString($0) }), displayedComponents: .date)
                .datePickerStyle(.compact).environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
            HStack(spacing: 8) {
                Button("Today") { value = ProjectSchedule.today() }
                Button("Tomorrow") { value = ProjectSchedule.addDays(ProjectSchedule.today(), 1) ?? "" }
                Button("In 1 week") { value = ProjectSchedule.addDays(ProjectSchedule.today(), 7) ?? "" }
            }.controlSize(.small)
            TextField("YYYY-MM-DD", text: $value).textFieldStyle(.roundedBorder).accessibilityLabel("Task date in YYYY-MM-DD")
            if invalidDate { Text("Choose a valid date or clear the value.").font(.caption).foregroundStyle(.red) }
            else {
                Text(value.isEmpty ? String(localized: "No date set. Choose a date or use a quick option above.") : String(localized: "Use YYYY-MM-DD. Clear the value to remove this date."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func submit() async {
        guard !saving, !invalidDate, request.clearable || !value.isEmpty else { return }
        saving = true; error = nil
        let result = await save(value.isEmpty ? nil : value)
        saving = false
        if let result { error = result } else { dismiss() }
    }
}
