import SwiftUI
import AppKit

struct RepositoryCodePanel: View {
    @Environment(RepoStore.self) private var store
    @ViewState private var revisionInput = "HEAD"
    @ViewState private var query = ""
    @ViewState private var directory = ""
    @ViewState private var tree: RepositoryTreeSnapshot?
    @ViewState private var treeURL: URL?
    @ViewState private var selected: RepositoryTreeEntry?
    @ViewState private var preview: RepositoryBlobPreview?
    @ViewState private var mode = "Source"
    @ViewState private var auxiliary: String?
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
    private var modes: [String] { ["Source"] + (selected.map { supportsPreview($0.path) } == true ? ["Preview"] : []) + ["File history", "Blame", "Working changes"] }
    private var prefix: String { directory.isEmpty ? "" : directory + "/" }
    private var parentDirectory: String { directory.split(separator: "/").dropLast().joined(separator: "/") }
    private var matching: [RepositoryTreeEntry] { tree?.entries.filter { entry in
        if let languageFilter { return entry.isFile && RepositoryLanguages.language(for: entry.path) == languageFilter && (query.isEmpty || entry.path.localizedCaseInsensitiveContains(query)) }
        return query.isEmpty ? entry.path.hasPrefix(prefix) && !entry.path.dropFirst(prefix.count).contains("/") : entry.path.localizedCaseInsensitiveContains(query)
    } ?? [] }
    private var folders: [String] { guard query.isEmpty && languageFilter == nil else { return [] }; return Array(Set((tree?.entries ?? []).filter { $0.path.hasPrefix(prefix) && $0.path.dropFirst(prefix.count).contains("/") }.map { prefix + String($0.path.dropFirst(prefix.count).split(separator: "/")[0]) })).sorted() }

    var body: some View {
        VStack(spacing: 0) {
            revisionToolbar
            navigationToolbar
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            Group {
                if explorerVisible {
                    AdaptiveWorkbenchSplit(listWidth: 245) { explorer } detail: { content }
                } else { content }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor).opacity(0.6)))
            .padding(.horizontal, 16).padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { panelWidth = $0 }
        .sheet(isPresented: $quickOpen) {
            RepositoryQuickOpen(paths: tree?.entries.map(\.path) ?? [], recent: navigation.recent, width: panelWidth, open: { path in
                quickOpen = false
                if let entry = tree?.entries.first(where: { $0.path == path }) { requestOpen(entry) }
            }, close: { quickOpen = false })
        }
        .task(id: store.url) { editors = ExternalEditors.editors(); revisionInput = "HEAD"; query = ""; findText = ""; await loadTree() }
        .onChange(of: languageFilter) { _, value in if value != nil { directory = "" } }
        .onDisappear { treeRequest = UUID(); fileRequest = UUID() }
    }

    private var revisionToolbar: some View {
        HStack(spacing: 9) {
            Button { explorerVisible.toggle() } label: { Image(systemName: "sidebar.left") }
                .help(explorerVisible ? String(localized: "Hide file explorer") : String(localized: "Show file explorer"))
                .accessibilityLabel(explorerVisible ? String(localized: "Hide file explorer") : String(localized: "Show file explorer"))
                .buttonStyle(.borderless)
            Divider().frame(height: 18)
            Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
            TextField("Revision", text: $revisionInput).textFieldStyle(.roundedBorder)
                .frame(minWidth: 80, maxWidth: 210).onSubmit { Task { await loadTree() } }
            Menu {
                ForEach(store.localBranches) { branch in Button(branch.name) { revisionInput = branch.name; Task { await loadTree() } } }
                ForEach(store.remoteBranches) { branch in Button(branch.name) { revisionInput = branch.name; Task { await loadTree() } } }
                ForEach(store.tags) { tag in Button(tag.name) { revisionInput = tag.name; Task { await loadTree() } } }
            } label: { Image(systemName: "chevron.down") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Choose a branch or tag")
                .accessibilityLabel("Choose a branch or tag")
            Button("Load revision") { Task { await loadTree() } }.disabled(loading)
            Spacer(minLength: 0)
            if loading { ProgressView().controlSize(.small) }
            else if let tree { Text(String(tree.revision.prefix(8))).font(.caption.monospaced()).foregroundStyle(.secondary).help(tree.revision) }
        }.padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 10)
    }

    private var navigationToolbar: some View {
        HStack(spacing: 8) {
            Button { navigate(-1) } label: { Image(systemName: "arrow.left") }.disabled(!navigation.canGoBack)
                .help("Navigate back").accessibilityLabel("Navigate back").accessibilityIdentifier("code-back")
            Button { navigate(1) } label: { Image(systemName: "arrow.right") }.disabled(!navigation.canGoForward)
                .help("Navigate forward").accessibilityLabel("Navigate forward").accessibilityIdentifier("code-forward")
            Divider().frame(height: 16)
            Button { quickOpen = true } label: { Label("Quick open", systemImage: "doc.text.magnifyingglass") }
                .keyboardShortcut("p", modifiers: .command).disabled(tree == nil || loading).accessibilityIdentifier("code-quick-open")
            Text("⌘P").font(.caption.monospaced()).foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            RepositoryExternalEditorMenu(editors: editors, fileAvailable: selected?.isFile == true && treeURL == store.url,
                open: openExternal, refresh: { editors = ExternalEditors.editors() }).disabled(store.url == nil)
            Menu {
                ForEach(navigation.recent, id: \.self) { path in
                    Button(path) { if let entry = tree?.entries.first(where: { $0.path == path }) { requestOpen(entry) } }
                }
            } label: { Image(systemName: "clock.arrow.circlepath") }
                .menuStyle(.borderlessButton).fixedSize().disabled(navigation.recent.isEmpty)
                .help("Recent files").accessibilityLabel("Recent files").accessibilityIdentifier("code-recent")
        }.buttonStyle(.borderless).font(.callout).padding(.horizontal, 18).padding(.bottom, 12)
    }

    private var fileTabs: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 3) {
                    ForEach(navigation.tabs, id: \.self) { path in
                        HStack(spacing: 8) {
                            Button {
                                if let entry = tree?.entries.first(where: { $0.path == path }) { requestOpen(entry, view: navigation.tabModes[path] ?? "Source") }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text((path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                                    if navigation.tabs.filter({ ($0 as NSString).lastPathComponent == (path as NSString).lastPathComponent }).count > 1 {
                                        Text((path as NSString).deletingLastPathComponent.isEmpty ? String(localized: "Repository") : (path as NSString).deletingLastPathComponent).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    }
                                }.frame(minWidth: 60, maxWidth: 180, alignment: .leading)
                            }.accessibilityIdentifier("code-tab-" + path)
                            Button { closeTab(path) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .medium)) }
                                .help("Close file").accessibilityLabel("Close file").accessibilityIdentifier("code-close-" + path)
                        }.font(.callout).padding(.horizontal, 11).padding(.vertical, 10)
                            .background(selected?.path == path ? Color(nsColor: .textBackgroundColor) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(alignment: .bottom) { if selected?.path == path { Color.accentColor.frame(height: 2) } }
                            .id(path).help(path).accessibilityAddTraits(selected?.path == path ? .isSelected : [])
                    }
                    }.padding(5)
                }.scrollIndicators(.hidden).accessibilityLabel("Open files")
                    .onChange(of: selected?.path) { _, path in if let path { proxy.scrollTo(path, anchor: .center) } }
            }
            Button(action: closeAllFiles) { Image(systemName: "xmark.square") }.padding(10)
                .help("Close all files").accessibilityLabel("Close all files").accessibilityIdentifier("code-close-all")
        }.buttonStyle(.plain).frame(height: Set(navigation.tabs.map { ($0 as NSString).lastPathComponent }).count == navigation.tabs.count ? 42 : 55)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
    }

    private var explorer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Files").font(.callout.weight(.semibold))
                Spacer()
                if let tree { Text(tree.entries.count.formatted()).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }.padding(.horizontal, 13).padding(.top, 13).padding(.bottom, 10)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search files", text: $query).textFieldStyle(.plain)
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Clear search").accessibilityLabel("Clear search") }
            }.font(.callout).padding(8).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(nsColor: .separatorColor).opacity(0.5)))
                .padding(.horizontal, 10).padding(.bottom, 10)
            HStack(spacing: 6) {
                Button("Repository") { directory = ""; query = "" }.buttonStyle(.plain).foregroundStyle(.secondary)
                if !directory.isEmpty {
                    Image(systemName: "chevron.right").font(.system(size: 8))
                    Text(directory).lineLimit(1).truncationMode(.middle).help(directory)
                    Spacer(minLength: 0)
                    Button { directory = parentDirectory } label: { Image(systemName: "arrow.up") }.buttonStyle(.plain).help("Parent folder").accessibilityLabel("Parent folder")
                }
            }.font(.caption).padding(.horizontal, 13).padding(.bottom, 11)
            RepositoryLanguageControl(segments: languages, truncated: tree?.truncated == true, selected: $languageFilter)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !directory.isEmpty && query.isEmpty && languageFilter == nil {
                        Button { directory = parentDirectory } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "chevron.right").font(.system(size: 9)).hidden()
                                Image(systemName: "folder").foregroundStyle(Color.accentColor.opacity(0.8))
                                Text(verbatim: "..")
                                Spacer(minLength: 0)
                            }.font(.callout).padding(.horizontal, 9).padding(.vertical, 8).contentShape(Rectangle())
                        }.buttonStyle(.plain).help("Parent folder").accessibilityLabel("Parent folder").accessibilityIdentifier("code-parent-folder")
                    }
                    ForEach(folders, id: \.self) { folder in
                        Button { directory = folder } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                                Image(systemName: "folder.fill").foregroundStyle(Color.accentColor.opacity(0.8))
                                Text(String(folder.dropFirst(prefix.count))).lineLimit(1)
                                Spacer(minLength: 0)
                            }.font(.callout).padding(.horizontal, 9).padding(.vertical, 8).contentShape(Rectangle())
                        }.buttonStyle(.plain).help(folder)
                    }
                    ForEach(Array(matching.prefix(2000))) { entry in
                        Button { requestOpen(entry) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: entry.isSubmodule ? "shippingbox" : entry.isSymlink ? "link" : "doc.text").foregroundStyle(.secondary)
                                Text(query.isEmpty && languageFilter == nil ? String(entry.path.dropFirst(prefix.count)) : entry.path).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                            }.font(.callout).padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                                .background(selected?.path == entry.path ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .overlay(alignment: .leading) { if selected?.path == entry.path { RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(width: 3).padding(.vertical, 6) } }
                        }.buttonStyle(.plain).help(entry.path).accessibilityAddTraits(selected?.path == entry.path ? .isSelected : [])
                    }
                    if matching.count > 2000 { Text("Showing the first 2,000 matches. Search to narrow the file list.").font(.caption).foregroundStyle(.secondary).padding(10) }
                    if tree != nil && matching.isEmpty && folders.isEmpty { ContentUnavailableView("No matching files", systemImage: "doc.text.magnifyingglass") }
                }.padding(6)
            }
            if tree?.truncated == true { Text("File list truncated. Narrow the repository or use another tool for the remaining files.").font(.caption).foregroundStyle(.orange).padding(10) }
        }.background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
    }

    @ViewBuilder private var content: some View {
        if let selected {
            VStack(alignment: .leading, spacing: 0) {
                fileTabs
                Divider()
                HStack(spacing: 10) {
                    Image(systemName: "doc.text").foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text((selected.path as NSString).lastPathComponent).font(.callout.weight(.semibold))
                        Text(selected.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }.help(selected.path)
                    Spacer(minLength: 0)
                    Text(LocalizedStringKey(RepositoryLanguages.language(for: selected.path))).font(.caption.weight(.medium))
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(RepositoryLanguageSummary.color(RepositoryLanguages.language(for: selected.path)).opacity(0.13), in: RoundedRectangle(cornerRadius: 5))
                        .accessibilityLabel(String(localized: "Language") + ": " + Bundle.main.localizedString(forKey: RepositoryLanguages.language(for: selected.path), value: nil, table: nil))
                        .accessibilityIdentifier("code-file-language")
                    Text(ByteCountFormatter.string(fromByteCount: Int64(selected.size), countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                }.padding(14)
                WorkbenchFlow(spacing: 4) {
                    ForEach(modes, id: \.self) { value in
                        Button { requestOpen(selected, view: value) } label: {
                            Text(LocalizedStringKey(value)).font(.callout.weight(mode == value ? .semibold : .regular))
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .foregroundStyle(mode == value ? Color.accentColor : .secondary)
                                .background(mode == value ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain).disabled(!selected.isFile && value != "Source").help(LocalizedStringKey(value))
                    }
                }.padding(.horizontal, 10).padding(.bottom, 10)
                Divider()
                if let notice = preview?.notice { Label(notice, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary).padding(12) }
                if fileLoading {
                    VStack { Spacer(); ProgressView("Loading…").controlSize(.small); Spacer() }.frame(maxWidth: .infinity)
                } else if mode == "Preview", let text = preview?.text {
                    if ["html", "htm"].contains((selected.path as NSString).pathExtension.lowercased()), let tree, let repository = treeURL {
                        RepositoryHTMLPreview(text: text, entry: selected, tree: tree, repository: repository)
                    } else { ScrollView { MarkdownView(text).padding(24) }.frame(maxWidth: .infinity, maxHeight: .infinity) }
                } else if mode == "Source", let data = preview?.image, let image = NSImage(data: data) {
                    ScrollView([.horizontal, .vertical]) { Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 1200).padding(24) }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let text = mode == "Source" ? preview?.text : auxiliary {
                    if mode != "Source" && text.isEmpty { ContentUnavailableView("No content to show.", systemImage: "doc.text") }
                    else { RepositoryCodeReader(text: text, path: selected.path, syntax: mode == "Source", fontSize: $fontSize, wraps: $wraps, findText: $findText, matchIndex: $matchIndex) }
                } else {
                    ContentUnavailableView("No content to show.", systemImage: "doc.text")
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("Choose a file", systemImage: "doc.text.magnifyingglass", description: Text("Search paths or choose a file from the repository tree."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func loadTree() async {
        guard let url = store.url else { return }
        let token = UUID(); treeRequest = token; fileRequest = UUID(); loading = true; fileLoading = false; error = nil; tree = nil; treeURL = nil; directory = ""; selected = nil; preview = nil; auxiliary = nil; navigation = RepositoryCodeNavigation(); quickOpen = false; languages = []; languageFilter = nil
        do {
            let value = try await RepositoryBrowser.tree(in: url, ref: revisionInput)
            guard !Task.isCancelled, store.url == url, treeRequest == token else { return }
            tree = value
            treeURL = url
            let summary = await Task.detached(priority: .userInitiated) { RepositoryLanguages.composition(value.entries) }.value
            guard !Task.isCancelled, store.url == url, treeRequest == token else { return }
            languages = summary
            if let entry = RepositoryBrowser.initialFile(value.entries) { directory = entry.path.split(separator: "/").dropLast().joined(separator: "/"); await open(entry) }
        } catch { if !Task.isCancelled && store.url == url && treeRequest == token { self.error = store.describe(error) } }
        if store.url == url && treeRequest == token { loading = false }
    }

    private func open(_ entry: RepositoryTreeEntry, view: String = "Source", record: Bool = true) async {
        guard let url = store.url, treeURL == url, let tree, tree.entries.first(where: { $0.path == entry.path }) == entry else { return }
        let token = UUID(), snapshot = tree.revision; fileRequest = token; selected = entry; mode = view; preview = nil; auxiliary = nil; error = nil; fileLoading = true; matchIndex = 0
        directory = entry.path.split(separator: "/").dropLast().joined(separator: "/")
        navigation.visit(entry.path, mode: view, record: record)
        func current() -> Bool { !Task.isCancelled && store.url == url && self.tree?.revision == snapshot && fileRequest == token }
        defer { if current() { fileLoading = false } }
        do {
            if view == "Source" || view == "Preview" {
                let value = try await RepositoryBrowser.blob(in: url, entry: entry)
                if current() { preview = value }
            } else {
                var args: [String]
                if view == "File history" { args = ["log", "--follow", "-n", "100", "--date=short", "--format=%h %ad %an%n%s%n", snapshot, "--", entry.path] }
                else if view == "Working changes" { args = ["diff", "--no-ext-diff", "--no-textconv", "HEAD", "--", entry.path] }
                else {
                    let value = try await RepositoryBrowser.blob(in: url, entry: entry)
                    guard let text = value.text, !text.isEmpty else { if current() { auxiliary = value.notice ?? String(localized: "No content to show.") }; return }
                    let lines = max(1, min(5000, RepositoryCodeReading.lineStarts(in: text).count))
                    args = ["blame", "--date=short", "-L", "1,\(lines)", snapshot, "--", entry.path]
                }
                guard current() else { return }
                let value = try await Git.run(args, in: url).output
                if current() { auxiliary = String(value.prefix(2_000_000)) }
            }
        } catch { if current() { self.error = store.describe(error) } }
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
        fileRequest = UUID(); selected = nil; preview = nil; auxiliary = nil; fileLoading = false; error = nil
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
