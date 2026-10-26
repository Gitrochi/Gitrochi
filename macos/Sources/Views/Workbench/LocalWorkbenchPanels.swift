import SwiftUI
import AppKit

struct RevisionComparisonPanel: View {
    @Environment(RepoStore.self) private var store
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkbenchHeading(title: "Compare revisions", detail: "Inspect the complete change between branches, tags or commits.")
            CompareRevisionsSheet(store: store, embedded: true)
        }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct LocalBranchesPanel: View {
    @Environment(RepoStore.self) private var store
    @ViewState private var tab = "Local"
    @ViewState private var query = ""
    @ViewState private var selected: Branch?
    @ViewState private var rename = ""
    @ViewState private var error: String?
    @ViewState private var activity: [String: String] = [:]
    @ViewState private var merged = Set<String>()
    @ViewState private var comparing = false
    private let tabs = ["Local", "Remote", "Tags", "Stashes"]
    private var branches: [Branch] { (tab == "Local" ? store.localBranches : store.remoteBranches).filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }.sorted { a, b in let ap = store.isPinned(a), bp = store.isPinned(b); return ap != bp ? ap : a.name.localizedStandardCompare(b.name) == .orderedAscending } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            WorkbenchHeading(title: "Branches", detail: "Manage local and remote branches, tags and stashes in one place.")
            WorkbenchFlow {
                if tab == "Tags", let sha = store.headHash { Button("New tag") { store.sheet = .tag(sha: sha) }.disabled(store.busy != nil) }
                if tab == "Stashes" { Button("Stash changes…") { store.sheet = .stash }.disabled(store.busy != nil) }
                Button("New branch") { store.requestNewBranch() }.disabled(store.busy != nil)
                Button { Task { await store.reload() } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
            }
            VStack(alignment: .leading, spacing: 10) {
                Picker("Reference type", selection: $tab) { ForEach(tabs, id: \.self) { Text(LocalizedStringKey($0)).tag($0) } }.pickerStyle(.segmented).frame(maxWidth: 430)
                TextField("Search branches, tags and stashes", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 430)
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 9) {
                    if tab == "Local" || tab == "Remote" {
                        if branches.isEmpty { ContentUnavailableView("No matching branches", systemImage: "arrow.triangle.branch") }
                        ForEach(branches) { branch in branchRow(branch) }
                    } else if tab == "Tags" {
                        ForEach(store.tags.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { tag in
                            WorkbenchFlow {
                                Image(systemName: "tag"); Text(tag.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle).help(tag.name); Text(String(tag.target.prefix(12))).font(.caption.monospaced()).foregroundStyle(.secondary)
                                Button("Check out detached") { Task { await store.checkoutDetached(tag.target) } }
                                Button("New branch") { store.requestNewBranch(from: tag.target, label: tag.name) }
                                Button("Push…") { Task { await store.pushTag(tag) } }
                                Button("Delete…") { store.deleteTag(tag) }
                            }.padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9)).disabled(store.busy != nil)
                        }
                    } else {
                        ForEach(store.stashes.filter { query.isEmpty || ($0.ref + $0.message).localizedCaseInsensitiveContains(query) }) { stash in
                            VStack(alignment: .leading, spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) { Text(stash.ref).fontWeight(.medium); Text(stash.message).font(.caption).foregroundStyle(.secondary) }
                                WorkbenchFlow {
                                Button("Apply") { Task { await store.stashApply(stash) } }
                                Button("Pop") { Task { await store.stashPop(stash) } }
                                Button("Discard…") { store.stashDrop(stash) }
                                }
                            }.padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9)).disabled(store.busy != nil)
                        }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let selected, !selected.isRemote {
                HStack { Text("Rename branch"); TextField("New branch name", text: $rename).textFieldStyle(.roundedBorder); Button("Rename") { Task { await renameBranch(selected) } }.disabled(rename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || rename == selected.name || store.busy != nil) }.padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }
            if comparing {
                HStack { Text("Compare revisions").fontWeight(.semibold); Spacer(); Button("Close") { comparing = false } }
                CompareRevisionsSheet(store: store, embedded: true).frame(minHeight: 300)
            }
        }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .task(id: (store.url?.path ?? "") + (store.headHash ?? "") + (store.localBranches + store.remoteBranches).map { $0.name + $0.target }.joined()) { await loadActivity() }
            .onChange(of: store.url) { _, _ in selected = nil; comparing = false; activity = [:]; merged = [] }
    }
    private func branchRow(_ branch: Branch) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { selected = branch; rename = branch.name } label: {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.branch").font(.title3).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 4) {
                        WorkbenchFlow(spacing: 6) { Text(branch.name).fontWeight(.semibold).lineLimit(1).truncationMode(.middle).help(branch.name); if branch.isCurrent { Text("Current").font(.caption).foregroundStyle(Color.accentColor) }; if store.isPinned(branch) { Label("Pinned", systemImage: "pin.fill").font(.caption).foregroundStyle(.secondary) }; if store.isHidden(branch) { Image(systemName: "eye.slash").foregroundStyle(.secondary).help("Show in graph again") } }
                        Text(activity[branch.name] ?? String(branch.target.prefix(12))).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text(branch.upstream ?? String(localized: "No upstream")).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        if branch.upstreamGone { Text("Upstream removed").font(.caption).foregroundStyle(.orange) }
                    }
                    Spacer()
                    if branch.ahead > 0 { Text("↑\(branch.ahead)").font(.caption.monospaced()) }
                    if branch.behind > 0 { Text("↓\(branch.behind)").font(.caption.monospaced()) }
                    if merged.contains(branch.name) && !branch.isCurrent { Text("Merged into HEAD").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing).frame(maxWidth: 120) }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            branchActions(branch)
        }.padding(12).background(selected?.name == branch.name ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected?.name == branch.name ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.15)))
    }
    private func branchActions(_ branch: Branch) -> some View {
        WorkbenchFlow {
            if !branch.isRemote { Button { store.setPinned(branch, !store.isPinned(branch)) } label: { Label(store.isPinned(branch) ? String(localized: "Unpin") : String(localized: "Pin to top"), systemImage: "pin") } }
            Button(store.isHidden(branch) ? "Show in graph again" : "Hide from graph") { Task { await store.setHidden(branch, !store.isHidden(branch)) } }.disabled(store.busy != nil)
            Button("Check out") { Task { await store.checkout(branch) } }.disabled(branch.isCurrent || store.busy != nil)
            Button("View commits") { store.selectedBranchID = branch.id; store.navigate(.repository, prepare: false); store.reveal(branch.target) }
            Button("Compare") { store.historyTools.left = store.headBranch ?? "HEAD"; store.historyTools.right = branch.name; comparing = true; Task { await store.loadRevisionComparison() } }
            Button("Merge into current") { Task { await store.merge(branch.name) } }.disabled(branch.isCurrent || store.busy != nil || store.headBranch == nil)
            Button("Rebase current onto") { Task { await store.rebase(onto: branch.name) } }.disabled(branch.isCurrent || store.busy != nil || store.headBranch == nil)
            if !branch.isRemote { Button("Push…") { Task { await store.pushBranch(branch) } }.disabled(store.busy != nil) }
            Button("Delete…") { store.confirmDelete(branch) }.disabled(branch.isCurrent || store.busy != nil)
        }
    }
    private func loadActivity() async {
        guard let url = store.url, let head = store.headHash else { return }
        do {
            async let activityResult = Git.run(["for-each-ref", "--format=%(refname:short)%09%(committerdate:short)%09%(subject)", "refs/heads", "refs/remotes"], in: url)
            async let mergedResult = Git.run(["for-each-ref", "--merged=\(head)", "--format=%(refname:short)", "refs/heads", "refs/remotes"], in: url)
            let (a, m) = try await (activityResult, mergedResult)
            guard !Task.isCancelled, store.url == url, store.headHash == head else { return }
            activity = Dictionary(a.output.split(separator: "\n").compactMap { line -> (String, String)? in
                let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                return parts.count == 3 ? (parts[0], parts[1] + " · " + parts[2]) : nil
            }, uniquingKeysWith: { _, new in new })
            merged = Set(m.output.split(separator: "\n").map(String.init))
        } catch { if !Task.isCancelled && store.url == url { self.error = store.describe(error) } }
    }
    private func renameBranch(_ branch: Branch) async {
        guard let url = store.url, !branch.isRemote else { return }
        let name = rename.trimmingCharacters(in: .whitespacesAndNewlines), head = store.headHash
        guard !name.isEmpty, !name.hasPrefix("-") else { return }
        do {
            try await Git.run(["check-ref-format", "--branch", name], in: url)
            let oid = try await Git.run(["rev-parse", "--verify", "refs/heads/" + branch.name], in: url).output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard store.url == url, store.headHash == head, oid == branch.target else { throw RepositoryBrowserError(message: String(localized: "The repository changed. Refresh before renaming.")) }
            if await store.run(String(localized: "Renaming branch…"), ["branch", "-m", branch.name, name]) { selected = nil; rename = "" }
        } catch { if store.url == url { self.error = store.describe(error) } }
    }
}

private struct WorkbenchHeading: View {
    let title: String
    let detail: String
    var body: some View { VStack(alignment: .leading, spacing: 6) { Text(LocalizedStringKey(title)).font(.title2.weight(.semibold)); Text(LocalizedStringKey(detail)).font(.callout).foregroundStyle(.secondary) } }
}
