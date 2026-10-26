import SwiftUI
import AppKit

/// The Compare page: revision pickers and a branch list on the left, the changed files and patch on the right
struct RevisionComparisonPanel: View {
    @Environment(RepoStore.self) private var store
    @ViewState private var filter = ""

    var body: some View {
        @Bindable var state = store.historyTools
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Compare revisions").font(.title3.weight(.semibold))
                RevisionPicker(title: String(localized: "From revision"), revision: $state.left, store: store)
                HStack {
                    Spacer()
                    Button { let old = state.left; state.left = state.right; state.right = old } label: { Image(systemName: "arrow.up.arrow.down") }
                        .buttonStyle(.borderless).help("Swap revisions")
                    Spacer()
                }
                RevisionPicker(title: String(localized: "To revision"), revision: $state.right, store: store)
                Toggle("Compare from the common ancestor (changes introduced by the right side)", isOn: $state.useMergeBase).font(.caption)
                Button { Task { await store.loadRevisionComparison() } } label: { Text("Compare").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.comparisonLoading || state.left.isEmpty || state.right.isEmpty)
                Text("Uncommitted changes are excluded. Compare fixes both revisions to immutable commits.").font(.caption).foregroundStyle(.secondary)
                Divider().padding(.vertical, 4)
                Text("Compare with the current branch").font(.subheadline.weight(.semibold))
                TextField("Filter branches and tags", text: $filter).textFieldStyle(.roundedBorder)
                List {
                    ForEach(references) { reference in
                        referenceRow(reference, state: state)
                            .listRowBackground(state.right == reference.name ? Color.accentColor.opacity(0.12) : Color.clear)
                    }
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
                .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(16).frame(width: 330)
            Divider()
            results(state)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onDisappear { store.cancelHistoryTools() }
    }

    private struct Reference: Identifiable {
        let name: String
        let icon: String
        let isCurrent: Bool
        var id: String { icon + name }
    }

    /// Local branches with the current one first, then remote branches and tags; filtered by the search field
    private var references: [Reference] {
        let locals = store.localBranches.sorted { a, b in a.isCurrent != b.isCurrent ? a.isCurrent : a.name.localizedStandardCompare(b.name) == .orderedAscending }
        let all = locals.map { Reference(name: $0.name, icon: "arrow.triangle.branch", isCurrent: $0.isCurrent) }
            + store.remoteBranches.map { Reference(name: $0.name, icon: "cloud", isCurrent: false) }
            + store.tags.map { Reference(name: $0.name, icon: "tag", isCurrent: false) }
        return filter.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    private func referenceRow(_ reference: Reference, state: HistoryToolsState) -> some View {
        HStack(spacing: 8) {
            Image(systemName: reference.icon).foregroundStyle(.secondary).frame(width: 16)
            Text(reference.name).lineLimit(1).truncationMode(.middle).help(reference.name)
            Spacer(minLength: 4)
            if reference.isCurrent {
                Text("Current").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Compare") {
                    state.left = store.headBranch ?? "HEAD"
                    state.right = reference.name
                    Task { await store.loadRevisionComparison() }
                }
                .controlSize(.small).disabled(state.comparisonLoading)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func results(_ state: HistoryToolsState) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if state.comparisonLoading {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Comparing…").font(.caption).foregroundStyle(.secondary) }.padding(12)
            }
            if let error = state.comparisonError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).padding(12)
            }
            if let result = state.comparison {
                HStack {
                    Text(summary(result)).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text("\(result.files.count) files").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                Divider()
                AdaptiveWorkbenchSplit(listWidth: 270) {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(result.files) { file in
                                Button { Task { await store.selectComparisonFile(file) } } label: {
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(file.path).font(.callout).lineLimit(2)
                                            if let old = file.oldPath { Text(old + " → " + file.path).font(.caption).foregroundStyle(.secondary) }
                                        }
                                        Spacer(minLength: 4)
                                        if let stat = result.stats[file.path] { LineStatText(added: stat.added ?? 0, deleted: stat.deleted ?? 0).font(.caption) }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(9)
                                    .background(state.comparisonPath == file.path ? Color.accentColor.opacity(0.15) : Color.clear)
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                } detail: {
                    HistoryPatchView(text: result.files.isEmpty ? String(localized: "No differences between these revisions.") : state.comparisonPatch)
                }
            } else if !state.comparisonLoading {
                ContentUnavailableView("Choose two revisions to compare", systemImage: "arrow.left.arrow.right",
                                       description: Text("Use branches, tags or commit IDs, or pick a branch on the left."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func summary(_ result: RevisionComparison) -> String {
        var text = String(result.left.prefix(12)) + " → " + String(result.right.prefix(12))
        if result.mergeBase { text += " · " + String(localized: "Common ancestor") + ": " + String(result.base.prefix(12)) }
        return text
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
