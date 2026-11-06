import SwiftUI
import AppKit

/// Releases, as the redesign's Releases board draws it: where the page is and its actions, what this branch has not
/// released yet, then the list column and the open release beside it, with its notes, installers and comparison. The
/// page fills the window; only the list and side columns keep their widths. (Windows: ReleaseWorkspace.tsx)
struct ReleaseWorkspace: View {
    @Bindable var store: RepoStore
    @Environment(\.locale) private var locale
    @ViewState private var editor: String?
    @ViewState private var input = HubReleaseInput()
    @ViewState private var preview = false
    @ViewState private var detailOpen = false
    @ViewState private var filter = "All releases"
    @ViewState private var sort = "date"
    @ViewState private var family: String?
    @ViewState private var base = ""
    @ViewState private var opened: String?
    @ViewState private var otherFiles = false
    @ViewState private var distances: (key: String, value: Distances)?
    @ViewState private var width: CGFloat = 1000
    struct Distances { var segments: [Int?] = []; var ahead: Int?; var behind: Int?; var prereleaseInHead = false }
    private static let stateHelp = ["Prerelease": "Published, but marked as not ready for production", "Draft": "Saved but not published; only people with write access see it"]
    private var compact: Bool { width < HostedList.compact }
    private var locked: Bool { store.hostingHub.loading || store.hostingHub.detailLoading || store.hostingHub.busy }
    /// An account is missing, or its saved sign-in cannot be read yet; the page can show nothing of the server until then
    private var blocked: Bool { store.hubAccount == nil || store.pendingHubCredentialAccount != nil || store.hubCredentialState == .authorizationRequired }
    // One package at a time: "latest" and the timeline mean nothing across separately versioned products.
    private var families: [String] { Array(Set(store.hostingHub.items.map(ReleaseCatalog.family))).sorted() }
    private var current: String { family ?? ReleaseCatalog.defaultFamily(store.hostingHub.items) }
    private var packaged: [HubItem] { store.hostingHub.items.filter { ReleaseCatalog.family($0) == current } }
    private var states: Set<String> { Set(packaged.map(ReleaseCatalog.state)) }
    // Drafts are the exception, so their segment appears only when there is one to show.
    private var filters: [String] { ["All releases", "Stable", "Prerelease"] + (states.contains("Draft") ? ["Draft"] : []) }
    private var shown: String { filters.contains(filter) ? filter : "All releases" }
    private func inFilter(_ item: HubItem) -> Bool { ReleaseCatalog.family(item) == current && (shown == "All releases" || ReleaseCatalog.state(item) == shown) }
    private var items: [HubItem] { ReleaseCatalog.ordered(store.hostingHub.filteredItems.filter(inFilter), byVersion: sort == "version") }
    private var latest: HubItem? { ReleaseCatalog.ordered(packaged).first { ReleaseCatalog.state($0) == "Stable" } }
    private var timeline: ReleaseCatalog.Timeline { ReleaseCatalog.timeline(packaged, family: current) }
    /// The line up to the newest stable release; a newer prerelease sits beside it, not on it
    private var line: [HubItem] { timeline.stable == nil ? timeline.path : timeline.path.filter { $0.id != timeline.prerelease?.id } }
    private var fork: HubItem? { timeline.stable == nil ? nil : timeline.prerelease }
    private var distanceKey: String { ([store.url?.path ?? "", store.headHash ?? ""] + timeline.path.map(ReleaseCatalog.tag)).joined(separator: "\n") }
    private var headLabel: String { store.headBranch ?? store.headHash.map { String($0.prefix(8)) } ?? "HEAD" }
    /// An empty detail says nothing: open a release whenever the list has one and the open one is not in it. Search
    /// leaves the open release alone, so that typing does not read a release for every key.
    private var toOpen: HubItem? {
        let hub = store.hostingHub
        guard editor == nil, !hub.loading, !hub.detailLoading, !hub.busy, hub.error == nil, store.hubCredentialState != .loading else { return nil }
        if let open = hub.detail?.item, inFilter(open) { return nil }
        return items.first { $0.id == opened } ?? ReleaseCatalog.releaseToOpen(items)
    }

    var body: some View {
        Group {
            if let target = store.target {
                VStack(spacing: 0) {
                    HostedListHeader(target: target) { headerActions }
                    if blocked {
                        HostedAccountNeeded(target: target) { Task { await store.loadHostingHub() } }
                    } else {
                        summary
                        if let notice = store.hostingHub.notice { noticeView(notice) }
                        if let error = store.hostingHub.error, !store.hostingHub.items.isEmpty {
                            HostedListNotice(title: error) { retry() }.padding(.horizontal, compact ? 12 : 20).padding(.bottom, 12)
                        }
                        Divider()
                        columns
                    }
                }
            } else {
                HostedListEmpty(symbol: "globe", title: String(localized: "This repository has no GitHub or GitLab remote"),
                                caption: String(localized: "Releases, pull requests and runs need a hosting remote."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // the page is the surface colour, as the board draws it; the list column is a shade off it
        .background(StudioStyle.surface)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task(id: store.hubContextStamp(in: .releases)) {
            editor = nil; detailOpen = false; filter = "All releases"; family = nil; base = ""; opened = nil
            await store.activateHostingHub(.releases)
        }
        .task(id: distanceKey) { await loadDistances() }
        // not a task of its own: the id moves as soon as the read starts, which would cancel it
        .onChange(of: toOpen?.id, initial: true) { _, _ in if let item = toOpen { select(item) } }
        .onChange(of: store.hostingHub.uncertainWrite) { _, value in if value { editor = nil } }
    }

    @ViewBuilder private var headerActions: some View {
        Button { detailOpen = false; Task { await store.loadHostingHub() } } label: { Label("Refresh", symbol: "arrow.clockwise") }
            .buttonStyle(HostedListButtonStyle(iconOnly: true))
            .disabled(locked || editor != nil)
            .help("Refresh")
        Button { startEditor(false) } label: { Label("New release…", symbol: "plus") }
            .buttonStyle(HostedListButtonStyle())
            .disabled(locked || store.hubAccount == nil)
    }
    private func packageTitle(_ value: String) -> String {
        let name = ReleaseCatalog.packageName(store.hostingHub.items, family: value)
        return name.isEmpty ? String(localized: "Repository releases") : name
    }
    private func retry() {
        Task { if let d = store.hostingHub.detail { await store.selectHostingHubItem(d.item) } else { await store.loadHostingHub() } }
    }
    private func select(_ item: HubItem) {
        base = ""; otherFiles = false; opened = item.id
        Task { await store.selectHostingHubItem(item) }
    }

    /// What this branch has not released yet and the way there (Windows: ReleaseSummary.tsx). Without the tag in this
    /// clone the distance is unknown, so the card says what it does know: the newest release.
    @ViewBuilder private var summary: some View {
        let timeline = self.timeline
        if let latest = timeline.stable ?? timeline.prerelease {
            let tag = ReleaseCatalog.tag(latest)
            let value = store.url == nil ? Distances() : distances?.key == distanceKey ? distances?.value : nil
            let unknown = value != nil && value?.ahead == nil
            let atLast = value?.ahead == 0 && value?.behind == 0
            let caption = (value?.behind ?? 0) > 0 ? String(localized: "Not on top of {0}").replacingOccurrences(of: "{0}", with: tag) : String(localized: "since \(tag)")
            let key = !unknown ? String(localized: "Unreleased") : timeline.stable != nil && timeline.prerelease != nil ? String(localized: "Latest stable release") : String(localized: "Latest release")
            HostedListSummary(compact: compact) {
                HostedListSummaryCaption(text: key)
                if unknown {
                    Text(verbatim: tag).font(.system(size: 15, weight: .semibold)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    HostedListSummaryCaption(text: latest.title)
                } else if let value {
                    Text(verbatim: headline(value)).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    HostedListSummaryCaption(text: caption)
                } else {
                    HostedListSummaryCaption(text: String(localized: "Loading…"))
                }
            } middle: {
                if store.url != nil {
                    ReleaseTimelineTrack(nodes: timelineNodes(atLast: atLast), segments: timelineSegments(value: value, atLast: atLast), fork: timelineFork(value))
                } else { Color.clear }
            } trail: {
                compareBranch(tag, shown: !atLast && value?.ahead != nil)
            } strip: {
                DesignIconImage(icon: .releases, size: 13).foregroundStyle(HostedList.caption).accessibilityHidden(true)
                HostedListSummaryCaption(text: key).fixedSize()
                Text(verbatim: unknown ? tag : value.map(headline) ?? String(localized: "Loading…")).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 8)
                compareBranch(tag, shown: !atLast && value?.ahead != nil)
            }
            .accessibilityLabel("Versions")
        }
    }
    private func headline(_ value: Distances) -> String {
        let ahead = value.ahead ?? 0
        return ahead == 0 ? String(localized: "Nothing unreleased") : ahead == 1 ? String(localized: "1 commit on this branch") : String(localized: "\(ahead) commits on this branch")
    }
    @ViewBuilder private func compareBranch(_ tag: String, shown: Bool) -> some View {
        if shown {
            Button { store.showRevisionComparison(left: tag, right: store.headHash ?? "HEAD") } label: { Label("Compare…", symbol: "arrow.left.arrow.right") }
                .buttonStyle(HostedListButtonStyle())
                .help(String(localized: "Opens \(tag) … \("HEAD") in Compare"))
                .accessibilityLabel(String(localized: "Compare \(tag) with this branch"))
        }
    }
    private func timelineNodes(atLast: Bool) -> [ReleaseTimelineTrack.Node] {
        var nodes = line.map { item -> ReleaseTimelineTrack.Node in
            .init(label: ReleaseCatalog.tag(item), kind: item.id != line.last?.id ? .older : atLast ? .head : .latest)
        }
        if !atLast, store.headHash != nil { nodes.append(.init(label: "HEAD", kind: .head, help: headLabel)) }
        return nodes
    }
    private func timelineSegments(value: Distances?, atLast: Bool) -> [ReleaseTimelineTrack.Segment] {
        // Square roots keep a 200-commit gap from flattening the 10-commit ones next to it.
        func weight(_ commits: Int?) -> Double { commits.map { max(1, Double($0).squareRoot()) } ?? 3 }
        var segments = line.indices.dropFirst().map { index in ReleaseTimelineTrack.Segment(weight: weight(index - 1 < (value?.segments.count ?? 0) ? value?.segments[index - 1] : nil), dashed: false) }
        if !atLast, store.headHash != nil { segments.append(.init(weight: weight(value?.ahead), dashed: true)) }
        return segments
    }
    private func timelineFork(_ value: Distances?) -> ReleaseTimelineTrack.Fork? {
        fork.map { item in
            // a branch says where it sits; a bare commit says nothing a reader could use
            let tagged = ReleaseCatalog.taggedOn(commit: nil, target: item.data["target_commitish"] as? String ?? "")
            let caption = tagged.flatMap { $0.commit ? nil : String(localized: "Prerelease · on \($0.value)") } ?? String(localized: "Prerelease")
            return .init(label: ReleaseCatalog.tag(item), caption: caption, inHead: value?.prereleaseInHead == true)
        }
    }
    private func loadDistances() async {
        let key = distanceKey, tags = line.map(ReleaseCatalog.tag), prerelease = fork.map(ReleaseCatalog.tag)
        guard let url = store.url, !tags.isEmpty else { return }
        // refs/tags/ keeps a server-supplied tag from being read as an option or a branch
        func count(_ arguments: [String]) async -> [Int]? {
            guard let result = try? await Git.run(["rev-list"] + arguments, in: url, ok: [0, 128]), result.status == 0 else { return nil }
            return result.output.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        }
        var segments: [Int?] = []
        for index in tags.indices.dropFirst() { segments.append(await count(["--count", "refs/tags/\(tags[index - 1])..refs/tags/\(tags[index])"])?.first) }
        var sides: [Int]?, inHead = false
        if let head = store.headHash {
            sides = await count(["--left-right", "--count", "refs/tags/\(tags[tags.count - 1])...\(head)"])
            if let prerelease { inHead = await count(["--left-right", "--count", "refs/tags/\(prerelease)...\(head)"])?.first == 0 }
        }
        guard !Task.isCancelled, distanceKey == key else { return }
        distances = (key, Distances(segments: segments, ahead: sides?.count == 2 ? sides?[1] : nil, behind: sides?.count == 2 ? sides?[0] : nil, prereleaseInHead: inHead))
    }

    /// The list and the detail side by side; in a narrow window choosing a row replaces the list with the detail.
    private var columns: some View {
        HStack(spacing: 0) {
            if !(compact && detailOpen) {
                list
                    .frame(width: compact ? nil : HostedList.column)
                    .frame(maxWidth: compact ? .infinity : nil, maxHeight: .infinity, alignment: .top)
                    .background(StudioStyle.canvas)
                if !compact { Divider() }
            }
            if !compact || detailOpen {
                detail.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            if families.count > 1 { packageMenu }
            HostedListSearch(prompt: String(localized: "Search releases"), text: $store.hostingHub.query, menuTitle: String(localized: "Sort")) {
                Picker("Sort releases", selection: $sort) { Text("Newest first").tag("date"); Text("Version number").tag("version") }.pickerStyle(.inline)
            }
            HostedListSegments(options: filters.map { state in
                (value: state, title: Bundle.main.localizedString(forKey: state == "All releases" ? "All" : state, value: nil, table: nil), count: nil)
            }, selection: shown) { filter = $0 }
            if sort == "version" { Text("Version ordering applies to one SemVer package; other selections use published dates.").font(.system(size: 12)).foregroundStyle(HostedList.caption).fixedSize(horizontal: false, vertical: true) }
            rows
        }
        .padding(12)
    }
    /// Only a repository of several separately versioned products has one; it scopes the summary and the list alike
    private var packageMenu: some View {
        Menu {
            Picker("Package", selection: Binding(get: { current }, set: { family = $0; filter = "All releases"; detailOpen = false })) {
                ForEach(families, id: \.self) { value in Text(verbatim: packageTitle(value)).tag(value) }
            }.pickerStyle(.inline)
        } label: {
            HStack(spacing: 6) {
                Text(verbatim: packageTitle(current)).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                DesignIconImage(icon: .chevronDown, size: 12).foregroundStyle(HostedList.caption)
            }
            .padding(.horizontal, 10).frame(height: 28)
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.surface))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(HostedList.edge))
        .help("Package").accessibilityLabel("Package")
        .disabled(locked)
    }
    @ViewBuilder private var rows: some View {
        let hub = store.hostingHub, host = store.target?.host ?? ""
        if hub.error != nil && hub.items.isEmpty {
            HostedListEmpty(symbol: "xmark.circle.fill", title: String(localized: "Couldn't reach \(host)"), caption: hub.error, actionTitle: String(localized: "Retry"), failed: true) { retry() }
        } else if hub.items.isEmpty && (hub.loading || hub.page == 0) {
            HostedListLoading(caption: String(localized: "Loading releases…"))
            Spacer(minLength: 0)
        } else if items.isEmpty {
            if hub.items.isEmpty {
                HostedListEmpty(symbol: "tag", title: String(localized: "No releases yet"), caption: String(localized: "\(store.target?.path ?? "") has no releases."))
            } else if !hub.query.trimmingCharacters(in: .whitespaces).isEmpty {
                HostedListEmpty(symbol: "magnifyingglass", title: String(localized: "No releases match “\(hub.query)”"), actionTitle: String(localized: "Clear search")) { store.hostingHub.query = "" }
            } else {
                HostedListEmpty(symbol: "tag", title: String(localized: "No matching releases."), actionTitle: String(localized: "Show all releases")) { filter = "All releases" }
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(items) { item in row(item) }
                    }
                    // Keep pagination outside the lazy rows so repeated scrolls retain its position.
                    if hub.loading { ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(8) }
                    if hub.more {
                        Button { Task { await store.loadHostingHub(append: true) } } label: { Text("Load more").frame(maxWidth: .infinity) }.disabled(locked)
                            .buttonStyle(HostedListTextButtonStyle())
                        Text("Search filters loaded pages. Load more to search older items.").font(.system(size: 12)).foregroundStyle(HostedList.caption).frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
    private func when(_ item: HubItem) -> String? {
        if ReleaseCatalog.state(item) == "Draft" { return String(localized: "Not published") }
        return ListDate.parse(ReleaseCatalog.date(item)).map { ListDate.when($0, locale: locale) }
    }
    private func row(_ item: HubItem) -> some View {
        let selected = store.hostingHub.detail?.item.id == item.id && editor == nil
        return HostedListRow(selected: selected, action: { editor = nil; detailOpen = true; select(item) }) {
            HostedListRowTitle(title: item.title, when: when(item), selected: selected)
            HStack(spacing: 6) {
                Text(verbatim: ReleaseCatalog.tag(item)).font(.system(size: 11)).foregroundStyle(HostedList.secondary(selected: selected)).lineLimit(1).truncationMode(.middle)
                markers(item, selected: selected)
            }
        }
        .disabled(store.hostingHub.busy)
        .contextMenu { releaseMenu(item, selected: selected) }
    }
    /// Latest is a plain fact with the accent's dot; a prerelease or a draft is a state, with its reason on hover.
    /// Stable is the norm, so it gets no marker of its own.
    @ViewBuilder private func markers(_ item: HubItem, selected: Bool) -> some View {
        let state = ReleaseCatalog.state(item)
        if item.id == latest?.id { ReleaseLatestPill(selected: selected) }
        if state != "Stable" {
            HostedListChip(title: Bundle.main.localizedString(forKey: state, value: nil, table: nil), symbol: state == "Draft" ? nil : "tag", selected: selected, tone: state == "Draft" ? .neutral : .waiting)
                .fixedSize()
                .help(Self.stateHelp[state].map { LocalizedStringKey($0) } ?? "")
        }
    }
    /// The same actions on a selected row and behind the detail's more button; the others can only be opened or copied
    @ViewBuilder private func releaseMenu(_ item: HubItem, selected: Bool) -> some View {
        if safe(item.url) != nil {
            Button { open(item.url) } label: { Label("Open in browser", symbol: "arrow.up.right.square") }
            Button { store.copy(item.url) } label: { Label("Copy link", symbol: "link") }
        }
        if selected {
            Button { startEditor(true) } label: { Label("Edit", symbol: "pencil") }.disabled(locked)
            Divider()
            Button(role: .destructive) { confirmDelete(item) } label: { Label("Delete…", symbol: "trash") }.disabled(locked)
        }
    }
    private func confirmDelete(_ item: HubItem) {
        confirm(String(localized: "Delete this item?"), item.title + "\n" + String(localized: "This removes the remote item. Release tags and git history are kept."), destructive: true) { c in
            try await HostingHubAPI.delete(c, section: .releases, item: item); detailOpen = false
        }
    }

    @ViewBuilder private var detail: some View {
        VStack(spacing: 0) {
            if compact {
                HStack {
                    Button { detailOpen = false; editor = nil } label: { Label("Back to releases", symbol: "chevron.left") }.buttonStyle(HostedListButtonStyle())
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                Divider()
            }
            if editor != nil {
                ScrollView { editForm.padding(.horizontal, 24).padding(.vertical, 20).frame(maxWidth: .infinity, alignment: .topLeading) }
            } else if items.isEmpty && !store.hostingHub.loading {
                HostedListEmpty(symbol: "tag", title: String(localized: "No release to show"), caption: String(localized: "A release's notes, installers and comparison appear here."))
            } else if let d = store.hostingHub.detail {
                GeometryReader { geometry in
                    ScrollView { releaseDetail(d, width: geometry.size.width) }
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    private func releaseDetail(_ d: HubDetail, width: CGFloat) -> some View {
        let tag = ReleaseCatalog.tag(d.item)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                WorkbenchFlow(spacing: 8) {
                    Text(verbatim: tag).font(.system(size: 13)).foregroundStyle(HostedList.caption).textSelection(.enabled)
                    markers(d.item, selected: false)
                }
                // the title takes the line; its buttons move under it only when it would leave the title too narrow
                if width < 560 {
                    VStack(alignment: .leading, spacing: 10) { detailTitle(d); detailActions(d) }
                } else {
                    HStack(alignment: .center, spacing: 12) { detailTitle(d).frame(maxWidth: .infinity, alignment: .leading); detailActions(d) }
                }
                taggedLine(d, tag: tag).padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(StudioStyle.border).frame(height: 1) }
            .padding(.horizontal, 24).padding(.top, 20)
            // Notes beside the installers when there is room, the installers below them otherwise
            Group {
                if width >= 716 {
                    HStack(alignment: .top, spacing: 28) {
                        notes(d, tag: tag).frame(maxWidth: .infinity, alignment: .leading)
                        side(d, tag: tag).frame(width: 280)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 24) { notes(d, tag: tag).frame(maxWidth: .infinity, alignment: .leading); side(d, tag: tag) }
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 20)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    private func detailTitle(_ d: HubDetail) -> some View {
        Text(verbatim: d.item.title).font(.system(size: 22, weight: .semibold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }
    private func detailActions(_ d: HubDetail) -> some View {
        HStack(spacing: 6) {
            Button { startEditor(true) } label: { Label("Edit", symbol: "pencil") }.buttonStyle(HostedListButtonStyle()).disabled(locked)
            if safe(d.item.url) != nil {
                Button { open(d.item.url) } label: { Label("Open in browser", symbol: "arrow.up.right.square") }.buttonStyle(HostedListButtonStyle())
            }
            Menu { releaseMenu(d.item, selected: true) } label: { DesignIconImage(icon: .more, size: 12) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.surface))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(HostedList.edge))
                .help("More release actions").accessibilityLabel("More release actions")
                .disabled(locked)
        }.fixedSize()
    }
    /// The tag's commit when this clone has the tag, otherwise what the server says it was cut from
    @ViewBuilder private func taggedLine(_ d: HubDetail, tag: String) -> some View {
        let commit = store.tags.first { $0.name == tag }?.target
        let tagged = ReleaseCatalog.taggedOn(commit: commit, target: d.item.data["target_commitish"] as? String ?? "")
        HStack(spacing: 8) {
            if ReleaseCatalog.state(d.item) == "Draft" { Text("Not published") }
            if let tagged {
                Text("Tagged on \(Text(verbatim: tagged.value).font(.system(size: tagged.commit ? 11 : 12, design: tagged.commit ? .monospaced : .default)))").textSelection(.enabled)
            }
        }
        .font(.system(size: 12)).foregroundStyle(HostedList.caption)
    }
    @ViewBuilder private func notes(_ d: HubDetail, tag: String) -> some View {
        if d.item.body.isEmpty { Text("No release notes.").font(.system(size: 13)).foregroundStyle(HostedList.caption) }
        else { ReleaseMarkdown(text: d.item.body, target: store.target, tag: tag).font(.system(size: 13)) }
    }
    private func side(_ d: HubDetail, tag: String) -> some View {
        VStack(alignment: .leading, spacing: 12) { installers(d, tag: tag); compare(d, tag: tag) }
    }
    private func card<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(HostedList.caption)
            content()
        }
        .padding(.horizontal, 14).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(StudioStyle.border))
        .accessibilityElement(children: .contain).accessibilityLabel(title)
    }
    private func installers(_ d: HubDetail, tag: String) -> some View {
        let groups = ReleaseCatalog.assetGroups(d.assets, tag: tag) { $0.name }
        return card("Installers") {
            ForEach(groups.primary) { asset in assetRow(asset) }
            if !groups.other.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Rectangle().fill(StudioStyle.border).frame(height: 1)
                    Button { otherFiles.toggle() } label: {
                        HStack(spacing: 6) {
                            DesignIconImage(icon: otherFiles ? .chevronDown : .chevronRight, size: 12)
                            Text("Other files").font(.system(size: 13))
                            StatusPill(title: groups.other.count.formatted(), tone: .neutral)
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: 22).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityAddTraits(otherFiles ? .isSelected : [])
                    if otherFiles { ForEach(groups.other) { asset in assetRow(asset) } }
                }
                .padding(.top, 4)
            }
            if d.assets.isEmpty { Text("No release assets.").font(.system(size: 12)).foregroundStyle(HostedList.caption) }
        }
    }
    private func assetRow(_ asset: HubAsset) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                Text(asset.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle).help(asset.name).textSelection(.enabled)
                HStack(spacing: 4) { if let size = asset.size { Text(ReleaseCatalog.assetSize(size)) }; if asset.size != nil, asset.downloads != nil { Text(verbatim: "·") }; if let downloads = asset.downloads { Text("\(downloads) downloads") } }.font(.system(size: 12)).foregroundStyle(HostedList.caption)
                if safe(asset.url, asset: true) == nil { Text("External download blocked; inspect the release page.").font(.system(size: 12)).foregroundStyle(HostedList.caption) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if safe(asset.url, asset: true) != nil {
                Button { open(asset.url, asset: true) } label: { Label("Download in browser", symbol: "arrow.down.to.line") }.buttonStyle(HostedListButtonStyle(iconOnly: true)).help("Download in browser")
            }
        }
    }
    @ViewBuilder private func compare(_ d: HubDetail, tag: String) -> some View {
        let comparable = ReleaseCatalog.state(d.item) == "Draft" ? [] : ReleaseCatalog.ordered(store.hostingHub.items.filter { ReleaseCatalog.state($0) != "Draft" && ReleaseCatalog.compareURL(store.target, base: ReleaseCatalog.tag($0), head: tag) != nil })
        if !comparable.isEmpty {
            // Preselect the release before this one, preferring the same state (a stable compares with the previous stable).
            let older = comparable.filter { ReleaseCatalog.date($0) < ReleaseCatalog.date(d.item) }
            let fallback = older.first { ReleaseCatalog.state($0) == ReleaseCatalog.state(d.item) } ?? older.first ?? comparable.first
            let from = base.isEmpty ? fallback.map(ReleaseCatalog.tag) ?? "" : base
            let url = ReleaseCatalog.compareURL(store.target, base: from, head: tag)
            card("Compare") {
                WorkbenchFlow(spacing: 8) {
                    HStack(spacing: 6) {
                        Text("From").font(.system(size: 12)).foregroundStyle(HostedList.caption)
                        Picker("Compare from", selection: Binding(get: { from }, set: { base = $0 })) { ForEach(comparable) { Text(verbatim: ReleaseCatalog.tag($0)).tag(ReleaseCatalog.tag($0)) } }.labelsHidden().fixedSize()
                    }
                    Text(verbatim: "→").foregroundStyle(HostedList.caption).accessibilityHidden(true)
                    Text(verbatim: tag).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle).help(tag)
                }
                HStack(spacing: 6) {
                    Button { store.showRevisionComparison(left: from, right: tag) } label: { Label("Compare…", symbol: "arrow.left.arrow.right") }
                        .buttonStyle(HostedListButtonStyle()).disabled(from.isEmpty)
                        .help(String(localized: "Opens \(from) … \(tag) in Compare"))
                        .accessibilityLabel(String(localized: "Compare \(from) with \(tag)"))
                    Button { if let url { open(url.absoluteString) } } label: { Label("Compare in browser", symbol: "arrow.up.right.square") }
                        .buttonStyle(HostedListButtonStyle(iconOnly: true)).help("Compare in browser").disabled(url == nil)
                }
            }
        }
    }
    private var editForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editor == "new" ? String(localized: "New release") : String(localized: "Edit release")).font(.system(size: 15, weight: .semibold))
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
            HStack(spacing: 6) {
                Button("Review and save") { submit() }.hostedListFilledButton().disabled(input.tag.trimmingCharacters(in: .whitespaces).isEmpty || input.name.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") { editor = nil }.buttonStyle(HostedListButtonStyle())
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
    private func noticeView(_ message: String) -> some View {
        Text(message).font(.system(size: 12)).foregroundStyle(HostedList.caption).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(StudioStyle.border))
            .padding(.horizontal, compact ? 12 : 20).padding(.bottom, 12)
    }
}

/// The accent's dot and a word: the one release marked as the latest. It turns white on the selection tint.
private struct ReleaseLatestPill: View {
    let selected: Bool
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Color.accentColor).frame(width: 6, height: 6).accessibilityHidden(true)
            Text("Latest").lineLimit(1)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(StudioStyle.Tone.neutral.text)
        .padding(.horizontal, 8).frame(height: 18)
        .background(Capsule().fill(selected ? StudioStyle.surface : StudioStyle.Tone.neutral.fill))
        .fixedSize()
    }
}

/// Recent tags and the checkout on one line, dashed from the latest release to HEAD; a newer prerelease hangs above the
/// dashed part, on a branch of its own unless HEAD contains it. Only as many tags as fit are shown, the newest kept.
struct ReleaseTimelineTrack: View {
    enum Kind { case older, latest, head }
    struct Node { var label: String; var kind: Kind; var help: String? }
    struct Segment { var weight: Double; var dashed: Bool }
    struct Fork { var label: String; var caption: String; var inHead: Bool }
    let nodes: [Node]
    let segments: [Segment]
    var fork: Fork?
    // As the board draws it: nodes 96 wide, the line 40 below the top, the labels 20 under the line
    private let inset: CGFloat = 8, node: CGFloat = 96, height: CGFloat = 68, line: CGFloat = 40

    var body: some View {
        GeometryReader { geometry in
            let count = min(nodes.count, max(2, Int((geometry.size.width - 2 * inset) / 88)))
            let shownNodes = Array(nodes.suffix(count)), shownSegments = Array(segments.suffix(max(0, count - 1)))
            let centers = positions(width: geometry.size.width, segments: shownSegments, count: shownNodes.count)
            ZStack(alignment: .topLeading) {
                ForEach(shownSegments.indices, id: \.self) { index in
                    if index + 1 < centers.count {
                        Path { path in path.move(to: CGPoint(x: centers[index], y: line)); path.addLine(to: CGPoint(x: centers[index + 1], y: line)) }
                            .stroke(shownSegments[index].dashed ? StudioStyle.Tone.neutral.text : Color.primary.opacity(0.2), style: StrokeStyle(lineWidth: 2, dash: shownSegments[index].dashed ? [6, 4] : []))
                    }
                }
                if let fork, shownSegments.last?.dashed == true, centers.count > 1 { forkMark(fork, from: centers[centers.count - 2], to: centers[centers.count - 1], limit: geometry.size.width) }
                ForEach(shownNodes.indices, id: \.self) { index in
                    dot(shownNodes[index].kind).position(x: centers[index], y: line)
                    Text(verbatim: shownNodes[index].label)
                        .font(.system(size: 11, weight: shownNodes[index].kind == .older ? .regular : .semibold))
                        .foregroundStyle(shownNodes[index].kind == .older ? HostedList.caption : Color.primary)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(width: node).help(shownNodes[index].help ?? shownNodes[index].label).position(x: centers[index], y: line + 20)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(nodes.map(\.label).joined(separator: ", ") + (fork.map { ", " + $0.label + ", " + $0.caption } ?? ""))
    }
    /// The hollow dot sits on the dashed line when HEAD contains the prerelease, and at the end of a curve above it when not
    @ViewBuilder private func forkMark(_ fork: Fork, from start: CGFloat, to end: CGFloat, limit: CGFloat) -> some View {
        let x = fork.inHead ? start + min(44, (end - start) / 2) : start + 44, y: CGFloat = fork.inHead ? line : 11
        if !fork.inHead {
            Path { path in
                path.move(to: CGPoint(x: start + 25, y: line))
                path.addLine(to: CGPoint(x: start + 25, y: y + 10))
                path.addQuadCurve(to: CGPoint(x: start + 35, y: y), control: CGPoint(x: start + 25, y: y))
                path.addLine(to: CGPoint(x: x, y: y))
            }
            .stroke(Color.primary.opacity(0.2), lineWidth: 2)
        }
        Circle().fill(StudioStyle.surface).overlay(Circle().strokeBorder(StudioStyle.Tone.neutral.text, lineWidth: 2)).frame(width: 12, height: 12).position(x: x + 6, y: y)
        HStack(spacing: 6) {
            Text(verbatim: fork.label).foregroundStyle(StudioStyle.Tone.neutral.text).layoutPriority(1)
            Text(verbatim: fork.caption).foregroundStyle(HostedList.caption)
        }
        .font(.system(size: 11)).lineLimit(1)
        .frame(width: max(40, limit - x - 18), height: 16, alignment: .leading)
        .offset(x: x + 18, y: fork.inHead ? line - 24 : y - 8)
    }
    private func positions(width: CGFloat, segments: [Segment], count: Int) -> [CGFloat] {
        let first = inset + node / 2, last = max(first, width - inset - node / 2), total = segments.reduce(0) { $0 + $1.weight }
        guard count > 1, total > 0 else { return [first] }
        var result = [first], x = first
        for segment in segments.prefix(count - 1) {
            x += (last - first) * CGFloat(segment.weight / total)
            result.append(x)
        }
        return result
    }
    @ViewBuilder private func dot(_ kind: Kind) -> some View {
        switch kind {
        case .older: Circle().fill(HostedList.caption.opacity(0.75)).frame(width: 10, height: 10)
        case .latest: Circle().fill(StudioStyle.Tone.neutral.text).frame(width: 12, height: 12)
        case .head: Circle().fill(Color.accentColor).frame(width: 12, height: 12).background(Circle().fill(Color.accentColor.opacity(0.18)).frame(width: 18, height: 18))
        }
    }
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
