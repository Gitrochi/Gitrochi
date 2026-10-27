import SwiftUI
import AppKit

struct RepositoryCodePanel: View {
    @Environment(RepoStore.self) private var store
    @ViewState private var revisionInput = "HEAD"
    @ViewState private var query = ""
    @ViewState private var directory = ""
    @ViewState private var tree: RepositoryTreeSnapshot?
    @ViewState private var selected: RepositoryTreeEntry?
    @ViewState private var preview: RepositoryBlobPreview?
    @ViewState private var mode = "Source"
    @ViewState private var auxiliary = ""
    @ViewState private var loading = false
    @ViewState private var error: String?
    @ViewState private var treeRequest = UUID()
    @ViewState private var fileRequest = UUID()
    private let modes = ["Source", "File history", "Blame", "Working changes"]
    private var prefix: String { directory.isEmpty ? "" : directory + "/" }
    private var matching: [RepositoryTreeEntry] { tree?.entries.filter { entry in query.isEmpty ? entry.path.hasPrefix(prefix) && !entry.path.dropFirst(prefix.count).contains("/") : entry.path.localizedCaseInsensitiveContains(query) } ?? [] }
    private var folders: [String] { guard query.isEmpty else { return [] }; return Array(Set((tree?.entries ?? []).filter { $0.path.hasPrefix(prefix) && $0.path.dropFirst(prefix.count).contains("/") }.map { prefix + String($0.path.dropFirst(prefix.count).split(separator: "/")[0]) })).sorted() }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("Revision", text: $revisionInput).textFieldStyle(.roundedBorder).onSubmit { Task { await loadTree() } }
                    Menu("Choose a branch or tag") {
                        ForEach(store.localBranches) { branch in Button(branch.name) { revisionInput = branch.name; Task { await loadTree() } } }
                        ForEach(store.remoteBranches) { branch in Button(branch.name) { revisionInput = branch.name; Task { await loadTree() } } }
                        ForEach(store.tags) { tag in Button(tag.name) { revisionInput = tag.name; Task { await loadTree() } } }
                    }.fixedSize()
                    Button("Load revision") { Task { await loadTree() } }.disabled(loading)
                }
                TextField("Search files", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 430)
            }
            if loading { ProgressView().controlSize(.small) }
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            if let tree {
                HStack { Text(String(tree.revision.prefix(12))).font(.caption.monospaced()); Text(verbatim: String(localized: "{0} files · {1} folders").replacingOccurrences(of: "{0}", with: tree.entries.count.formatted()).replacingOccurrences(of: "{1}", with: RepositoryBrowser.folderCount(tree.entries).formatted())).font(.caption); if tree.truncated { Text("File list truncated. Narrow the repository or use another tool for the remaining files.").font(.caption).foregroundStyle(.orange) } }.foregroundStyle(.secondary)
            }
            AdaptiveWorkbenchSplit(listWidth: 250) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 4) { Button("Repository") { directory = "" }; if !directory.isEmpty { Text("/ " + directory).lineLimit(1).truncationMode(.middle); Button { directory = directory.split(separator: "/").dropLast().joined(separator: "/") } label: { Image(systemName: "arrow.up") }.help("Parent folder") } }.font(.caption).padding(9)
                        ForEach(folders, id: \.self) { folder in Button { directory = folder } label: { HStack { Image(systemName: "folder"); Text(String(folder.dropFirst(prefix.count))).lineLimit(1); Spacer() }.font(.callout).padding(9).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain) }
                        ForEach(Array(matching.prefix(2000))) { entry in
                            Button { Task { await open(entry) } } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: entry.isSubmodule ? "shippingbox" : entry.isSymlink ? "link" : "doc.text").foregroundStyle(.secondary)
                                    Text(query.isEmpty ? String(entry.path.dropFirst(prefix.count)) : entry.path).font(.callout).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 0)
                                }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(selected?.path == entry.path ? Color.accentColor.opacity(0.15) : Color.clear)
                            }.buttonStyle(.plain).help(entry.path)
                        }
                        if matching.count > 2000 { Text("Showing the first 2,000 matches. Search to narrow the file list.").font(.caption).foregroundStyle(.secondary).padding(10) }
                        if tree != nil && matching.isEmpty && folders.isEmpty { ContentUnavailableView("No matching files", systemImage: "doc.text.magnifyingglass") }
                    }
                }
            } detail: {
                content
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary.opacity(0.15))
        }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .task(id: store.url) { revisionInput = "HEAD"; query = ""; await loadTree() }
            .onDisappear { treeRequest = UUID(); fileRequest = UUID() }
    }
    @ViewBuilder private var content: some View {
        if let selected {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text(selected.path).fontWeight(.medium).lineLimit(1).truncationMode(.middle).help(selected.path); Spacer(); Text("\(selected.size) B").font(.caption).foregroundStyle(.secondary) }.padding(.horizontal, 12).padding(.top, 12)
                WorkbenchFlow(spacing: 7) {
                    ForEach(modes, id: \.self) { value in
                        Button { Task { await open(selected, view: value) } } label: { Text(LocalizedStringKey(value)).foregroundStyle(mode == value ? Color.accentColor : Color.primary) }.disabled(!selected.isFile && value != "Source")
                    }
                }.padding(.horizontal, 12)
                if let notice = preview?.notice { Text(notice).font(.callout).foregroundStyle(.secondary).padding(.horizontal, 12) }
                if mode == "Source", let data = preview?.image, let image = NSImage(data: data) {
                    ScrollView([.horizontal, .vertical]) { Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 1200).padding(20) }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        Text(mode == "Source" ? preview?.text ?? (preview?.notice != nil ? "" : String(localized: "Loading…")) : (auxiliary.isEmpty ? String(localized: "No content to show.") : auxiliary))
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(12)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else { ContentUnavailableView("Choose a file", systemImage: "doc.text", description: Text("Search paths or choose a file from the repository tree.")) }
    }
    private func loadTree() async {
        guard let url = store.url else { return }
        let token = UUID(); treeRequest = token; fileRequest = UUID(); loading = true; error = nil; tree = nil; directory = ""; selected = nil; preview = nil; auxiliary = ""
        do {
            let value = try await RepositoryBrowser.tree(in: url, ref: revisionInput)
            guard !Task.isCancelled, store.url == url, treeRequest == token else { return }
            tree = value
            if let entry = RepositoryBrowser.initialFile(value.entries) { directory = entry.path.split(separator: "/").dropLast().joined(separator: "/"); await open(entry) }
        } catch { if !Task.isCancelled && store.url == url && treeRequest == token { self.error = store.describe(error) } }
        if store.url == url && treeRequest == token { loading = false }
    }
    private func open(_ entry: RepositoryTreeEntry, view: String = "Source") async {
        guard let url = store.url, let tree else { return }
        let token = UUID(), snapshot = tree.revision; fileRequest = token; selected = entry; mode = view; preview = nil; auxiliary = ""; error = nil
        func current() -> Bool { !Task.isCancelled && store.url == url && self.tree?.revision == snapshot && fileRequest == token }
        do {
            if view == "Source" {
                let value = try await RepositoryBrowser.blob(in: url, entry: entry)
                if current() { preview = value }
            } else {
                var args: [String]
                if view == "File history" { args = ["log", "--follow", "-n", "100", "--date=short", "--format=%h %ad %an%n%s%n", snapshot, "--", entry.path] }
                else if view == "Working changes" { args = ["diff", "--no-ext-diff", "--no-textconv", "HEAD", "--", entry.path] }
                else {
                    let value = try await RepositoryBrowser.blob(in: url, entry: entry)
                    guard let text = value.text, !text.isEmpty else { if current() { auxiliary = value.notice ?? String(localized: "No content to show.") }; return }
                    let lines = max(1, min(5000, text.split(separator: "\n", omittingEmptySubsequences: false).count - (text.hasSuffix("\n") ? 1 : 0)))
                    args = ["blame", "--date=short", "-L", "1,\(lines)", snapshot, "--", entry.path]
                }
                guard current() else { return }
                let value = try await Git.run(args, in: url).output
                if current() { auxiliary = String(value.prefix(2_000_000)) }
            }
        } catch { if current() { self.error = store.describe(error) } }
    }
}
