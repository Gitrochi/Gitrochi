import SwiftUI

/// The Compare page, as the redesign's Compare board draws it: From and To in a 312pt list column above the branches
/// and tags to compare with the current branch, and beside it Files and Commits tabs, the files as a tree next to the
/// open file's diff. The page compares as soon as either side changes. The "Compare revisions…" dialog keeps its own
/// one-column layout. (Windows: widgets/local-workbench/ui/RevisionComparisonPanel.tsx)
struct RevisionComparisonPanel: View {
    private enum Side { case from, to }
    private enum Tab { case files, commits }

    @Environment(RepoStore.self) private var store
    @AppStorage(requestFileViewModeKey) private var mode = "tree"
    @ViewState private var tab = Tab.files
    @ViewState private var filter = ""
    @ViewState private var picking: Side?
    @ViewState private var typed = ""
    @ViewState private var selectedPath: String?
    @ViewState private var collapsed = Set<String>()
    @ViewState private var hovered: String?
    @ViewState private var wraps = false
    @ViewState private var lineCount: Int?
    @ViewState private var keys = FileKeys()

    var body: some View {
        let state = store.historyTools
        HStack(spacing: 0) {
            listColumn(state)
                .frame(width: 312)
                .frame(maxHeight: .infinity, alignment: .top)
                .clipped()
                .background(StudioStyle.canvas)
            Divider()
            results(state).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { applyDefaults() }
        .task(id: key) { await compare() }
        .onChange(of: tab == .files && !(state.comparison?.files.isEmpty ?? true), initial: true) { _, on in
            if on { keys.start { step($0 ? 1 : -1) } } else { keys.stop() }
        }
        .onChange(of: store.url) { _, _ in selectedPath = nil; collapsed = []; filter = "" }
        .onDisappear { store.cancelHistoryTools(); keys.stop() }
    }

    // MARK: Comparing

    /// Where every branch and tag points, so a side that moves compares again
    private var targets: [String: String] {
        Dictionary((store.localBranches + store.remoteBranches).map { ($0.name, $0.target) } + store.tags.map { ($0.name, $0.target) },
                   uniquingKeysWith: { first, _ in first })
    }

    /// A dialog over the page owns the shared inputs while it is open; the page compares once it closes
    private var key: String {
        let state = store.historyTools
        return HistoryTools.comparisonKey(repository: store.url?.path ?? "", left: state.left, right: state.right, mergeBase: state.useMergeBase,
                                          head: store.headHash, targets: targets) + (store.sheet == nil ? "" : "\u{0}dialog")
    }

    /// On a first visit there is nothing to show yet: the usual base against the current branch, from where they split
    private func applyDefaults() {
        let state = store.historyTools
        guard state.comparison == nil, !state.comparisonLoading, state.left == "HEAD~1", state.right == "HEAD", let head = store.headBranch else { return }
        let names = store.localBranches.map(\.name) + store.remoteBranches.map(\.name)
        let base = RebasePreview.defaultBase(names: names, current: head, upstream: store.status.upstream)
        guard base != head, names.contains(base) else { return }
        state.left = base; state.right = head; state.useMergeBase = true
    }

    private func compare() async {
        let state = store.historyTools, current = key
        guard store.sheet == nil, store.url != nil, HistoryTools.validRevision(state.left), HistoryTools.validRevision(state.right),
              current != state.comparisonKey || (state.comparison == nil && state.comparisonError == nil && !state.comparisonLoading) else { return }
        // a swap or a quick second choice compares once
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
        state.comparisonKey = current
        await store.loadRevisionComparison(openFirst: false)
    }

    private func retry() {
        store.historyTools.comparisonKey = ""
        Task { await store.loadRevisionComparison(openFirst: false) }
    }

    // MARK: List column

    private func listColumn(_ state: HistoryToolsState) -> some View {
        @Bindable var state = state
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                VStack(spacing: 6) {
                    picker(.from, state)
                    picker(.to, state)
                }
                .frame(maxWidth: .infinity)
                Button { let left = state.left; state.left = state.right; state.right = left } label: { SymbolIcon("arrow.up.arrow.down").font(.system(size: 12)) }
                    .buttonStyle(PullRequestButtonStyle(iconOnly: true))
                    .help("Swap From and To").accessibilityLabel("Swap From and To")
            }
            Toggle("From the common ancestor", isOn: $state.useMergeBase).toggleStyle(.checkbox).font(.system(size: 13))
            caption(String(localized: "Updates as soon as either side changes. Uncommitted changes are excluded."))
            // the rule runs to the column's edges without widening the column
            Color.clear.frame(height: 1).overlay(StudioStyle.border.padding(.horizontal, -12)).padding(.vertical, 4)
            Text("Compare with the current branch").font(.system(size: 13, weight: .semibold))
            HStack(spacing: 6) {
                DesignIconImage(icon: .search, size: 12).foregroundStyle(StudioStyle.Rail.icon)
                TextField("Filter branches and tags", text: $filter).textFieldStyle(.plain).font(.system(size: 13))
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.surface))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.16)))
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(references.filter { HistoryTools.referenceMatches($0.name, filter: filter) }) { referenceRow($0, state) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityLabel("Compare with the current branch")
        }
        .padding(12)
    }

    private var references: [ComparisonReference] {
        HistoryTools.comparisonReferences(local: store.localBranches.map(\.name), remote: store.remoteBranches.map(\.name), tags: store.tags.map(\.name), current: store.headBranch)
    }

    /// From or To: the name chosen, and a popover where any revision can be typed or a branch or tag chosen
    private func picker(_ side: Side, _ state: HistoryToolsState) -> some View {
        let value = side == .from ? state.left : state.right
        let title = side == .from ? String(localized: "From") : String(localized: "To")
        let resolved = state.comparison.map { side == .from ? $0.left : $0.right }
        return Button { typed = ""; picking = side } label: {
            HStack(spacing: 8) {
                Text(verbatim: title).font(.system(size: 12)).foregroundStyle(StudioStyle.Rail.icon).frame(minWidth: 28, alignment: .leading).fixedSize()
                Text(verbatim: value).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                DesignIconImage(icon: .chevronDown, size: 9).foregroundStyle(StudioStyle.Rail.icon)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.surface))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.16)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // the commit the name stood for when it was compared
        .help(Text(verbatim: resolved.map { value + " · " + String($0.prefix(7)) } ?? value))
        .accessibilityLabel(Text(verbatim: title + ": " + value))
        .popover(isPresented: Binding(get: { picking == side }, set: { if !$0 && picking == side { picking = nil } }), arrowEdge: .bottom) {
            revisionList(side, current: value)
        }
    }

    /// Any revision can be typed; the branches and tags below narrow as it is typed
    private func revisionList(_ side: Side, current: String) -> some View {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = HistoryTools.comparisonReferences(local: store.localBranches.map(\.name), remote: store.remoteBranches.map(\.name), tags: store.tags.map(\.name), current: nil)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TextField("Branch, tag or commit", text: $typed).textFieldStyle(.roundedBorder)
                    .onSubmit { if HistoryTools.validRevision(text) { choose(side, text) } }
                Button("Apply") { choose(side, text) }.disabled(!HistoryTools.validRevision(text))
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(all.filter { HistoryTools.referenceMatches($0.name, filter: text) }) { reference in
                        RepositoryCodeRow(selected: reference.name == current, action: { choose(side, reference.name) }) {
                            HStack(spacing: 8) {
                                SymbolIcon(icon(reference)).font(.system(size: 12)).foregroundStyle(StudioStyle.Rail.icon).frame(width: 14)
                                Text(reference.name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
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

    private func choose(_ side: Side, _ value: String) {
        if side == .from { store.historyTools.left = value } else { store.historyTools.right = value }
        picking = nil
    }

    private func icon(_ reference: ComparisonReference) -> String {
        switch reference.kind {
        case .branch: return "arrow.triangle.branch"
        case .remote: return "cloud"
        case .tag: return "tag"
        }
    }

    /// A branch or tag compared with the current branch: it becomes From and the current branch To
    private func referenceRow(_ reference: ComparisonReference, _ state: HistoryToolsState) -> some View {
        let head = store.headBranch ?? "HEAD"
        let compared = state.left == reference.name && state.right == head, hover = hovered == reference.id
        return Button { state.left = reference.name; state.right = head } label: {
            HStack(spacing: 8) {
                SymbolIcon(icon(reference)).font(.system(size: 12)).foregroundStyle(StudioStyle.Rail.icon).frame(width: 14)
                Text(reference.name).lineLimit(1).truncationMode(.middle).fontWeight(compared ? .semibold : .regular)
                    .frame(maxWidth: .infinity, alignment: .leading).layoutPriority(-1)
                if hover && !compared {
                    Text("Compare").padding(.horizontal, 8).frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.surface))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.16)))
                        .accessibilityHidden(true)
                }
            }
            .font(.system(size: 13))
            .padding(.leading, 8).padding(.trailing, 4).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(compared ? StudioStyle.selection : hover ? StudioStyle.hover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? reference.id : (hovered == reference.id ? nil : hovered) }
        .accessibilityLabel(compared ? String(localized: "\(reference.name), compared now") : String(localized: "Compare \(reference.name) with the current branch"))
        .accessibilityAddTraits(compared ? .isSelected : [])
    }

    // MARK: Results

    @ViewBuilder private func results(_ state: HistoryToolsState) -> some View {
        VStack(spacing: 0) {
            tabBar(state)
            Divider()
            Group {
                if let error = state.comparisonError {
                    HostedListEmpty(symbol: "exclamationmark.triangle", title: String(localized: "Couldn't compare these revisions"), caption: error,
                                    actionTitle: String(localized: "Retry"), failed: true, action: retry)
                } else if let result = state.comparison {
                    if tab == .files { files(result) } else { commits(result) }
                } else if state.comparisonLoading {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HostedListEmpty(symbol: "arrow.left.arrow.right", title: String(localized: "Choose two revisions to compare"),
                                    caption: String(localized: "Use branches, tags or commit IDs, or pick a branch on the left."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Files and Commits own their counts; the common ancestor shows when the comparison starts there
    private func tabBar(_ state: HistoryToolsState) -> some View {
        let result = state.comparison
        return HStack(spacing: 12) {
            HStack(spacing: 4) {
                tabButton(.files, "Files", count: result.map { String($0.files.count) })
                tabButton(.commits, "Commits", count: result.map { HistoryTools.commitCountLabel($0.commits.count) })
            }
            Spacer(minLength: 0)
            if state.comparisonLoading && result != nil {
                ProgressView().controlSize(.mini).accessibilityLabel("Comparing…")
            }
            if let result, result.mergeBase {
                HStack(spacing: 4) {
                    Text("Common ancestor")
                    Text(verbatim: String(result.base.prefix(7))).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                }
                .font(.system(size: 12)).foregroundStyle(StudioStyle.Rail.icon)
            }
        }
        .padding(.horizontal, 16)
    }

    private func tabButton(_ value: Tab, _ title: LocalizedStringKey, count: String?) -> some View {
        Button { tab = value } label: {
            HStack(spacing: 6) {
                Text(title)
                if let count { StatusPill(title: count, symbol: nil, tone: .neutral) }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(tab == value ? AnyShapeStyle(.primary) : AnyShapeStyle(StudioStyle.Tone.neutral.text))
            .padding(.horizontal, 12).frame(height: 35)
            .overlay(alignment: .bottom) { if tab == value { StudioStyle.accent.frame(height: 2) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(tab == value ? .isSelected : [])
    }

    // MARK: Files

    /// The files in the order the list draws them, so "2 / 6", J and K follow what is on screen
    private func ordered(_ result: RevisionComparison) -> [FileChange] {
        guard mode == "tree" else { return result.files }
        return FileTree.rows(result.files, collapsed: []).compactMap { row in
            if case .file(let change) = row.kind { return change }
            return nil
        }
    }

    private func open(_ result: RevisionComparison) -> FileChange? {
        let files = ordered(result)
        return files.first { $0.path == selectedPath } ?? files.first
    }

    private func step(_ offset: Int) {
        guard let result = store.historyTools.comparison, let current = open(result) else { return }
        let files = ordered(result)
        guard let index = files.firstIndex(of: current), files.indices.contains(index + offset) else { return }
        selectedPath = files[index + offset].path
    }

    @ViewBuilder private func files(_ result: RevisionComparison) -> some View {
        if result.files.isEmpty {
            HostedListEmpty(symbol: "equal.circle", title: String(localized: "No differences between these revisions."))
        } else {
            AdaptiveWorkbenchSplit(threshold: 720, listWidth: 300) {
                tree(result)
            } detail: {
                if let file = open(result), let url = store.url {
                    let files = ordered(result), index = files.firstIndex(of: file) ?? 0
                    RepositoryCodeChangesView(repository: url, path: file.path, commit: result.right, base: result.base, oldPath: file.oldPath,
                                              position: CodeFilePosition(index: index, count: files.count, step: step),
                                              wraps: $wraps, lineCount: $lineCount)
                }
            }
        }
    }

    private func tree(_ result: RevisionComparison) -> some View {
        let current = open(result)?.path
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Changed files").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                FileViewToggle(key: requestFileViewModeKey, fallback: "tree")
            }
            .padding(.leading, 6)
            .frame(height: 28)
            // the rows scroll under the header, never over it; a row wider than the column cuts its name, not the column
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if mode == "tree" {
                        ForEach(FileTree.rows(result.files, collapsed: collapsed)) { row in
                            switch row.kind {
                            case .folder(let path, let name, let files): folderRow(path: path, name: name, count: files.count, depth: row.depth)
                            case .file(let change): fileRow(change, result, selected: change.path == current, indent: 6 + CGFloat(row.depth) * 14 + 18, folder: false)
                            }
                        }
                    } else {
                        ForEach(result.files) { fileRow($0, result, selected: $0.path == current, indent: 6, folder: true) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .clipped()
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Changed files")
    }

    private func folderRow(path: String, name: String, count: Int, depth: Int) -> some View {
        let open = !collapsed.contains(path), id = "d:" + path
        return Button { if open { collapsed.insert(path) } else { collapsed.remove(path) } } label: {
            HStack(spacing: 6) {
                SymbolIcon(open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(StudioStyle.Rail.icon).frame(width: 12)
                DesignIconImage(icon: .repository, size: 11).foregroundStyle(StudioStyle.Rail.icon)
                Text(verbatim: name).fontWeight(.medium).lineLimit(1).truncationMode(.head).layoutPriority(-1)
                // a folder holding a single file needs no count
                if count > 1 { StatusPill(title: String(count), symbol: nil, tone: .neutral) }
                Spacer(minLength: 0)
            }
            .font(.system(size: 13))
            .padding(.leading, 6 + CGFloat(depth) * 14).padding(.trailing, 6)
            .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovered == id ? StudioStyle.hover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? id : (hovered == id ? nil : hovered) }
    }

    private func fileRow(_ file: FileChange, _ result: RevisionComparison, selected: Bool, indent: CGFloat, folder: Bool) -> some View {
        let id = "f:" + file.path, stat = result.stats[file.path]
        return Button { selectedPath = file.path } label: {
            HStack(spacing: 6) {
                StatusBadge(kind: file.kind)
                // a rename's old name gives way first, then the folder, then the name; the counts are never cut
                if let old = file.oldPath, old != file.path {
                    Text(verbatim: (old as NSString).lastPathComponent + " →").font(.system(size: 11)).foregroundStyle(StudioStyle.Rail.icon).lineLimit(1).layoutPriority(-2)
                }
                Text(verbatim: file.fileName).fontWeight(selected ? .semibold : .regular).lineLimit(1).truncationMode(.middle)
                if folder { PullRequestFolderLabel(path: file.path, color: selected ? Color.primary.opacity(0.72) : StudioStyle.Rail.icon).layoutPriority(-3) }
                Spacer(minLength: 0)
                if let stat { LineStatText(added: stat.added ?? 0, deleted: stat.deleted ?? 0).fixedSize().layoutPriority(1) }
            }
            .font(.system(size: 13))
            .padding(.leading, indent).padding(.trailing, 8)
            .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? StudioStyle.selection : hovered == id ? StudioStyle.hover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? id : (hovered == id ? nil : hovered) }
        .help(Text(verbatim: file.oldPath.map { $0 + " → " + file.path } ?? file.path))
        .accessibilityLabel(Text(verbatim: file.path))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Commits

    @ViewBuilder private func commits(_ result: RevisionComparison) -> some View {
        if result.commits.isEmpty {
            HostedListEmpty(symbol: "equal.circle", title: String(localized: "No commits between these revisions."))
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(result.commits.prefix(HistoryTools.comparisonCommitLimit)) { commitRow($0) }
                }
                .padding(10)
            }
            .accessibilityLabel("Commits")
        }
    }

    private func commitRow(_ commit: ComparisonCommit) -> some View {
        let id = "c:" + commit.id
        return Button { store.reveal(commit.id) } label: {
            HStack(spacing: 10) {
                Text(verbatim: String(commit.id.prefix(7))).font(.system(size: 11, design: .monospaced)).foregroundStyle(StudioStyle.Rail.icon).frame(width: 56, alignment: .leading)
                Text(verbatim: commit.subject).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: commit.author).font(.system(size: 12)).foregroundStyle(StudioStyle.Rail.icon).lineLimit(1).fixedSize()
                if let date = commit.date { Text(verbatim: ListDate.when(date)).font(.system(size: 12)).foregroundStyle(StudioStyle.Rail.icon).fixedSize() }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovered == id ? StudioStyle.hover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? id : (hovered == id ? nil : hovered) }
        .help("Show commit")
    }

    private func caption(_ text: String) -> some View {
        Text(verbatim: text).font(.system(size: 12)).foregroundStyle(StudioStyle.Rail.icon).fixedSize(horizontal: false, vertical: true)
    }
}
