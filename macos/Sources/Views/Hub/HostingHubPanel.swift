import SwiftUI

struct HostingHubPanel: View {
    @Bindable var store: RepoStore
    let section: HostingHubSection
    var onClone: ((String) -> Void)? = nil
    @ViewState private var editor: String?
    @ViewState private var release = HubReleaseInput()
    @ViewState private var gist = HubGistInput()
    @ViewState private var issueURL = ""
    @ViewState private var projectAccessAccount: HostAccount?
    @ViewState private var projectLayout = "board"
    @ViewState private var projectFieldID = ""
    private var locked: Bool { store.hostingHub.loading || store.hostingHub.detailLoading || store.hostingHub.busy }
    private var title: String { if store.hubProvider == .gitlab { switch section { case .gists: return String(localized: "Snippets"); case .organizations: return String(localized: "Groups"); case .projects: return String(localized: "Issue boards"); default: break } }; return section.title }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.title2.weight(.semibold))
                WorkbenchFlow(spacing: 10) {
                    Picker("Workspace account", selection: Binding(get: { store.hubAccount?.id ?? "" }, set: { id in editor = nil; Task { await store.selectHubAccount(id) } })) {
                        if AccountStore.shared.accounts.isEmpty { Text("No connected account").tag("") }
                        ForEach(AccountStore.shared.accounts) { a in Text("\(a.host) · @\(a.username)").tag(a.id) }
                    }.labelsHidden().frame(width: 250).disabled(locked)
                    if section == .projects, store.hubProvider == .github, let account = store.hubAccount {
                        Picker("Project scope", selection: Binding(get: { store.hubProjectEffectiveScope }, set: { scope in editor = nil; Task { await store.selectHubProjectScope(scope) } })) {
                            if let owner = store.hubProjectRepositoryOwner { Text(verbatim: String(localized: "Repository owner: {0}").replacingOccurrences(of: "{0}", with: owner)).tag("repository") }
                            Text(verbatim: String(localized: "My projects: @{0}").replacingOccurrences(of: "{0}", with: account.username)).tag("personal")
                        }.frame(maxWidth: 310).disabled(locked)
                    }
                    Button { editor = nil; Task { await store.loadHostingHub() } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh").disabled(locked)
                    if section == .releases || section == .gists { Button { startEditor(edit: false) } label: { Label("New", systemImage: "plus") }.disabled(locked || store.hubAccount == nil) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            Divider()
            if let notice = store.hostingHub.notice { noticeView(notice) }
            if let error = store.hostingHub.error {
                VStack(alignment: .leading, spacing: 10) {
                    Label { Text(error).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: store.hostingHub.projectPermissionRequired ? "lock.shield" : "exclamationmark.circle") }
                        .font(.callout).foregroundStyle(store.hostingHub.projectPermissionRequired ? Color.secondary : Color.red)
                    WorkbenchFlow(spacing: 8) {
                        if store.hostingHub.projectPermissionRequired, let account = store.hubAccount {
                            Button("Connect project access") { projectAccessAccount = account }.buttonStyle(.borderedProminent).disabled(locked)
                            Text("Approve the additional permission in GitHub, then projects will reload automatically.").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Button("Retry") { Task { if let d = store.hostingHub.detail { await store.selectHostingHubItem(d.item) } else { await store.loadHostingHub() } } }.disabled(locked)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(Color.secondary.opacity(0.06))
            }
            AdaptiveWorkbenchSplit {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Search loaded items", text: $store.hostingHub.query).textFieldStyle(.roundedBorder)
                    Text("Search filters loaded pages. Load more to search older items.").font(.caption).foregroundStyle(.secondary)
                    ScrollView { LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(store.hostingHub.filteredItems) { item in
                            Button { editor = nil; Task { await store.selectHostingHubItem(item) } } label: {
                                itemRow(item)
                            }.buttonStyle(.plain).background(RoundedRectangle(cornerRadius: 8).fill(store.hostingHub.detail?.item.id == item.id && editor == nil ? Color.accentColor.opacity(0.16) : .clear)).disabled(store.hostingHub.busy)
                        }
                        if store.hostingHub.loading { ProgressView().padding() }
                        if !store.hostingHub.loading && store.hostingHub.items.isEmpty && store.hostingHub.error == nil {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(section == .projects && store.hubProvider == .github ? String(localized: "No projects found for {0}.").replacingOccurrences(of: "{0}", with: store.hubProjectOwner) : section == .projects ? String(localized: "No projects found for this owner.") : section == .releases ? String(localized: "No releases found for this repository.") : String(localized: "No items returned by this account.")).font(.caption).foregroundStyle(.secondary)
                                if section == .projects && store.hubProvider == .github && store.hubProjectEffectiveScope == "repository" { Button("Show my projects") { Task { await store.selectHubProjectScope("personal") } }.disabled(locked) }
                            }.padding()
                        }
                        if store.hostingHub.more { Button("Load more") { Task { await store.loadHostingHub(append: true) } }.disabled(locked) }
                    } }
                }.padding(12)
            } detail: {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if editor != nil { editForm.disabled(locked) }
                        else if store.hostingHub.detailLoading && store.hostingHub.detail == nil { ProgressView().padding(30) }
                        else if let d = store.hostingHub.detail { detailView(d) }
                        else { Text(section == .projects ? String(localized: "Select a project to view its board.") : String(localized: "Select an item to see details and available actions.")).foregroundStyle(.secondary).padding(30) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(22)
                }
            }
        }
        .sheet(item: $projectAccessAccount) { account in
            GitHubBrowserLoginSheet(expectedLogin: account.username, capability: .projects) { _, _ in
                projectAccessAccount = nil
                Task { await store.activateHostingHub(.projects) }
            }
        }
        .onChange(of: store.hostingHub.uncertainWrite) { _, uncertain in if uncertain { editor = nil } }
        .task(id: section.rawValue + store.hubContextStamp) { editor = nil; issueURL = ""; await store.activateHostingHub(section) }
    }
    private func itemRow(_ item: HubItem) -> some View {
        HStack(spacing: 10) {
            if section == .organizations {
                HostingAvatar(name: item.title, username: item.subtitle, avatarURL: item.avatarURL, size: 36, style: .organization)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title).font(.callout.weight(.semibold))
                Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                if section == .projects && !item.body.isEmpty { Text(item.body).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(12).contentShape(Rectangle())
    }
    private func noticeView(_ text: String) -> some View { Text(text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(10).background(Color.secondary.opacity(0.08)).textSelection(.enabled) }
    private func safeURL(_ url: String, asset: Bool = false) -> URL? { HostingHubAPI.safeURL(provider: store.hubProvider, host: store.hubAccount?.host ?? store.target?.host ?? "", url, asset: asset) }
    private func open(_ url: String, asset: Bool = false) { if let safe = safeURL(url, asset: asset) { NSWorkspace.shared.open(safe) } }
    private func confirm(_ title: String, _ body: String, refreshList: Bool = false, destructive: Bool = false, action: @escaping (HubAccess) async throws -> Void) {
        let context = store.hubActionStamp
        store.confirm = ConfirmRequest(title: title, message: body, actionTitle: String(localized: "Confirm"), destructive: destructive) { await store.hostingHubAction(expected: context, refreshList: refreshList, action: action) }
    }
    private func startEditor(edit: Bool) {
        if section == .releases { let d = edit ? store.hostingHub.detail : nil, x = d?.item.data ?? [:]; release = HubReleaseInput(tag: HostingHubAPI.s(x, "tag_name"), name: d?.item.title ?? "", body: d?.item.body ?? "", target: HostingHubAPI.s(x, "target_commitish"), draft: store.hubProvider == .github ? x["draft"] as? Bool ?? true : false, prerelease: x["prerelease"] as? Bool ?? false) }
        else { let d = edit ? store.hostingHub.detail : nil; gist = HubGistInput(description: d?.item.body ?? "", isPublic: d?.item.data["public"] as? Bool ?? false, files: d?.files ?? [HubFile(name: "snippet.txt", content: "")]) }; editor = edit ? "edit" : "new"
    }
    @ViewBuilder private var editForm: some View {
        Text((editor == "new" ? String(localized: "New") : String(localized: "Edit")) + " · " + section.title).font(.headline)
        if section == .releases {
            LabeledContent("Tag") { TextField("Tag", text: $release.tag).textFieldStyle(.roundedBorder).disabled(editor == "edit") }
            LabeledContent("Name") { TextField("Name", text: $release.name).textFieldStyle(.roundedBorder) }
            LabeledContent("Target branch or commit") { TextField("Target branch or commit", text: $release.target).textFieldStyle(.roundedBorder).disabled(editor == "edit" && store.hubProvider == .gitlab) }
            Text("Release notes").font(.caption); TextEditor(text: $release.body).accessibilityLabel("Release notes").font(.body).frame(minHeight: 230).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
            if store.hubProvider == .github { Toggle("Draft", isOn: $release.draft); Toggle("Prerelease", isOn: $release.prerelease) }
        } else {
            LabeledContent("Description") { TextField("Description", text: $gist.description).textFieldStyle(.roundedBorder) }
            if editor == "new" { Toggle("Public", isOn: $gist.isPublic) }
            ForEach(gist.files.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 8) { TextField("File name", text: $gist.files[index].name).textFieldStyle(.roundedBorder); TextEditor(text: $gist.files[index].content).accessibilityLabel("File content").font(.system(.body, design: .monospaced)).frame(minHeight: 180).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25))); if gist.files.count > 1 { Button("Remove file") { gist.files.remove(at: index) } } }
            }
            Button("Add file") { gist.files.append(HubFile(name: "", content: "")) }
        }
        HStack { Button("Review and save") { submitEditor() }.buttonStyle(.borderedProminent).disabled(section == .releases ? release.tag.isEmpty || release.name.isEmpty : gist.files.contains { $0.name.isEmpty || $0.content.isEmpty }); Button("Cancel") { editor = nil } }.disabled(locked)
    }
    private func submitEditor() {
        let editing = editor == "edit"
        if section == .releases { let input = release, previous = editing ? store.hostingHub.detail?.item : nil; confirm(input.draft ? String(localized: "Save release draft?") : String(localized: "Publish release?"), "\(store.target?.path ?? "")\n\(input.tag) · \(input.name)\n" + (input.draft ? String(localized: "Only accounts with repository write access can see the draft.") : String(localized: "This publishes the release on the server.")), refreshList: true) { c in try await HostingHubAPI.saveRelease(c, input, previous: previous); editor = nil } }
        else { let input = gist, previous = editing ? store.hostingHub.detail : nil; confirm(editing ? String(localized: "Save gist changes?") : String(localized: "Create gist?"), input.description + "\n" + input.files.map(\.name).joined(separator: ", ") + "\n" + (input.isPublic ? String(localized: "Public: anyone can discover these files.") : String(localized: "Secret/private: anyone with a secret gist URL can read it; never include secrets.")), refreshList: true) { c in try await HostingHubAPI.saveGist(c, input, previous: previous); editor = nil } }
    }
    @ViewBuilder private func detailView(_ d: HubDetail) -> some View {
        if section == .organizations {
            HStack(spacing: 14) {
                HostingAvatar(name: d.item.title, username: d.item.subtitle, avatarURL: d.item.avatarURL, size: 56, style: .organization)
                VStack(alignment: .leading, spacing: 5) {
                    Text(d.item.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                    Text(d.item.subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            Text(d.item.title).font(.title3.weight(.semibold)).textSelection(.enabled)
            Text(d.item.subtitle).font(.caption).foregroundStyle(.secondary)
        }
        WorkbenchFlow {
            if safeURL(d.item.url) != nil { Button { open(d.item.url) } label: { Label("Open in browser", systemImage: "arrow.up.right.square") } }
            if section == .releases || section == .gists && d.item.editable { Button("Edit") { startEditor(edit: true) }.disabled(section == .gists && (d.files.contains(where: \.truncated) || d.item.data["truncated"] as? Bool == true)) }
            if section == .gists, let starred = d.starred { Button { let context = store.hubActionStamp; Task { await store.hostingHubAction(expected: context) { c in try await HostingHubAPI.star(c, item: d.item, starred: !starred) } } } label: { Label(starred ? String(localized: "Unstar") : String(localized: "Star"), systemImage: starred ? "star.fill" : "star") } }
            if section == .releases || section == .gists && d.item.editable { Button(role: .destructive) { confirm(String(localized: "Delete this item?"), d.item.title + "\n" + String(localized: "This removes the remote item. Release tags and git history are kept."), refreshList: true, destructive: true) { c in try await HostingHubAPI.delete(c, section: section, item: d.item) } } label: { Label("Delete", systemImage: "trash") } }
        }.controlSize(.small).disabled(locked)
        if let notice = d.notice { noticeView(notice) }
        if !d.item.body.isEmpty { Text(d.item.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
        switch section {
        case .releases:
            Text("Release assets").font(.headline)
            ForEach(d.assets) { asset in WorkbenchFlow { VStack(alignment: .leading) { Text(asset.name).fontWeight(.medium); if let size = asset.size { Text("\(size) bytes").font(.caption).foregroundStyle(.secondary) }; if let count = asset.downloads { Text("\(count) downloads").font(.caption).foregroundStyle(.secondary) } }; if safeURL(asset.url, asset: true) != nil { Button("Download in browser") { open(asset.url, asset: true) } } else { Text("External download blocked; inspect the release page.").font(.caption).foregroundStyle(.secondary) } }.padding(.vertical, 8); Divider() }
            if d.assets.isEmpty { Text("No release assets.").foregroundStyle(.secondary) }
        case .gists:
            ForEach(d.files) { file in VStack(alignment: .leading, spacing: 8) { Text(file.name).font(.headline); if file.truncated { Text("The server truncated this file. Editing is disabled to avoid data loss.").font(.caption).foregroundStyle(.orange) }; Text(file.content).font(.system(.callout, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12).background(Color.secondary.opacity(0.08)) } }
        case .organizations:
            Picker("Organization view", selection: Binding(get: { store.hostingHub.tab }, set: { tab in Task { await store.selectHostingHubItem(d.item, tab: tab) } })) {
                Text("Repositories").tag("repositories")
                Text("Members").tag("members")
            }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 280).disabled(locked)
            if store.hostingHub.tab == "members" {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), alignment: .leading)], alignment: .leading, spacing: 12) {
                    ForEach(d.members) { member in memberCard(member) }
                }
                if d.members.isEmpty && !store.hostingHub.detailLoading { Text("No members visible to this account.").font(.callout).foregroundStyle(.secondary).padding(.vertical, 16) }
            }
            ForEach(d.repositories) { repository in VStack(alignment: .leading, spacing: 10) { VStack(alignment: .leading, spacing: 5) { Text(repository.name).fontWeight(.medium); Text(repository.description).font(.caption).foregroundStyle(.secondary) }; Button(onClone == nil ? String(localized: "Copy clone URL") : String(localized: "Clone")) { if let onClone { onClone(repository.cloneURL) } else { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(repository.cloneURL, forType: .string) } }.disabled(locked || safeURL(repository.cloneURL) == nil) }.padding(.vertical, 8); Divider() }
        case .projects:
            projectWorkspace(d)

        }
        if d.more { Button("Load more") { Task { await store.selectHostingHubItem(d.item, append: true) } }.disabled(locked) }
        if store.hostingHub.detailLoading { ProgressView() }
    }
    private func memberCard(_ member: HubMember) -> some View {
        HStack(alignment: .top, spacing: 12) {
            HostingAvatar(name: member.name, username: member.username, avatarURL: member.avatarURL, size: 42)
            VStack(alignment: .leading, spacing: 5) {
                Text(member.name).font(.callout.weight(.semibold)).lineLimit(1).help(member.name)
                if !member.username.isEmpty { Text(verbatim: "@" + member.username).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Text(member.role).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3).background(Capsule().fill(Color.secondary.opacity(0.09)))
            }
            Spacer(minLength: 0)
            if let url = member.profileURL {
                Link(destination: url) { Image(systemName: "arrow.up.right").font(.caption.weight(.semibold)).frame(width: 24, height: 24).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Open profile").accessibilityLabel("Open profile")
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.15)))
    }
    private func groupingField(_ detail: HubDetail) -> HubProjectField? {
        detail.fields.first { $0.id == projectFieldID } ?? detail.fields.first { ["status", "상태"].contains($0.name.lowercased()) } ?? detail.fields.first
    }
    private func projectWorkspace(_ detail: HubDetail) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkbenchFlow(spacing: 12) {
                Picker("Project view", selection: $projectLayout) { Label("Board", systemImage: "rectangle.split.3x1").tag("board"); Label("List", systemImage: "list.bullet").tag("list") }.pickerStyle(.segmented).frame(width: 170)
                Text(verbatim: String(localized: "{0} loaded items").replacingOccurrences(of: "{0}", with: detail.rows.count.formatted())).font(.caption).foregroundStyle(.secondary)
                if let field = groupingField(detail) {
                    Picker("Group by", selection: Binding(get: { field.id }, set: { projectFieldID = $0 })) { ForEach(detail.fields) { value in Text(value.name).tag(value.id) } }.frame(maxWidth: 230)
                }
            }
            if detail.fields.isEmpty { Text("No editable single-select fields. Add a Status field in the project to move items here.").font(.caption).foregroundStyle(.secondary) }
            if detail.rows.isEmpty {
                VStack(spacing: 10) { Image(systemName: "rectangle.split.3x1").font(.title); Text("This project has no loaded items.").font(.headline); Text("Add an existing issue below or manage the project in GitHub.").font(.caption) }
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(28).background(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [5])))
            } else if projectLayout == "board" {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(Array(HostingHubAPI.projectColumns(detail, fieldID: groupingField(detail)?.id).enumerated()), id: \.element.id) { index, column in
                            projectColumn(column, detail: detail, index: index)
                        }
                    }.padding(.bottom, 8)
                }.accessibilityLabel("Project board")
                if HostingHubAPI.projectColumns(detail, fieldID: groupingField(detail)?.id).count > 1 { Text("Scroll horizontally to see more columns.").font(.caption).foregroundStyle(.secondary) }
            } else {
                LazyVStack(alignment: .leading, spacing: 10) { ForEach(detail.rows) { row in projectCard(row, detail: detail) } }
            }
            Divider()
            WorkbenchFlow(spacing: 8) {
                TextField("Issue URL", text: $issueURL).textFieldStyle(.roundedBorder).frame(minWidth: 200, idealWidth: 330)
                Button { let url = issueURL; confirm(store.hubProvider == .gitlab ? String(localized: "Move issue to the Open column?") : String(localized: "Add issue to project?"), store.hubProvider == .gitlab ? url + "\n" + String(localized: "This reopens the issue and removes its board column labels.") : url) { c in try await HostingHubAPI.addIssue(c, detail: detail, issueURL: url) } } label: { Label("Add issue", systemImage: "plus") }.disabled(issueURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.disabled(locked)
        }
    }
    private func projectColumn(_ column: HubProjectColumn, detail: HubDetail, index: Int) -> some View {
        let colors: [Color] = [.purple, .blue, .orange, .green, .pink, .teal]
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) { Circle().fill(colors[index % colors.count]).frame(width: 8, height: 8); Text(column.title).font(.callout.weight(.semibold)); Spacer(minLength: 4); Text(column.rows.count.formatted()).font(.caption.monospacedDigit()).foregroundStyle(.secondary).padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(Color.secondary.opacity(0.1))) }.padding(.horizontal, 3)
            ForEach(column.rows) { row in projectCard(row, detail: detail) }
            if column.rows.isEmpty { Text("No items").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 20) }
        }.padding(12).frame(width: 270, alignment: .leading).background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.05))).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.15)))
    }
    private func projectCard(_ row: HubProjectRow, detail: HubDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "circle").foregroundStyle(Color.accentColor).font(.caption).padding(.top, 3)
                Text(row.title).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                if safeURL(row.url) != nil { Button { open(row.url) } label: { Image(systemName: "arrow.up.right.square") }.buttonStyle(.borderless).help("Open in browser") }
            }
            if !row.body.isEmpty { Text(String(row.body.prefix(1200))).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled) }
            ForEach(detail.fields) { field in projectField(field, row: row, detail: detail).font(.caption) }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .controlBackgroundColor))).overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.secondary.opacity(0.18)))
    }
    private func projectStatusBinding(_ row: HubProjectRow, field: HubProjectField, detail: HubDetail) -> Binding<String> {
        Binding(get: { row.statuses[field.id] ?? "" }, set: { option in
            let optionName = field.options.first(where: { $0.id == option })?.name ?? ""
            let message = row.title + "\n" + field.name + ": " + optionName
            confirm(String(localized: "Change project status?"), message) { c in
                try await HostingHubAPI.move(c, detail: detail, row: row, field: field, option: option)
            }
        })
    }
    private func projectField(_ field: HubProjectField, row: HubProjectRow, detail: HubDetail) -> some View {
        Picker(field.name, selection: projectStatusBinding(row, field: field, detail: detail)) {
            Text("Not set").tag("").disabled(true)
            ForEach(field.options) { option in Text(option.name).tag(option.id) }
        }.disabled(locked || row.contentID.isEmpty)
    }

}
