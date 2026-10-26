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
    let save: (String, String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @ViewState private var title = ""
    @ViewState private var bodyText = ""
    @ViewState private var url = ""
    @ViewState private var query = ""
    @ViewState private var candidates: [CollaborationInboxItem] = []
    @ViewState private var loading = false
    @ViewState private var error: String?
    @ViewState private var more = false
    @ViewState private var page = 0
    private var linking: Bool { request.mode == .link }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Image(systemName: linking ? "link" : "square.and.pencil").foregroundStyle(Color.accentColor); Text(linking ? String(localized: "Add existing work") : request.row == nil ? String(localized: "New draft task") : String(localized: "Edit draft")).font(.title2.bold()); Spacer() }
            if linking {
                Text("Pick an issue from the current repository, or paste an issue or pull request URL.").font(.callout).foregroundStyle(.secondary)
                HStack { TextField("Search repository issues", text: $query).textFieldStyle(.roundedBorder).onSubmit { Task { await loadCandidates() } }; Button("Search") { Task { await loadCandidates() } }.disabled(loading) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(candidates) { item in
                            Button { url = item.url } label: {
                                HStack(alignment: .top, spacing: 9) { Image(systemName: url == item.url ? "checkmark.circle.fill" : "circle").foregroundStyle(Color.accentColor); VStack(alignment: .leading, spacing: 4) { Text(item.title).font(.callout.weight(.medium)); Text("#\(item.number) · \(item.state)").font(.caption).foregroundStyle(.secondary) }; Spacer(minLength: 0) }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(url == item.url ? Color.accentColor.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain)
                        }
                        if loading { ProgressView().padding() }
                        if more { Button("Load more") { Task { await loadCandidates(append: true) } }.disabled(loading) }
                        if candidates.isEmpty && !loading { Text("No issues found in this repository.").font(.caption).foregroundStyle(.secondary).padding(12) }
                    }
                }.frame(maxHeight: .infinity).background(Color.secondary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                TextField("Issue or pull request URL", text: $url).textFieldStyle(.roundedBorder)
            } else {
                Text("Capture an idea now. Keep its status, dates and notes beside the code.").font(.callout).foregroundStyle(.secondary)
                TextField("Task title", text: $title).font(.title3).textFieldStyle(.roundedBorder)
                Text("Description").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                TextEditor(text: $bodyText).font(.body).padding(8).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.15))).accessibilityLabel("Task description")
                Text("Markdown is supported.").font(.caption).foregroundStyle(.secondary)
            }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("Review and save") { save(title, bodyText, url) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(linking ? url.trimmed.isEmpty : title.trimmed.isEmpty) }
        }.padding(24).frame(width: 560, height: 550)
            .task { title = request.row?.title ?? ""; bodyText = request.row?.body ?? ""; if linking { await loadCandidates() } }
    }
    private func loadCandidates(append: Bool = false) async {
        guard !loading, request.context == store.hubActionStamp else { return }
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
    let save: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @ViewState private var value = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(request.field.name).font(.title2.bold())
            Text(request.bulkRows.isEmpty ? request.row.title : String(localized: "{0} selected").replacingOccurrences(of: "{0}", with: request.bulkRows.count.formatted())).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            if [.singleSelect, .iteration].contains(request.field.kind) {
                Picker("Value", selection: $value) { Text("Not set").tag("").disabled(!request.clearable); ForEach(request.field.options) { option in Text(option.name).tag(option.id) } }.pickerStyle(.menu)
            } else {
                TextField(request.field.kind == .date ? "YYYY-MM-DD" : String(localized: "Value"), text: $value).textFieldStyle(.roundedBorder)
                if request.field.kind == .date { Text("Use YYYY-MM-DD. Clear the value to remove this date.").font(.caption).foregroundStyle(.secondary) }
            }
            HStack { if request.clearable { Button("Clear value") { save(nil) } }; Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("Review and save") { save(value.isEmpty ? nil : value) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!request.clearable && value.isEmpty) }
        }.padding(24).frame(width: 470).onAppear { value = request.row.values[request.field.id] ?? request.row.statuses[request.field.id] ?? "" }
    }
}
