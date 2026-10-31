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
    @ViewState private var family: String?
    @ViewState private var base = ""
    @ViewState private var distances: (key: String, value: Distances)?
    @ViewState private var summaryWidth: CGFloat = 1000
    @ViewState private var detailWidth: CGFloat = 1000
    struct Distances { var segments: [Int?]; var ahead: Int?; var behind: Int? }
    private static let stateHelp = ["Stable": "Published releases", "Prerelease": "Published, but marked as not ready for production", "Draft": "Saved but not published; only people with write access see it"]
    private var locked: Bool { store.hostingHub.loading || store.hostingHub.detailLoading || store.hostingHub.busy }
    // One package at a time: "latest" and the timeline mean nothing across separately versioned products.
    private var families: [String] { Array(Set(store.hostingHub.items.map(ReleaseCatalog.family))).sorted() }
    private var current: String { family ?? ReleaseCatalog.defaultFamily(store.hostingHub.items) }
    private var packaged: [HubItem] { store.hostingHub.items.filter { ReleaseCatalog.family($0) == current } }
    private var states: Set<String> { Set(packaged.map(ReleaseCatalog.state)) }
    private var mixed: Bool { states.contains { $0 != "Stable" } }
    private var shown: String { mixed ? filter : "All releases" }
    private var items: [HubItem] {
        ReleaseCatalog.ordered(store.hostingHub.filteredItems.filter {
            ReleaseCatalog.family($0) == current && (shown == "All releases" || ReleaseCatalog.state($0) == shown)
        }, byVersion: sort == "version")
    }
    private var latest: HubItem? { ReleaseCatalog.ordered(packaged).first { ReleaseCatalog.state($0) == "Stable" } }
    private var timeline: ReleaseCatalog.Timeline { ReleaseCatalog.timeline(store.hostingHub.error == nil ? packaged : [], family: current) }
    private var distanceKey: String { ([store.url?.path ?? "", store.headHash ?? ""] + timeline.path.map(ReleaseCatalog.tag)).joined(separator: "\n") }
    private var headLabel: String { store.headBranch ?? store.headHash.map { String($0.prefix(8)) } ?? "HEAD" }
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            summary
            if let notice = store.hostingHub.notice { noticeView(notice) }
            if let account = store.pendingHubCredentialAccount { CredentialAccessNotice(account: account).padding(12) }
            if store.hostingHub.allowingCredentialAccess || store.hubCredentialState == .loading { ProgressView().controlSize(.small).padding(8) }
            if let error = store.hostingHub.error {
                HStack(alignment: .top) { Text(error).font(.callout).textSelection(.enabled); Spacer(); Button("Retry") { Task { if let d = store.hostingHub.detail { await store.selectHostingHubItem(d.item) } else { await store.loadHostingHub() } } }.disabled(locked) }.padding(12).foregroundStyle(.red)
            }
            GeometryReader { geometry in
                if geometry.size.width < 680 {
                    if detailOpen { detail(narrow: true) } else { list }
                } else {
                    HStack(spacing: 0) { list.frame(width: min(330, geometry.size.width * 0.32)); Divider(); detail(narrow: false) }
                }
            }
        }
        .task(id: store.hubContextStamp(in: .releases)) {
            editor = nil; detailOpen = false; filter = "All releases"; family = nil; base = ""
            await store.activateHostingHub(.releases)
        }
        .task(id: distanceKey) { await loadDistances() }
        .onChange(of: store.hostingHub.uncertainWrite) { _, value in if value { editor = nil } }
    }
    private var toolbar: some View {
        HStack(spacing: 10) {
            if let target = store.target { Text(target.host + " / " + target.path).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled) }
            if families.count > 1 {
                Picker("Package", selection: Binding(get: { current }, set: { family = $0; filter = "All releases"; detailOpen = false })) {
                    ForEach(families, id: \.self) { value in Text(verbatim: packageTitle(value)).tag(value) }
                }.fixedSize().disabled(locked)
            }
            Spacer(minLength: 0)
            Button { detailOpen = false; Task { await store.loadHostingHub() } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh").accessibilityLabel("Refresh").disabled(locked || editor != nil)
            Button { startEditor(false) } label: { Label("New release", systemImage: "plus") }.buttonStyle(.borderedProminent).disabled(locked || store.hubAccount == nil)
        }.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 12)
    }
    private func packageTitle(_ value: String) -> String {
        let name = ReleaseCatalog.packageName(store.hostingHub.items, family: value)
        return name.isEmpty ? String(localized: "Repository releases") : name
    }

    /// The newest release of the package and where the checkout stands after it (Windows: ReleaseSummary.tsx).
    @ViewBuilder private var summary: some View {
        let timeline = self.timeline
        if let latest = timeline.stable ?? timeline.prerelease {
            let value = distances?.key == distanceKey ? distances?.value : nil
            let atLast = value?.ahead == 0 && value?.behind == 0
            HStack(spacing: 32) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(timeline.stable != nil && timeline.prerelease != nil ? "Latest stable release" : "Latest release").font(.caption).foregroundStyle(.secondary)
                    Text(ReleaseCatalog.tag(latest)).font(.system(size: 28, weight: .semibold, design: .monospaced)).foregroundStyle(Color.accentColor).lineLimit(1).minimumScaleFactor(0.6).textSelection(.enabled)
                    Text(latest.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    HostingDate(value: ReleaseCatalog.date(latest), published: true)
                }.frame(minWidth: 160, maxWidth: 240, alignment: .leading)
                if summaryWidth >= 680, store.url != nil {
                    ReleaseTimelineTrack(nodes: timelineNodes(timeline, atLast: atLast), segments: timelineSegments(timeline, value: value, atLast: atLast))
                        .frame(maxWidth: .infinity)
                } else { Spacer(minLength: 0) }
                if !atLast, value?.ahead != nil {
                    VStack(spacing: 6) {
                        Button { store.showRevisionComparison(left: ReleaseCatalog.tag(latest), right: store.headHash ?? "HEAD") } label: { Label("Compare changes", systemImage: "arrow.left.arrow.right") }
                        Text(verbatim: ReleaseCatalog.tag(latest) + " → " + headLabel).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }.fixedSize()
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: .separatorColor).opacity(0.6)))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { summaryWidth = $0 }
            .padding(.horizontal, 20).padding(.bottom, 14)
            .accessibilityElement(children: .contain).accessibilityLabel("Versions")
        }
    }
    private func timelineNodes(_ timeline: ReleaseCatalog.Timeline, atLast: Bool) -> [ReleaseTimelineTrack.Node] {
        var nodes = timeline.path.map { item -> ReleaseTimelineTrack.Node in
            let kind: ReleaseTimelineTrack.Kind = item.id == timeline.stable?.id ? .latest : ReleaseCatalog.state(item) == "Prerelease" ? .prerelease : .older
            return .init(label: ReleaseCatalog.tag(item), detail: atLast && item.id == timeline.path.last?.id ? headLabel : nil, kind: kind)
        }
        if !atLast, let head = store.headHash { nodes.append(.init(label: headLabel, detail: String(head.prefix(8)), kind: .head)) }
        return nodes
    }
    private func timelineSegments(_ timeline: ReleaseCatalog.Timeline, value: Distances?, atLast: Bool) -> [ReleaseTimelineTrack.Segment] {
        // Square roots keep a 200-commit gap from flattening the 10-commit ones next to it.
        func weight(_ commits: Int?) -> Double { commits.map { max(1, Double($0).squareRoot()) } ?? 3 }
        var segments = timeline.path.indices.dropFirst().map { index in ReleaseTimelineTrack.Segment(weight: weight(index - 1 < (value?.segments.count ?? 0) ? value?.segments[index - 1] : nil), dashed: false, label: nil) }
        if !atLast, store.headHash != nil {
            var label: String?
            if let value, let ahead = value.ahead, let last = timeline.path.last {
                if (value.behind ?? 0) > 0 { label = String(localized: "Not on top of {0}").replacingOccurrences(of: "{0}", with: ReleaseCatalog.tag(last)) }
                else if ahead > 0 { label = String(localized: "{0} unreleased commits").replacingOccurrences(of: "{0}", with: ahead.formatted()) }
            }
            segments.append(.init(weight: weight(value?.ahead), dashed: true, label: label))
        }
        return segments
    }
    private func loadDistances() async {
        let key = distanceKey, tags = timeline.path.map(ReleaseCatalog.tag)
        guard let url = store.url, !tags.isEmpty else { return }
        // refs/tags/ keeps a server-supplied tag from being read as an option or a branch
        func count(_ arguments: [String]) async -> [Int]? {
            guard let result = try? await Git.run(["rev-list"] + arguments, in: url, ok: [0, 128]), result.status == 0 else { return nil }
            return result.output.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        }
        var segments: [Int?] = []
        for index in tags.indices.dropFirst() { segments.append(await count(["--count", "refs/tags/\(tags[index - 1])..refs/tags/\(tags[index])"])?.first) }
        var sides: [Int]?
        if let head = store.headHash { sides = await count(["--left-right", "--count", "refs/tags/\(tags[tags.count - 1])...\(head)"]) }
        guard !Task.isCancelled, distanceKey == key else { return }
        distances = (key, Distances(segments: segments, ahead: sides?.count == 2 ? sides?[1] : nil, behind: sides?.count == 2 ? sides?[0] : nil))
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Search loaded items", text: $store.hostingHub.query).textFieldStyle(.roundedBorder)
                Menu {
                    Picker("Sort releases", selection: $sort) { Text("Newest first").tag("date"); Text("Version number").tag("version") }.pickerStyle(.inline)
                } label: { Image(systemName: "arrow.up.arrow.down") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Sort releases").accessibilityLabel("Sort releases")
            }
            if mixed {
                Picker("Release status", selection: $filter) {
                    ForEach(["All releases", "Stable", "Prerelease", "Draft"].filter { $0 == "All releases" || states.contains($0) }, id: \.self) { state in
                        let count = state == "All releases" ? packaged.count : packaged.filter { ReleaseCatalog.state($0) == state }.count
                        Text(verbatim: Bundle.main.localizedString(forKey: state == "All releases" ? "All" : state, value: nil, table: nil) + " \(count)").tag(state)
                    }
                }.pickerStyle(.segmented).labelsHidden()
                if let help = Self.stateHelp[shown] { Text(LocalizedStringKey(help)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            if sort == "version" { Text("Version ordering applies to one SemVer package; other selections use published dates.").font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(items) { item in row(item) }
                    }
                    // Keep pagination outside the lazy rows so repeated scrolls retain its position.
                    if store.hostingHub.loading { ProgressView().padding() }
                    if !store.hostingHub.loading && items.isEmpty && store.hostingHub.error == nil { Text(store.hostingHub.items.isEmpty ? String(localized: "No releases found for this repository.") : String(localized: "No matching releases.")).font(.callout).foregroundStyle(.secondary).padding(12) }
                    if store.hostingHub.more {
                        Divider().padding(.vertical, 6)
                        Button { Task { await store.loadHostingHub(append: true) } } label: { Text("Load more").frame(maxWidth: .infinity) }.disabled(locked)
                        Text("Search filters loaded pages. Load more to search older items.").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    }
                }
            }
        }.padding(12).background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }
    private func row(_ item: HubItem) -> some View {
        let selected = store.hostingHub.detail?.item.id == item.id && editor == nil
        return Button {
            editor = nil; detailOpen = true; base = ""
            Task { await store.selectHostingHubItem(item) }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(ReleaseCatalog.tag(item)).font(.callout.monospaced().weight(.semibold)).foregroundStyle(selected ? Color.accentColor : Color.primary)
                    badge(item)
                    if item.id == latest?.id { pill("Latest", color: .accentColor) }
                    Spacer(minLength: 4)
                    if ReleaseCatalog.state(item) == "Draft" { Text("Not published").font(.caption).foregroundStyle(.secondary) } else { HostingDate(value: ReleaseCatalog.date(item)) }
                }
                Text(item.title).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }.padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.13) : .clear)).disabled(store.hostingHub.busy)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func detail(narrow: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if narrow { Button { detailOpen = false; editor = nil } label: { Label("Back to releases", systemImage: "chevron.left") }.buttonStyle(.plain) }
                if editor != nil { editForm }
                else if let d = store.hostingHub.detail { releaseDetail(d) }
                else if store.hostingHub.detailLoading { ProgressView() }
                else { Label("Select a release to read its notes and compare versions.", systemImage: "tag").foregroundStyle(.secondary).padding(.vertical, 40) }
            }.frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity, alignment: .topLeading).padding(22)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { detailWidth = $0 - 44 }
        }
    }
    @ViewBuilder private func releaseDetail(_ d: HubDetail) -> some View {
        let tag = ReleaseCatalog.tag(d.item), target = d.item.data["target_commitish"] as? String ?? ""
        WorkbenchFlow(spacing: 8) {
            Text(tag).font(.system(.callout, design: .monospaced).weight(.semibold)).foregroundStyle(Color.accentColor).textSelection(.enabled)
            badge(d.item)
            if d.item.id == latest?.id { pill("Latest", color: .accentColor) }
        }
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(d.item.title).font(.title.weight(.semibold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if safe(d.item.url) != nil { Button { open(d.item.url) } label: { Label("Open in browser", systemImage: "arrow.up.right.square") } }
                Button { startEditor(true) } label: { Label("Edit", systemImage: "pencil") }.disabled(locked)
                Menu {
                    Button("Delete", role: .destructive) {
                        confirm(String(localized: "Delete this item?"), d.item.title + "\n" + String(localized: "This removes the remote item. Release tags and git history are kept."), destructive: true) { c in
                            try await HostingHubAPI.delete(c, section: .releases, item: d.item); detailOpen = false
                        }
                    }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Release actions").accessibilityLabel("Release actions").disabled(locked)
            }.fixedSize()
        }
        WorkbenchFlow(spacing: 10) {
            if ReleaseCatalog.state(d.item) == "Draft" { Text("Not published").font(.caption).foregroundStyle(.secondary) } else { HostingDate(value: ReleaseCatalog.date(d.item), published: true) }
            if !target.isEmpty { Text(verbatim: String(localized: "Tagged from {0}").replacingOccurrences(of: "{0}", with: target)).font(.caption).foregroundStyle(.secondary) }
            if !d.assets.isEmpty { Text(verbatim: String(localized: "Assets: {0}").replacingOccurrences(of: "{0}", with: d.assets.count.formatted())).font(.caption).foregroundStyle(.secondary) }
        }
        Divider()
        // Notes beside the downloads when there is room, the downloads below them otherwise
        if detailWidth >= 720 {
            HStack(alignment: .top, spacing: 28) {
                notes(d, tag: tag).frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 14) { assets(d, tag: tag); compare(d, tag: tag) }.frame(width: 300)
            }
        } else {
            VStack(alignment: .leading, spacing: 18) { notes(d, tag: tag); assets(d, tag: tag); compare(d, tag: tag) }
        }
    }
    @ViewBuilder private func notes(_ d: HubDetail, tag: String) -> some View {
        if d.item.body.isEmpty { Text("No release notes.").foregroundStyle(.secondary) }
        else { ReleaseMarkdown(text: d.item.body, target: store.target, tag: tag).font(.callout).frame(maxWidth: 760, alignment: .leading) }
    }
    private func assets(_ d: HubDetail, tag: String) -> some View {
        let groups = ReleaseCatalog.assetGroups(d.assets, tag: tag) { $0.name }
        return VStack(alignment: .leading, spacing: 4) {
            Text("Release assets").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 2)
            ForEach(groups.primary) { asset in assetRow(asset) }
            if !groups.other.isEmpty {
                DisclosureGroup {
                    ForEach(groups.other) { asset in assetRow(asset) }
                } label: { Text(verbatim: String(localized: "Other files ({0})").replacingOccurrences(of: "{0}", with: groups.other.count.formatted())).font(.caption) }
                .padding(.top, 4)
            }
            if d.assets.isEmpty { Text("No release assets.").font(.callout).foregroundStyle(.secondary) }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor).opacity(0.6)))
    }
    private func assetRow(_ asset: HubAsset) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(asset.name).font(.callout).lineLimit(1).truncationMode(.middle).help(asset.name).textSelection(.enabled)
                HStack(spacing: 4) { if let size = asset.size { Text(ReleaseCatalog.assetSize(size)) }; if asset.size != nil, asset.downloads != nil { Text(verbatim: "·") }; if let downloads = asset.downloads { Text("\(downloads) downloads") } }.font(.caption).foregroundStyle(.secondary)
                if safe(asset.url, asset: true) == nil { Text("External download blocked; inspect the release page.").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            if safe(asset.url, asset: true) != nil {
                Button { open(asset.url, asset: true) } label: { Image(systemName: "arrow.down.circle") }.buttonStyle(.borderless).help("Download in browser").accessibilityLabel("Download in browser")
            }
        }.padding(.vertical, 4)
    }
    @ViewBuilder private func compare(_ d: HubDetail, tag: String) -> some View {
        let comparable = ReleaseCatalog.state(d.item) == "Draft" ? [] : ReleaseCatalog.ordered(store.hostingHub.items.filter { ReleaseCatalog.state($0) != "Draft" && ReleaseCatalog.compareURL(store.target, base: ReleaseCatalog.tag($0), head: tag) != nil })
        if !comparable.isEmpty {
            // Preselect the release before this one, preferring the same state (a stable compares with the previous stable).
            let older = comparable.filter { ReleaseCatalog.date($0) < ReleaseCatalog.date(d.item) }
            let fallback = older.first { ReleaseCatalog.state($0) == ReleaseCatalog.state(d.item) } ?? older.first ?? comparable.first
            let from = base.isEmpty ? fallback.map(ReleaseCatalog.tag) ?? "" : base
            let url = ReleaseCatalog.compareURL(store.target, base: from, head: tag)
            VStack(alignment: .leading, spacing: 10) {
                Text("Compare changes").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Picker("Compare from", selection: Binding(get: { from }, set: { base = $0 })) { ForEach(comparable) { Text(ReleaseCatalog.tag($0)).tag(ReleaseCatalog.tag($0)) } }.labelsHidden()
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Text(tag).font(.caption.monospaced().weight(.semibold)).lineLimit(1).truncationMode(.middle).padding(.horizontal, 8).padding(.vertical, 4).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6)).help(tag)
                    Button { if let url { open(url.absoluteString) } } label: { Image(systemName: "arrow.up.right.square") }.buttonStyle(.borderless).help("Compare in browser").accessibilityLabel("Compare in browser").disabled(url == nil)
                }
                Button { store.showRevisionComparison(left: from, right: tag) } label: { Label("Compare in app", systemImage: "arrow.left.arrow.right").frame(maxWidth: .infinity) }.disabled(from.isEmpty)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor).opacity(0.6)))
        }
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
    // Stable is the norm, so only the exceptions get a badge.
    @ViewBuilder private func badge(_ item: HubItem) -> some View {
        let state = ReleaseCatalog.state(item)
        if state != "Stable" { pill(LocalizedStringKey(state), color: state == "Draft" ? .secondary : .orange) }
    }
    private func pill(_ title: LocalizedStringKey, color: Color) -> some View {
        Text(title).font(.caption2.weight(.semibold)).foregroundStyle(color).padding(.horizontal, 7).padding(.vertical, 2).background(color.opacity(0.13), in: Capsule())
    }
    private func noticeView(_ message: String) -> some View { Text(message).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(10).background(.quaternary.opacity(0.25)) }
}

/// Recent tags and the checkout on one line; segment lengths follow the commits between them.
struct ReleaseTimelineTrack: View {
    enum Kind { case older, latest, prerelease, head }
    struct Node { var label: String; var detail: String?; var kind: Kind }
    struct Segment { var weight: Double; var dashed: Bool; var label: String? }
    let nodes: [Node]
    let segments: [Segment]
    private let line: CGFloat = 24, inset: CGFloat = 34, minimum: CGFloat = 28

    var body: some View {
        GeometryReader { geometry in
            let centers = positions(width: geometry.size.width)
            ZStack(alignment: .topLeading) {
                ForEach(segments.indices, id: \.self) { index in
                    if index + 1 < nodes.count {
                        let from = centers[index] + size(nodes[index].kind) / 2, to = centers[index + 1] - size(nodes[index + 1].kind) / 2
                        Path { path in path.move(to: CGPoint(x: from, y: line)); path.addLine(to: CGPoint(x: to, y: line)) }
                            .stroke(segments[index].dashed ? Color.accentColor : Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 2, dash: segments[index].dashed ? [4, 3] : []))
                        if let label = segments[index].label {
                            Text(label).font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor).fixedSize().position(x: (from + to) / 2, y: line - 14)
                        }
                    }
                }
                ForEach(nodes.indices, id: \.self) { index in
                    dot(nodes[index].kind).position(x: centers[index], y: line)
                    VStack(spacing: 2) {
                        Text(nodes[index].label).font(labelFont(nodes[index].kind)).foregroundStyle(labelColor(nodes[index].kind))
                        if let detail = nodes[index].detail { Text(detail).font(.caption2.monospaced()).foregroundStyle(.secondary) }
                    }.fixedSize().frame(height: 30, alignment: .top).position(x: centers[index], y: line + 26)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(height: 70)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(nodes.map(\.label).joined(separator: ", ") + (segments.last?.label.map { ", " + $0 } ?? ""))
    }
    private func size(_ kind: Kind) -> CGFloat { kind == .older ? 8 : kind == .prerelease ? 10 : 12 }
    private func positions(width: CGFloat) -> [CGFloat] {
        let dots = nodes.reduce(0) { $0 + size($1.kind) }, total = segments.reduce(0) { $0 + $1.weight }
        let spare = max(0, width - inset * 2 - dots - minimum * CGFloat(segments.count))
        var x = inset, result: [CGFloat] = []
        for (index, node) in nodes.enumerated() {
            result.append(x + size(node.kind) / 2)
            x += size(node.kind) + (index < segments.count ? minimum + spare * CGFloat(segments[index].weight / max(total, 1)) : 0)
        }
        return result
    }
    @ViewBuilder private func dot(_ kind: Kind) -> some View {
        switch kind {
        case .older: Circle().fill(Color.secondary.opacity(0.5)).frame(width: 8, height: 8)
        case .latest: Circle().fill(Color.accentColor).frame(width: 12, height: 12).background(Circle().fill(Color.accentColor.opacity(0.18)).frame(width: 20, height: 20))
        case .prerelease: Circle().fill(Color.orange).frame(width: 10, height: 10)
        case .head: Circle().fill(Color(nsColor: .textBackgroundColor)).overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2)).frame(width: 12, height: 12)
        }
    }
    private func labelFont(_ kind: Kind) -> Font {
        switch kind {
        case .older: return .caption.monospaced()
        case .latest, .prerelease: return .caption.monospaced().weight(.semibold)
        case .head: return .caption.weight(.semibold)
        }
    }
    private func labelColor(_ kind: Kind) -> Color { kind == .latest ? .accentColor : kind == .prerelease ? .orange : kind == .head ? .primary : .secondary }
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
