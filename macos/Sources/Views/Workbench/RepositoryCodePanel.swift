import SwiftUI
import AppKit

/// The Code page, as the redesign's Code boards draw it: one bar with the revision, back and forward, the file's path
/// and quick open; the folder's files in a column; and the open file under one row of view tabs (Source, History,
/// Blame, Working changes) with a status bar below. (Windows: widgets/local-workbench/ui/RepositoryCodePanel.tsx)
struct RepositoryCodePanel: View {
    @Environment(RepoStore.self) private var store
    @ViewState private var revisionInput = "HEAD"
    @ViewState private var revisionPicker = false
    @ViewState private var revisionSearch = ""
    @ViewState private var directory = ""
    @ViewState private var tree: RepositoryTreeSnapshot?
    @ViewState private var treeURL: URL?
    @ViewState private var selected: RepositoryTreeEntry?
    @ViewState private var preview: RepositoryBlobPreview?
    @ViewState private var mode = "Source"
    @ViewState private var loading = false
    @ViewState private var fileLoading = false
    @ViewState private var error: String?
    @ViewState private var treeRequest = UUID()
    @ViewState private var fileRequest = UUID()
    @ViewState private var explorerVisible = true
    @ViewState private var fontSize: CGFloat = 13
    @ViewState private var wraps = false
    @ViewState private var findText = ""
    @ViewState private var matchIndex = 0
    @ViewState private var navigation = RepositoryCodeNavigation()
    @ViewState private var quickOpen = false
    @ViewState private var panelWidth: CGFloat = 600
    @ViewState private var languages: [RepositoryLanguages.Segment] = []
    @ViewState private var languageFilter: String?
    @ViewState private var editors: [ExternalEditor] = []
    /// The commits that changed the open file, read once per file for the History tab and its count; nil while reading
    @ViewState private var history: [FileHistoryEntry]?
    @ViewState private var historyPath: String?
    @ViewState private var historyRequest = UUID()
    /// The commits of the history that are on no remote yet
    @ViewState private var local: Set<String> = []
    @ViewState private var historySelected: String?
    @ViewState private var blame: [BlameLine]?
    @ViewState private var blameWidth: CGFloat = 0
    /// Lines of what the open view shows, for the status bar
    @ViewState private var lineCount: Int?

    private var modes: [String] { ["Source"] + (selected.map { supportsPreview($0.path) } == true ? ["Preview"] : []) + ["History", "Blame", "Working changes"] }
    private var prefix: String { directory.isEmpty ? "" : directory + "/" }
    private var parentDirectory: String { directory.split(separator: "/").dropLast().joined(separator: "/") }
    private var matching: [RepositoryTreeEntry] { tree?.entries.filter { entry in
        if let languageFilter { return entry.isFile && RepositoryLanguages.language(for: entry.path) == languageFilter }
        return entry.path.hasPrefix(prefix) && !entry.path.dropFirst(prefix.count).contains("/")
    } ?? [] }
    private var folders: [String] { guard languageFilter == nil else { return [] }; return Array(Set((tree?.entries ?? []).filter { $0.path.hasPrefix(prefix) && $0.path.dropFirst(prefix.count).contains("/") }.map { prefix + String($0.path.dropFirst(prefix.count).split(separator: "/")[0]) })).sorted() }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(StudioStyle.Tone.failed.text)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 8)
                Divider()
            }
            Group {
                if explorerVisible {
                    AdaptiveWorkbenchSplit(listWidth: 240) { files } detail: { document }
                } else { document }
            }
            .background(StudioStyle.surface)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(StudioStyle.surface)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { panelWidth = $0 }
        .sheet(isPresented: $quickOpen) {
            RepositoryQuickOpen(paths: tree?.entries.map(\.path) ?? [], recent: navigation.recent, width: panelWidth, open: { path in
                quickOpen = false
                if let entry = tree?.entries.first(where: { $0.path == path }) { requestOpen(entry) }
            }, close: { quickOpen = false })
        }
        .task(id: store.url) { editors = ExternalEditors.editors(); revisionInput = "HEAD"; findText = ""; await loadTree() }
        .onChange(of: languageFilter) { _, value in if value != nil { directory = "" } }
        .onDisappear { treeRequest = UUID(); fileRequest = UUID(); historyRequest = UUID() }
    }

    // MARK: Bar

    /// One row: the revision, back and forward, the path and quick open. A narrow window puts the path and quick open
    /// on a second line, as the board's bar wraps.
    private var toolbar: some View {
        let wide = panelWidth >= 760
        return VStack(spacing: 8) {
            HStack(spacing: 10) {
                revisionButton
                separator
                HStack(spacing: 4) {
                    Button { navigate(-1) } label: { Image(systemName: "chevron.left").font(.system(size: 12, weight: .medium)) }
                        .disabled(!navigation.canGoBack).help("Navigate back").accessibilityLabel("Navigate back").accessibilityIdentifier("code-back")
                    Button { navigate(1) } label: { Image(systemName: "chevron.right").font(.system(size: 12, weight: .medium)) }
                        .disabled(!navigation.canGoForward).help("Navigate forward").accessibilityLabel("Navigate forward").accessibilityIdentifier("code-forward")
                }
                .buttonStyle(RepositoryCodeBarButton(square: true))
                if wide {
                    separator
                    breadcrumb
                    quickOpenField.frame(width: panelWidth >= 980 ? 280 : 200)
                } else {
                    Spacer(minLength: 0)
                }
                // the board has no place for these two; they stay at the end of the bar
                RepositoryExternalEditorMenu(editors: editors, fileAvailable: selected?.isFile == true && treeURL == store.url,
                    open: openExternal, refresh: { editors = ExternalEditors.editors() }).disabled(store.url == nil)
                Button { explorerVisible.toggle() } label: { Image(systemName: "sidebar.left").foregroundStyle(StudioStyle.Rail.icon).frame(width: 24, height: 24).contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .help(explorerVisible ? String(localized: "Hide file explorer") : String(localized: "Show file explorer"))
                    .accessibilityLabel(explorerVisible ? String(localized: "Hide file explorer") : String(localized: "Show file explorer"))
            }
            if !wide {
                HStack(spacing: 10) {
                    breadcrumb
                    quickOpenField.frame(width: 160)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(minHeight: 44)
    }

    private var separator: some View { StudioStyle.border.frame(width: 1, height: 16).accessibilityHidden(true) }

    /// The revision shown: its short hash and, when it has one, its name. No counts: the tabs and lists own those.
    private var revisionButton: some View {
        let name = tree.flatMap { RepositoryCodeHistory.revisionName(input: revisionInput, revision: $0.revision, branch: store.headBranch) }
        // a long branch name is cut in the middle; a narrow window leaves it less room
        let room: CGFloat = panelWidth >= 760 ? 200 : 130
        return Button { revisionSearch = ""; revisionPicker = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "circle.and.line.horizontal").font(.system(size: 12)).foregroundStyle(StudioStyle.Rail.icon)
                if loading {
                    ProgressView().controlSize(.small)
                } else if let tree {
                    Text(String(tree.revision.prefix(7))).font(.system(size: 12, design: .monospaced)).fixedSize()
                    if let name {
                        Text(verbatim: "·").foregroundStyle(StudioStyle.Rail.icon).fixedSize().accessibilityHidden(true)
                        Text(name).lineLimit(1).truncationMode(.middle).frame(maxWidth: room).fixedSize()
                    }
                } else {
                    Text(revisionInput).lineLimit(1).truncationMode(.middle).frame(maxWidth: room).fixedSize()
                }
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(StudioStyle.Rail.icon)
            }
        }
        .buttonStyle(RepositoryCodeBarButton())
        .help("Choose a branch or tag")
        .accessibilityLabel(String(localized: "Revision") + " " + (tree.map { String($0.revision.prefix(7)) } ?? revisionInput) + (name.map { ", " + $0 } ?? ""))
        .accessibilityHint("Choose a branch or tag")
        .popover(isPresented: $revisionPicker, arrowEdge: .bottom) { revisionList }
    }

    /// Any revision can be typed; the branches and tags below narrow as it is typed
    private var revisionList: some View {
        let typed = revisionSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let refs = store.localBranches.map { ("arrow.triangle.branch", $0.name) } + store.remoteBranches.map { ("cloud", $0.name) } + store.tags.map { ("tag", $0.name) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TextField("Revision", text: $revisionSearch).textFieldStyle(.roundedBorder).onSubmit { if RepositoryBrowser.validRevision(typed) { load(typed) } }
                Button("Load revision") { load(typed) }.disabled(!RepositoryBrowser.validRevision(typed) || loading)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(refs.filter { typed.isEmpty || $0.1.localizedCaseInsensitiveContains(typed) }, id: \.1) { icon, name in
                        RepositoryCodeRow(selected: name == revisionInput, action: { load(name) }) {
                            HStack(spacing: 8) {
                                Image(systemName: icon).font(.system(size: 12)).foregroundStyle(StudioStyle.Rail.icon).frame(width: 14)
                                Text(name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                            }
                            .padding(.horizontal, 10).frame(height: 28)
                        }
                    }
                }
            }
            .frame(maxHeight: 280)
        }
        .padding(12)
        .frame(width: 320)
    }

    /// The open file's folders, each a step back to that folder, then the file. Folders drop from the start when the
    /// bar is short of room; the file name is never cut (docs/design.md, Text).
    private var breadcrumb: some View {
        let folders = (selected.map { ($0.path as NSString).deletingLastPathComponent } ?? directory).split(separator: "/").map(String.init)
        let name = selected.map { ($0.path as NSString).lastPathComponent }
        return ViewThatFits(in: .horizontal) {
            ForEach(0...folders.count, id: \.self) { dropped in
                HStack(spacing: 4) {
                    if dropped > 0 { Text(verbatim: "…").foregroundStyle(.tertiary) }
                    ForEach(Array(folders.enumerated().dropFirst(dropped)), id: \.offset) { index, folder in
                        if index > 0 { Text(verbatim: "›").foregroundStyle(.tertiary).accessibilityHidden(true) }
                        RepositoryCodeCrumb(title: folder) { directory = folders.prefix(index + 1).joined(separator: "/"); languageFilter = nil }
                    }
                    if let name {
                        if !folders.isEmpty { Text(verbatim: "›").foregroundStyle(.tertiary).accessibilityHidden(true) }
                        Text(name).fontWeight(.semibold).lineLimit(1).fixedSize().padding(.horizontal, 4)
                    }
                }
                .font(.system(size: 13))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 28)
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("File path")
    }

    /// Opens the quick-open palette; drawn as the field it leads to
    private var quickOpenField: some View {
        Button { quickOpen = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12))
                Text("Quick open").lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: "⌘P").font(.system(size: 12))
            }
            .font(.system(size: 13)).foregroundStyle(StudioStyle.Rail.icon)
            .padding(.horizontal, 10).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.surface))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.16)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("p", modifiers: .command).disabled(tree == nil || loading).accessibilityIdentifier("code-quick-open")
    }

    // MARK: Files

    private var files: some View {
        let changed = Dictionary(store.status.files.map { ($0.path, $0.kind) }, uniquingKeysWith: { first, _ in first })
        return VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if !directory.isEmpty && languageFilter == nil {
                        RepositoryCodeRow(selected: false, action: { directory = parentDirectory }) {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.turn.left.up").font(.system(size: 11)).foregroundStyle(StudioStyle.Rail.icon).frame(width: 14)
                                Text(verbatim: "..").font(.system(size: 12, design: .monospaced)).foregroundStyle(StudioStyle.Tone.neutral.text)
                            }
                            .padding(.leading, 10).padding(.trailing, 6).frame(height: 28)
                        }
                        .help("Parent folder").accessibilityLabel("Parent folder").accessibilityIdentifier("code-parent-folder")
                    }
                    ForEach(folders, id: \.self) { folder in
                        RepositoryCodeRow(selected: false, action: { directory = folder }) {
                            HStack(spacing: 8) {
                                Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(StudioStyle.Rail.icon).frame(width: 14)
                                Text(String(folder.dropFirst(prefix.count))).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                            }
                            .padding(.leading, 10).padding(.trailing, 6).frame(height: 28)
                        }
                        .help(folder)
                    }
                    ForEach(Array(matching.prefix(2000))) { entry in
                        let current = selected?.path == entry.path
                        RepositoryCodeRow(selected: current, action: { requestOpen(entry) }) {
                            HStack(spacing: 8) {
                                Image(systemName: entry.isSubmodule ? "shippingbox" : entry.isSymlink ? "link" : "doc").font(.system(size: 12)).foregroundStyle(StudioStyle.Rail.icon).frame(width: 14)
                                Text(languageFilter == nil ? String(entry.path.dropFirst(prefix.count)) : entry.path).font(.system(size: 13, weight: current ? .semibold : .regular))
                                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                                // changed in the working tree and not committed yet
                                if let kind = changed[entry.path] { StatusBadge(kind: kind) }
                            }
                            .padding(.leading, 10).padding(.trailing, 6).frame(height: 28)
                        }
                        .help(entry.path)
                    }
                    if matching.count > 2000 { Text("Showing the first 2,000 matches. Search to narrow the file list.").font(.caption).foregroundStyle(.secondary).padding(10) }
                    if tree != nil && matching.isEmpty && folders.isEmpty { ContentUnavailableView("No matching files", systemImage: "doc.text.magnifyingglass") }
                }
                .padding(.horizontal, 8).padding(.vertical, 10)
            }
            if !languages.isEmpty {
                Divider()
                RepositoryLanguageControl(segments: languages, truncated: tree?.truncated == true, selected: $languageFilter)
            }
            if tree?.truncated == true { Text("File list truncated. Narrow the repository or use another tool for the remaining files.").font(.caption).foregroundStyle(StudioStyle.Tone.waiting.text).padding(10) }
        }
        // the split draws its line 2 pt past the column: the fill reaches it
        .background(StudioStyle.canvas.padding(.trailing, -3))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Files")
    }

    // MARK: Document

    @ViewBuilder private var document: some View {
        VStack(alignment: .leading, spacing: 0) {
            // one open file needs no tab of its own
            if navigation.tabs.count > 1 {
                fileTabs
                Divider()
            }
            if let selected {
                viewTabs(selected)
                Divider()
                if let notice = preview?.notice { Label(notice, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8) }
                content(selected).frame(maxWidth: .infinity, maxHeight: .infinity)
                statusBar(selected)
            } else {
                ContentUnavailableView("Choose a file", systemImage: "doc.text.magnifyingglass", description: Text("Search paths or choose a file from the repository tree."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fileTabs: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                    ForEach(navigation.tabs, id: \.self) { path in
                        let current = selected?.path == path
                        HStack(spacing: 6) {
                            Button {
                                if let entry = tree?.entries.first(where: { $0.path == path }) { requestOpen(entry, view: navigation.tabModes[path] ?? "Source") }
                            } label: {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text((path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                                    if navigation.tabs.filter({ ($0 as NSString).lastPathComponent == (path as NSString).lastPathComponent }).count > 1 {
                                        Text((path as NSString).deletingLastPathComponent.isEmpty ? String(localized: "Repository") : (path as NSString).deletingLastPathComponent).font(.system(size: 11)).foregroundStyle(StudioStyle.Rail.icon).lineLimit(1).truncationMode(.head)
                                    }
                                }.frame(minWidth: 60, maxWidth: 180, alignment: .leading)
                            }.accessibilityIdentifier("code-tab-" + path)
                            Button { closeTab(path) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .medium)).foregroundStyle(StudioStyle.Rail.icon).frame(width: 16, height: 16).contentShape(Rectangle()) }
                                .help("Close file").accessibilityLabel("Close file").accessibilityIdentifier("code-close-" + path)
                        }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(current ? AnyShapeStyle(.primary) : AnyShapeStyle(StudioStyle.Tone.neutral.text))
                            .padding(.horizontal, 12).frame(maxHeight: .infinity)
                            .overlay(alignment: .bottom) { if current { StudioStyle.accent.frame(height: 2) } }
                            .id(path).help(path).accessibilityAddTraits(current ? .isSelected : [])
                    }
                    }.padding(.horizontal, 16)
                }.scrollIndicators(.hidden).accessibilityLabel("Open files")
                    .onChange(of: selected?.path) { _, path in if let path { proxy.scrollTo(path, anchor: .center) } }
            }
            Button(action: closeAllFiles) { Image(systemName: "xmark.square").foregroundStyle(StudioStyle.Rail.icon).frame(width: 24, height: 24).contentShape(Rectangle()) }.padding(.trailing, 12)
                .help("Close all files").accessibilityLabel("Close all files").accessibilityIdentifier("code-close-all")
        }.buttonStyle(.plain).frame(height: Set(navigation.tabs.map { ($0 as NSString).lastPathComponent }).count == navigation.tabs.count ? 36 : 44)
            .background(StudioStyle.canvas)
    }

    /// Source, History with its count, Blame and Working changes: underline tabs, so a label never shifts
    private func viewTabs(_ selected: RepositoryTreeEntry) -> some View {
        WorkbenchFlow(spacing: 4) {
            ForEach(modes, id: \.self) { value in
                Button { requestOpen(selected, view: value) } label: {
                    HStack(spacing: 6) {
                        Text(LocalizedStringKey(value))
                        if value == "History", let history, !history.isEmpty { StatusPill(title: RepositoryCodeHistory.countLabel(history.count), tone: .neutral) }
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(mode == value ? AnyShapeStyle(.primary) : AnyShapeStyle(StudioStyle.Tone.neutral.text))
                    .padding(.horizontal, 12).frame(height: 35)
                    .overlay(alignment: .bottom) { if mode == value { StudioStyle.accent.frame(height: 2) } }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(!selected.isFile && value != "Source")
                .accessibilityAddTraits(mode == value ? .isSelected : [])
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func content(_ selected: RepositoryTreeEntry) -> some View {
        if fileLoading {
            VStack { Spacer(); ProgressView("Loading…").controlSize(.small); Spacer() }.frame(maxWidth: .infinity)
        } else if mode == "History", let repository = treeURL {
            RepositoryCodeHistoryView(repository: repository, entries: history, local: local, selected: $historySelected, wraps: $wraps, lineCount: $lineCount)
        } else if mode == "Working changes", let repository = treeURL {
            RepositoryCodeChangesView(repository: repository, path: selected.path, commit: nil, wraps: $wraps, lineCount: $lineCount)
        } else if mode == "Blame", let blame, !blame.isEmpty {
            RepositoryCodeBlameView(lines: blame, textWidth: blameWidth, wraps: wraps, show: { store.reveal($0) }, before: blameBefore)
        } else if mode == "Preview", let text = preview?.text {
            if ["html", "htm"].contains((selected.path as NSString).pathExtension.lowercased()), let tree, let repository = treeURL {
                RepositoryHTMLPreview(text: text, entry: selected, tree: tree, repository: repository)
            } else { ScrollView { MarkdownView(text).padding(24) }.frame(maxWidth: .infinity, maxHeight: .infinity) }
        } else if mode == "Source", let data = preview?.image, let image = NSImage(data: data) {
            ScrollView([.horizontal, .vertical]) { Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 1200).padding(24) }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if mode == "Source", let text = preview?.text {
            RepositoryCodeReader(text: text, path: selected.path, syntax: true, fontSize: $fontSize, wraps: $wraps, findText: $findText, matchIndex: $matchIndex, statusBar: false)
        } else {
            ContentUnavailableView("No content to show.", systemImage: "doc.text")
        }
    }

    /// One grammar for every view: what is shown on the left; the language, the lines and "Read only" on the right
    private func statusBar(_ selected: RepositoryTreeEntry) -> some View {
        let language = RepositoryLanguages.language(for: selected.path)
        var facts = [Bundle.main.localizedString(forKey: language == "Other files" ? "Plain text" : language, value: nil, table: nil)]
        if preview?.image != nil, mode == "Source" { facts = [ByteCountFormatter.string(fromByteCount: Int64(selected.size), countStyle: .file)] }
        else if let lineCount { facts.append(String(localized: "{0} lines").replacingOccurrences(of: "{0}", with: lineCount.formatted())) }
        facts.append(String(localized: "Read only"))
        return HStack(spacing: 12) {
            Text(shown).lineLimit(1)
            Spacer(minLength: 0)
            Text(facts.joined(separator: " · ")).lineLimit(1).fixedSize()
                .help(ByteCountFormatter.string(fromByteCount: Int64(selected.size), countStyle: .file))
        }
        .font(.system(size: 12)).foregroundStyle(StudioStyle.Rail.icon)
        .padding(.horizontal, 16).frame(height: 24)
        .background(StudioStyle.canvas)
        .overlay(alignment: .top) { Divider() }
    }

    /// What the open view shows, in a sentence; a hash in it is set in the monospaced font
    private var shown: AttributedString {
        var hash = tree.map { String($0.revision.prefix(7)) } ?? ""
        let sentence: String
        switch mode {
        case "History":
            let entry = history?.first { $0.id == historySelected } ?? history?.first
            hash = entry?.commit.short ?? ""
            // a first commit has no parent to compare with
            sentence = entry == nil ? "" : entry?.commit.parents.isEmpty == true ? String(localized: "As of commit \(hash)") : String(localized: "Changes in \(hash) against its parent")
        case "Blame": sentence = String(localized: "Blame of the revision shown · uncommitted changes not shown")
        case "Working changes": sentence = String(localized: "Uncommitted changes against HEAD")
        default: sentence = hash.isEmpty ? "" : String(localized: "As of commit \(hash)")
        }
        var text = AttributedString(sentence)
        if !hash.isEmpty, let range = text.range(of: hash) { text[range].font = .system(size: 11, design: .monospaced) }
        return text
    }

    // MARK: Reading

    private func load(_ revision: String) {
        revisionInput = revision; revisionPicker = false
        Task { await loadTree() }
    }

    private func loadTree(reopen path: String? = nil, view: String = "Source") async {
        guard let url = store.url else { return }
        let token = UUID(); treeRequest = token; fileRequest = UUID(); historyRequest = UUID(); loading = true; fileLoading = false; error = nil; tree = nil; treeURL = nil; directory = ""; selected = nil; preview = nil; blame = nil; history = nil; historyPath = nil; lineCount = nil; navigation = RepositoryCodeNavigation(); quickOpen = false; languages = []; languageFilter = nil
        do {
            let value = try await RepositoryBrowser.tree(in: url, ref: revisionInput)
            guard !Task.isCancelled, store.url == url, treeRequest == token else { return }
            tree = value
            treeURL = url
            let summary = await Task.detached(priority: .userInitiated) { RepositoryLanguages.composition(value.entries) }.value
            guard !Task.isCancelled, store.url == url, treeRequest == token else { return }
            languages = summary
            if let entry = path.flatMap({ path in value.entries.first { $0.path == path } }) {
                await open(entry, view: view)
            } else if let entry = RepositoryBrowser.initialFile(value.entries) {
                await open(entry)
            }
        } catch { if !Task.isCancelled && store.url == url && treeRequest == token { self.error = store.describe(error) } }
        if store.url == url && treeRequest == token { loading = false }
    }

    private func open(_ entry: RepositoryTreeEntry, view: String = "Source", record: Bool = true) async {
        guard let url = store.url, treeURL == url, let tree, tree.entries.first(where: { $0.path == entry.path }) == entry else { return }
        let token = UUID(), snapshot = tree.revision; fileRequest = token; selected = entry; mode = view; preview = nil; blame = nil; lineCount = nil; error = nil; matchIndex = 0
        directory = entry.path.split(separator: "/").dropLast().joined(separator: "/")
        navigation.visit(entry.path, mode: view, record: record)
        if historyPath != entry.path { Task { await loadHistory(entry.path, revision: snapshot, in: url) } }
        // History and Working changes read for themselves
        guard ["Source", "Preview", "Blame"].contains(view) else { fileLoading = false; return }
        fileLoading = true
        func current() -> Bool { !Task.isCancelled && store.url == url && self.tree?.revision == snapshot && fileRequest == token }
        defer { if current() { fileLoading = false } }
        do {
            let value = try await RepositoryBrowser.blob(in: url, entry: entry)
            guard current() else { return }
            preview = value
            let count = await Task.detached(priority: .userInitiated) { value.text.map { RepositoryCodeReading.lineStarts(in: $0).count } }.value
            guard current() else { return }
            guard view == "Blame" else { lineCount = count; return }
            guard let count, count > 0 else { blame = []; return }
            let output = try await Git.run(RepositoryCodeHistory.blameArgs(revision: snapshot, path: entry.path, lines: count), in: url).output
            let parsed = await Task.detached(priority: .userInitiated) { () -> ([BlameLine], CGFloat) in
                let lines = Parsers.blame(output)
                return (lines, RepositoryCodeText.width(lines.map(\.text)))
            }.value
            guard current() else { return }
            blame = parsed.0; blameWidth = parsed.1; lineCount = parsed.0.count
        } catch { if current() { self.error = store.describe(error) } }
    }

    /// The commits that changed a file, for the History tab and its count, and which of them are not pushed yet
    private func loadHistory(_ path: String, revision: String, in url: URL) async {
        let token = UUID(); historyRequest = token; historyPath = path; history = nil; local = []; historySelected = nil
        func current() -> Bool { historyRequest == token && store.url == url && tree?.revision == revision }
        // stepping through files quickly must not start a log for each of them
        try? await Task.sleep(for: .milliseconds(250))
        guard current() else { return }
        guard let output = try? await Git.run(RepositoryCodeHistory.logArgs(revision: revision, path: path, format: Parsers.fileHistoryFormat), in: url).output else {
            if current() { history = [] }
            return
        }
        let entries = await Task.detached(priority: .userInitiated) { Parsers.fileHistory(output) }.value
        guard current() else { return }
        history = entries
        // "local" means not on a remote, so it needs one
        guard !store.remoteBranches.isEmpty, !entries.isEmpty,
              let ids = try? await Git.run(RepositoryCodeHistory.localArgs(revision: revision), in: url).output, current() else { return }
        local = Set(ids.split(whereSeparator: \.isNewline).map(String.init))
    }

    /// "Blame before this change": the page moves to the commit's parent and blames the file there
    private func blameBefore(_ commit: String) -> (() -> Void)? {
        guard let history, let target = RepositoryCodeHistory.before(commit, in: history.map { ($0.commit.id, $0.commit.parents.first, $0.path) }) else { return nil }
        return {
            revisionInput = target.revision
            Task { await loadTree(reopen: target.path, view: "Blame") }
        }
    }

    private func requestOpen(_ entry: RepositoryTreeEntry, view: String = "Source", record: Bool = true) {
        let generation = treeRequest
        Task {
            guard treeRequest == generation else { return }
            await open(entry, view: view, record: record)
        }
    }

    private func navigate(_ delta: Int) {
        guard let location = navigation.move(delta), let entry = tree?.entries.first(where: { $0.path == location.path }) else { return }
        requestOpen(entry, view: location.mode, record: false)
    }

    private func closeTab(_ path: String) {
        let active = selected?.path
        let next = navigation.close(path, selected: active)
        guard active == path else { return }
        if let next, let entry = tree?.entries.first(where: { $0.path == next }) { requestOpen(entry, view: navigation.tabModes[next] ?? "Source") }
        else { clearFile() }
    }

    private func closeAllFiles() { navigation.closeAll(); clearFile() }

    private func clearFile() {
        fileRequest = UUID(); historyRequest = UUID(); selected = nil; preview = nil; blame = nil; history = nil; historyPath = nil; lineCount = nil; fileLoading = false; error = nil
    }

    private func supportsPreview(_ path: String) -> Bool { ["html", "htm", "md", "markdown"].contains((path as NSString).pathExtension.lowercased()) }

    private func openExternal(_ editorID: String, file: Bool) {
        guard let repository = store.url, !file || selected?.isFile == true else { return }
        let path = file ? selected?.path : nil, generation = treeRequest, applications = editors
        Task {
            guard store.url == repository, treeRequest == generation else { return }
            do { try await ExternalEditors.open(repository: repository, editorID: editorID, file: path, available: applications) }
            catch { if store.url == repository { self.error = store.describe(error) } }
        }
    }
}

/// A list row of the Code page: 6 pt corners, and the selection tint or the hover fill, never a bar or an outline.
/// It keeps its own hover, so the pointer does not redraw the page around it.
struct RepositoryCodeRow<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let content: Content
    @ViewState private var hover = false

    var body: some View {
        Button(action: action) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(selected ? StudioStyle.selection : hover ? StudioStyle.hover : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A folder of the open file's path
private struct RepositoryCodeCrumb: View {
    let title: String
    let action: () -> Void
    @ViewState private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title).foregroundStyle(StudioStyle.Rail.icon).lineLimit(1).fixedSize()
                .padding(.horizontal, 4).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(hover ? StudioStyle.hover : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// A 28 pt bordered control of the Code page's bar. Disabled, it turns neutral instead of fading (docs/design.md, Controls).
private struct RepositoryCodeBarButton: ButtonStyle {
    var square = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(StudioStyle.Rail.blocked))
            .padding(.horizontal, square ? 0 : 10)
            .frame(width: square ? 28 : nil, height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(!enabled ? StudioStyle.canvas : configuration.isPressed ? StudioStyle.hover : StudioStyle.surface))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(enabled ? 0.16 : 0.09)))
            .contentShape(Rectangle())
    }
}
