import SwiftUI
import AppKit

/// Repository releases keep reading, editing and version discovery in one workspace.
struct ReleaseWorkspace: View {
    @Bindable var store: RepoStore
    @ViewState private var editor: String?
    @ViewState private var input = HubReleaseInput()
    @ViewState private var preview = false
    @ViewState private var detailOpen = false
    @ViewState private var filter = "All releases"
    @ViewState private var sort = "date"
    @ViewState private var family = "*"
    @ViewState private var base = ""
    @ViewState private var nearest: String?
    private var locked: Bool { store.hostingHub.loading || store.hostingHub.detailLoading || store.hostingHub.busy }
    private var items: [HubItem] {
        ReleaseCatalog.ordered(store.hostingHub.filteredItems.filter {
            (filter == "All releases" || ReleaseCatalog.state($0) == filter) && (family == "*" || ReleaseCatalog.family($0) == family)
        }, byVersion: sort == "version")
    }
    private var families: [String] { Array(Set(store.hostingHub.items.map(ReleaseCatalog.family))).sorted() }
    private var scoped: [HubItem] { store.hostingHub.items.filter { family == "*" || ReleaseCatalog.family($0) == family } }
    private var tagContext: String { store.hubContextStamp(in: .releases) + "|" + (store.headHash ?? "") }
    var body: some View {
        VStack(spacing: 0) {
            header
            versions
            if let notice = store.hostingHub.notice { noticeView(notice) }
            if let account = store.pendingHubCredentialAccount { CredentialAccessNotice(account: account).padding(12) }
            if store.hostingHub.allowingCredentialAccess || store.hubCredentialState == .loading { ProgressView().controlSize(.small).padding(8) }
            if let error = store.hostingHub.error {
                HStack(alignment: .top) { Text(error).font(.callout).textSelection(.enabled); Spacer(); Button("Retry") { Task { if let d = store.hostingHub.detail { await store.selectHostingHubItem(d.item) } else { await store.loadHostingHub() } } }.disabled(locked) }.padding(12).foregroundStyle(.red)
            }
            GeometryReader { geometry in
                if geometry.size.width < 680 {
                    if detailOpen { detail } else { list }
                } else {
                    HStack(spacing: 0) { list.frame(width: min(330, geometry.size.width * 0.32)); Divider(); detail }
                }
            }
        }
        .task(id: store.hubContextStamp(in: .releases)) {
            editor = nil; detailOpen = false; filter = "All releases"; family = "*"; base = ""
            await store.activateHostingHub(.releases)
        }
        .task(id: tagContext) {
            nearest = nil
            let stamp = tagContext
            guard let url = store.url, let head = store.headHash else { return }
            let result = try? await Git.run(["describe", "--tags", "--abbrev=0", head], in: url, ok: [0, 128])
            guard !Task.isCancelled, tagContext == stamp else { return }
            nearest = result?.status == 0 ? result?.output.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        }
        .onChange(of: store.hostingHub.uncertainWrite) { _, value in if value { editor = nil } }
    }
    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Releases").font(.title2.weight(.semibold))
                if let target = store.target { Text(target.host + " / " + target.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button { detailOpen = false; Task { await store.loadHostingHub() } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh").accessibilityLabel("Refresh").disabled(locked || editor != nil)
            Button { startEditor(false) } label: { Label("New", systemImage: "plus") }.disabled(locked || store.hubAccount == nil)
        }.padding(20)
    }
    private var versions: some View {
        let exact = store.tags.filter { $0.target == store.headHash }.map(\.name).joined(separator: ", ")
        let sorted = ReleaseCatalog.ordered(store.hostingHub.error == nil && !store.hostingHub.loading ? scoped : [])
        let stable = sorted.first { ReleaseCatalog.state($0) == "Stable" }
        let prerelease = sorted.first { ReleaseCatalog.state($0) == "Prerelease" }
        let packageChosen = families.count <= 1 || family != "*"
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 12) {
            versionCell("Tag at checkout", exact.isEmpty ? String(localized: "No tag at checkout") : exact)
            versionCell("Nearest ancestor tag", nearest.map { $0.isEmpty ? String(localized: "No ancestor tag") : $0 } ?? "—")
            versionCell(store.hostingHub.more ? "Newest loaded stable" : "Latest stable by date", packageChosen ? stable.map(ReleaseCatalog.tag) ?? "—" : String(localized: "Select a package"))
            versionCell(store.hostingHub.more ? "Newest loaded prerelease" : "Latest prerelease by date", packageChosen ? prerelease.map(ReleaseCatalog.tag) ?? "—" : String(localized: "Select a package"))
        }.padding(.horizontal, 20).padding(.bottom, 16).overlay(alignment: .bottom) { Divider() }
    }
    private func versionCell(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(LocalizedStringKey(title)).font(.caption).foregroundStyle(.secondary); Text(value).font(.callout.weight(.medium)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search loaded items", text: $store.hostingHub.query).textFieldStyle(.roundedBorder)
            HStack {
                Picker("Release status", selection: $filter) {
                    Text("All releases").tag("All releases"); Text("Stable").tag("Stable")
                    if store.hubProvider == .github { Text("Prerelease").tag("Prerelease"); Text("Draft").tag("Draft") }
                }.labelsHidden()
                Picker("Sort releases", selection: $sort) { Text("Published date").tag("date"); Text("Version").tag("version") }.labelsHidden()
            }
            if families.count > 1 { Picker("Package", selection: $family) { Text("All packages").tag("*"); ForEach(families, id: \.self) { value in Text(value.isEmpty ? String(localized: "Repository releases") : value).tag(value) } } }
            Text("Search filters loaded pages. Load more to search older items.").font(.caption).foregroundStyle(.secondary)
            if sort == "version" { Text("Version ordering applies to one SemVer package; other selections use published dates.").font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(items) { item in
                        Button {
                            editor = nil; detailOpen = true; base = ""
                            Task { await store.selectHostingHubItem(item) }
                        } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                WorkbenchFlow(spacing: 8) { Label(ReleaseCatalog.tag(item), systemImage: "tag").font(.callout.weight(.semibold)); badge(item) }
                                Text(item.title).font(.callout)
                                Text(String(ReleaseCatalog.date(item).prefix(10))).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(12).contentShape(Rectangle())
                        }.buttonStyle(.plain).background(RoundedRectangle(cornerRadius: 8).fill(store.hostingHub.detail?.item.id == item.id && editor == nil ? Color.accentColor.opacity(0.15) : .clear)).disabled(store.hostingHub.busy)
                    }
                    if store.hostingHub.loading { ProgressView().padding() }
                    if !store.hostingHub.loading && items.isEmpty && store.hostingHub.error == nil { Text(store.hostingHub.items.isEmpty ? String(localized: "No releases found for this repository.") : String(localized: "No matching releases.")).font(.callout).foregroundStyle(.secondary).padding(12) }
                    if store.hostingHub.more { Button("Load more") { Task { await store.loadHostingHub(append: true) } }.disabled(locked) }
                }
            }
        }.padding(12)
    }
    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button { detailOpen = false; editor = nil } label: { Label("Back to releases", systemImage: "chevron.left") }.buttonStyle(.plain)
                if editor != nil { editForm }
                else if let d = store.hostingHub.detail { releaseDetail(d) }
                else if store.hostingHub.detailLoading { ProgressView() }
                else { Label("Select a release to read its notes and compare versions.", systemImage: "tag").foregroundStyle(.secondary).padding(.vertical, 40) }
            }.frame(maxWidth: 880, alignment: .leading).frame(maxWidth: .infinity, alignment: .topLeading).padding(22)
        }
    }
    @ViewBuilder private func releaseDetail(_ d: HubDetail) -> some View {
        let tag = ReleaseCatalog.tag(d.item)
        WorkbenchFlow { Text(tag).font(.system(.title3, design: .monospaced)).foregroundStyle(Color.accentColor).textSelection(.enabled); badge(d.item) }
        Text(d.item.title).font(.title.weight(.semibold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        Text(ReleaseCatalog.date(d.item).isEmpty ? String(localized: "Date unavailable") : String(ReleaseCatalog.date(d.item).prefix(10))).font(.callout).foregroundStyle(.secondary)
        WorkbenchFlow {
            if safe(d.item.url) != nil { Button { open(d.item.url) } label: { Label("Open in browser", systemImage: "arrow.up.right.square") } }
            Menu {
                Button("Edit") { startEditor(true) }
                Button("Delete", role: .destructive) {
                    confirm(String(localized: "Delete this item?"), d.item.title + "\n" + String(localized: "This removes the remote item. Release tags and git history are kept."), destructive: true) { c in
                        try await HostingHubAPI.delete(c, section: .releases, item: d.item); detailOpen = false
                    }
                }
            } label: { Image(systemName: "ellipsis") }.help("Release actions").accessibilityLabel("Release actions").disabled(locked)
        }
        let comparable = ReleaseCatalog.state(d.item) == "Draft" ? [] : store.hostingHub.items.filter { ReleaseCatalog.state($0) != "Draft" && ReleaseCatalog.compareURL(store.target, base: ReleaseCatalog.tag($0), head: tag) != nil }
        if !comparable.isEmpty {
            WorkbenchFlow {
                Picker("Compare from", selection: $base) { Text("Choose a tag").tag(""); ForEach(comparable) { Text(ReleaseCatalog.tag($0)).tag(ReleaseCatalog.tag($0)) } }.frame(maxWidth: 320)
                Button("Compare changes") { if let url = ReleaseCatalog.compareURL(store.target, base: base, head: tag) { open(url.absoluteString) } }.disabled(ReleaseCatalog.compareURL(store.target, base: base, head: tag) == nil)
            }.padding(12).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        }
        if d.item.body.isEmpty { Text("No release notes.").foregroundStyle(.secondary) }
        else { ReleaseMarkdown(text: d.item.body, target: store.target, tag: tag).font(.callout).padding(.vertical, 10) }
        Text("Release assets").font(.headline)
        ForEach(d.assets) { asset in
            WorkbenchFlow {
                Image(systemName: "arrow.down.doc")
                VStack(alignment: .leading, spacing: 5) {
                    Text(asset.name).font(.callout.weight(.medium)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    HStack { if let size = asset.size { Text(ReleaseCatalog.assetSize(size)) }; if let downloads = asset.downloads { Text("\(downloads) downloads") } }.font(.caption).foregroundStyle(.secondary)
                }
                if safe(asset.url, asset: true) != nil { Button("Download in browser") { open(asset.url, asset: true) } }
                else { Text("External download blocked; inspect the release page.").font(.caption).foregroundStyle(.secondary) }
            }.padding(.vertical, 8)
            Divider()
        }
        if d.assets.isEmpty { Text("No release assets.").foregroundStyle(.secondary) }
    }
    private var editForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editor == "new" ? String(localized: "New release") : String(localized: "Edit release")).font(.headline)
            LabeledContent("Tag") { TextField("Tag", text: $input.tag).textFieldStyle(.roundedBorder).disabled(editor == "edit") }
            LabeledContent("Name") { TextField("Name", text: $input.name).textFieldStyle(.roundedBorder) }
            LabeledContent("Target branch or commit") { TextField("Target branch or commit", text: $input.target).textFieldStyle(.roundedBorder).disabled(editor == "edit" && store.hubProvider == .gitlab) }
            Picker("Release notes", selection: $preview) { Text("Write").tag(false); Text("Preview").tag(true) }.pickerStyle(.segmented).frame(maxWidth: 240)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $input.body).font(.system(.body, design: .monospaced)).frame(minHeight: 260).opacity(preview ? 0 : 1).allowsHitTesting(!preview).accessibilityHidden(preview).accessibilityLabel("Release notes")
                if preview {
                    if input.body.isEmpty { Text("No release notes.").foregroundStyle(.secondary).padding(10) }
                    else { ReleaseMarkdown(text: input.body, target: store.target, tag: input.tag).padding(10) }
                }
            }.overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            if store.hubProvider == .github { Toggle("Draft", isOn: $input.draft); Toggle("Prerelease", isOn: $input.prerelease) }
            HStack {
                Button("Review and save") { submit() }.buttonStyle(.borderedProminent).disabled(input.tag.trimmingCharacters(in: .whitespaces).isEmpty || input.name.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") { editor = nil }
            }
        }.disabled(locked)
    }
    private func startEditor(_ edit: Bool) {
        if edit, let item = store.hostingHub.detail?.item { input = HubReleaseInput(tag: ReleaseCatalog.tag(item), name: item.title, body: item.body, target: item.data["target_commitish"] as? String ?? "", draft: item.data["draft"] as? Bool == true, prerelease: item.data["prerelease"] as? Bool == true) }
        else { input = HubReleaseInput(draft: store.hubProvider == .github) }
        editor = edit ? "edit" : "new"; preview = false; detailOpen = true
    }
    private func submit() {
        let payload = input, previous = editor == "edit" ? store.hostingHub.detail?.item : nil
        confirm(payload.draft ? String(localized: "Save release draft?") : String(localized: "Publish release?"), (store.target?.path ?? "") + "\n" + payload.tag + " · " + payload.name + "\n" + (payload.draft ? String(localized: "Only accounts with repository write access can see the draft.") : String(localized: "This publishes the release on the server."))) { c in
            try await HostingHubAPI.saveRelease(c, payload, previous: previous); editor = nil; detailOpen = false
        }
    }
    private func confirm(_ title: String, _ message: String, destructive: Bool = false, action: @escaping (HubAccess) async throws -> Void) {
        let stamp = store.hubActionStamp
        store.confirm = ConfirmRequest(title: title, message: message, actionTitle: String(localized: "Confirm"), destructive: destructive) { await store.hostingHubAction(expected: stamp, refreshList: true, action: action) }
    }
    private func safe(_ value: String, asset: Bool = false) -> URL? { HostingHubAPI.safeURL(provider: store.hubProvider, host: store.target?.host ?? "", value, asset: asset) }
    private func open(_ value: String, asset: Bool = false) { if let url = safe(value, asset: asset) { NSWorkspace.shared.open(url) } }
    private func badge(_ item: HubItem) -> some View {
        Text(LocalizedStringKey(ReleaseCatalog.state(item))).font(.caption2).padding(.horizontal, 7).padding(.vertical, 3).foregroundStyle(ReleaseCatalog.state(item) == "Stable" ? Color.accentColor : Color.secondary).background(.quaternary.opacity(0.4), in: Capsule())
    }
    private func noticeView(_ message: String) -> some View { Text(message).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(10).background(.quaternary.opacity(0.25)) }
}

/// A release resolves repository files at its tag, with the existing image gate.
struct ReleaseMarkdown: View {
    let text: String
    let target: RepoTarget?
    let tag: String
    var body: some View {
        let ref = (tag.isEmpty ? "HEAD" : tag).addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? "HEAD"
        let web = target?.webURL ?? ""
        let marker = target?.provider == .gitlab ? "-/" : ""
        MarkdownView(text, refs: target?.markdownRefs, baseURL: URL(string: web + "/" + marker + "blob/" + ref + "/"), imageBaseURL: URL(string: web + "/" + marker + "raw/" + ref + "/"), canLoadImage: { target?.canLoadImage($0) ?? false })
    }
}
