import SwiftUI

struct SidebarView: View {
    @Environment(RepoStore.self) private var store
    @ViewState private var expanded: Set<String> = []
    /// Set: only this section, as a flyout of the rail (the sidebar folded away)
    var flyout: String? = nil
    @ViewState private var flyoutHeight: CGFloat = 200

    @AppStorage("sidebarMode") private var mode = "list"
    @FocusState private var filterFocused: Bool

    var body: some View {
        if let flyout {
            ScrollView {
                // the flyout has no field, so it lists everything
                VStack(alignment: .leading, spacing: 0) { sections(only: flyout, query: "") }
                    .padding(.bottom, 8)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { flyoutHeight = $0 }
            }
            .frame(width: 280, height: min(max(flyoutHeight, 40), 520))
            .environment(\.sidebarFlyout, true)
            .onAppear(perform: expandCurrent)
        } else {
            list
        }
    }

    private var list: some View {
        @Bindable var store = store
        return VStack(spacing: 0) {
            // the board's 28 pt control; a saved "ci" mode from before the Actions page falls through to the branch list
            Segmented(label: "Repository tools", items: [
                .init(value: "list", title: String(localized: "Branches")),
                .init(value: "agents", title: activeAgents > 0 ? String(localized: "Agents \(activeAgents)") : String(localized: "Agents")),
            ], selection: mode == "agents" ? "agents" : "list", fill: true) { mode = $0 }
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 4)
            if mode == "agents" {
                AgentsPanel()
            } else {
                // 10 pt under the switch and, with the first section's own 6 pt, 10 pt over the first head
                SidebarFilterField(text: $store.branchFilter, focused: $filterFocused) { store.escapeInBranchFilter() }
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
                    .onChange(of: filterFocused) { _, focused in store.branchFilterFocused = focused }
                    .onDisappear { store.branchFilterFocused = false }
                branchList
            }
        }
        // 반투명 사이드바는 바탕화면 색이 비쳐 물들어 보인다 — 불투명한 중립 배경으로
        .scrollContentBackground(.hidden)
        .background(StudioStyle.sidebar.ignoresSafeArea())
    }

    /// 지금 일하거나 허락을 기다리는 세션 수
    private var activeAgents: Int {
        let paths = Set(store.worktrees.map { AgentCenter.normalize($0.path) })
        return AgentCenter.shared.sessions.filter { $0.status.isActive && paths.contains(AgentCenter.normalize($0.path)) }.count
    }

    private var branchList: some View {
        let query = BranchFilter.query(store.branchFilter)
        return Group {
            if !query.isEmpty, !matches(query) {
                // nothing matches: the empty form of docs/design.md, at the top of the list
                VStack(spacing: 0) {
                    HostedListEmpty(symbol: "magnifyingglass", title: String(localized: "No matching branches"),
                                    caption: String(localized: "No branch or tag name contains “\(store.branchFilter.trimmingCharacters(in: .whitespacesAndNewlines))”."),
                                    actionTitle: String(localized: "Clear filter")) { store.branchFilter = "" }
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            } else {
                SharedStack {
                    // with each section's own 6 pt on top, a head stands 12 pt under the rows before it
                    VStack(alignment: .leading, spacing: 6) { sections(only: nil, query: query) }
                        .padding(.horizontal, 4)
                        .padding(.bottom, 8)
                }
            }
        }
        // on the group, so coming back from the empty form does not reopen a folder the user folded
        .onAppear(perform: expandCurrent)
        .onChange(of: store.headBranch) { _, _ in expandCurrent() }
    }

    /// Whether any branch or tag name contains the query
    private func matches(_ query: String) -> Bool {
        (store.localBranches + store.remoteBranches).contains { BranchFilter.matches($0.name, query) }
            || store.tags.contains { BranchFilter.matches($0.name, query) }
    }

    /// The sections, or just the one with this id (the rail's flyout). With a query each holds only the names that
    /// match and stands open; one without a match is left out. The remembered folds are not touched meanwhile.
    @ViewBuilder
    private func sections(only: String?, query: String) -> some View {
        let show = { (id: String) in only == nil || only == id }
        let filtering = !query.isEmpty
        let forced: Binding<Bool>? = filtering ? .constant(true) : nil

        let locals = BranchFolders(store.localBranches, key: { $0.name }, pinned: { store.isPinned($0) }).filtered(query)
        if show("local"), !filtering || locals.count > 0 {
            SidebarSection("local", open: forced) {
                // "Pin to top": pinned branches lead under their whole names, out of their folders
                ForEach(locals.pinned) { b in localRow(b, label: b.name) }
                ForEach(locals.loose) { b in localRow(b, label: b.name) }
                ForEach(locals.folders) { f in
                    DisclosureGroup(isExpanded: expansion("l:" + f.name, forced: filtering)) {
                        ForEach(f.branches) { b in localRow(b, label: BranchFolders.leaf(b.name)) }
                    } label: {
                        folderLabel(f)
                    }
                    .disclosureGroupStyle(SidebarTreeGroup())
                }
            } header: {
                Text("Local branches")
                Spacer(minLength: 4)
                StatusPill(title: "\(locals.count)", tone: .neutral)
            }
        }

        let remotes = remoteGroups(query)
        if show("remotes"), !remotes.isEmpty {
            SidebarSection("remotes", open: forced) {
                ForEach(remotes, id: \.0) { remote, groups in
                    DisclosureGroup(isExpanded: expansion("r:" + remote, forced: filtering)) {
                        ForEach(groups.loose) { b in remoteRow(b, label: b.shortName) }
                        ForEach(groups.folders) { f in
                            DisclosureGroup(isExpanded: expansion("r:\(remote)/\(f.name)", forced: filtering)) {
                                ForEach(f.branches) { b in remoteRow(b, label: BranchFolders.leaf(b.shortName)) }
                            } label: {
                                folderLabel(f)
                            }
                            .disclosureGroupStyle(SidebarTreeGroup())
                        }
                    } label: {
                        groupLabel(remote, icon: .cloud, count: groups.count)
                    }
                    .disclosureGroupStyle(SidebarTreeGroup())
                }
            } header: {
                // each remote's own row carries its count
                Text("Remotes")
            }
        }

        let tags = store.tags.filter { BranchFilter.matches($0.name, query) }
        if show("tags"), !tags.isEmpty {
            SidebarSection("tags", open: forced) {
                ForEach(tags) { t in
                    // the branch rows' disclosure and icon columns, so the names line up
                    HStack(spacing: 6) {
                        Color.clear.frame(width: 10, height: 16).accessibilityHidden(true)
                        DesignIconImage(icon: .releases, size: 13).foregroundStyle(StudioStyle.Rail.icon)
                        Text(t.name).lineLimit(1).truncationMode(.tail)
                    }
                        .sidebarTreeRow()
                        .contentShape(Rectangle())
                        .onTapGesture { store.reveal(t.target) }
                        .contextMenu {
                            Button("Go to this tag") { store.reveal(t.target) }
                            Button("Push tag") { Task { await store.pushTag(t) } }
                            if store.target != nil { Button("Open in Releases") { store.navigate(.releases) } }
                            Divider()
                            Button("Delete tag…", role: .destructive) { store.deleteTag(t) }
                        }
                }
            } header: {
                Text("Tags")
                Spacer(minLength: 4)
                StatusPill(title: "\(tags.count)", tone: .neutral)
            }
        }

        // no board draws stashes; the list stays because nothing else shows it. The field filters names, so it is
        // hidden meanwhile
        if show("stashes"), !filtering, !store.stashes.isEmpty {
            SidebarSection("stashes") {
                ForEach(store.stashes) { s in
                    HStack(alignment: .top, spacing: 6) {
                        Color.clear.frame(width: 10, height: 16).accessibilityHidden(true)
                        SymbolIcon("archivebox").font(.system(size: 12)).foregroundStyle(StudioStyle.Rail.icon)
                            .frame(width: 13, height: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.message).lineLimit(1)
                            Text(s.ref).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .sidebarTreeRow()
                    .contentShape(Rectangle())
                    .onTapGesture { store.reveal(s.hash) }
                    .contextMenu {
                        Button("Apply") { Task { await store.stashApply(s) } }
                        Button("Pop") { Task { await store.stashPop(s) } }
                        Divider()
                        Button("Drop…", role: .destructive) { store.stashDrop(s) }
                    }
                }
            } header: {
                Text("Stashes")
                Spacer(minLength: 4)
                StatusPill(title: "\(store.stashes.count)", tone: .neutral)
            }
        }
    }

    /// 현재 브랜치가 든 폴더는 펼쳐 둔다
    private func expandCurrent() {
        if let h = store.headBranch, let slash = h.firstIndex(of: "/") {
            expanded.insert("l:" + h[..<slash])
        }
    }

    /// forced: the filter is on, so the folder holds a match and stands open whatever was remembered
    private func expansion(_ id: String, forced: Bool = false) -> Binding<Bool> {
        if forced { return .constant(true) }
        return Binding(get: { expanded.contains(id) },
                set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } })
    }

    /// A folder is plain grey even when it holds the current branch: the branch's own marker says so
    private func folderLabel(_ f: BranchFolder) -> some View {
        groupLabel(f.name, icon: .repository, count: f.branches.count)
    }

    /// A folder or a remote: a 13 pt icon, the name, and how many branches it holds as a neutral pill at the right edge
    private func groupLabel(_ name: String, icon: DesignIcon, count: Int) -> some View {
        HStack(spacing: 6) {
            DesignIconImage(icon: icon, size: 13).foregroundStyle(StudioStyle.Rail.icon)
            Text(name).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            StatusPill(title: "\(count)", tone: .neutral)
        }
    }

    private func localRow(_ b: Branch, label: String) -> some View {
        BranchRow(branch: b, label: label, hidden: store.isHidden(b), pinned: store.isPinned(b),
                  protected: store.gitchProtected.contains(b.name), showAgain: { Task { await store.setHidden(b, false) } })
            .sidebarTreeRow()
            .contentShape(Rectangle())
            .draggable(RepoStore.branchPayload + b.name) { Label(b.name, symbol: "arrow.triangle.branch").padding(6) }
            .onTapGesture(count: 2) { Task { await store.checkout(b) } }
            .onTapGesture { store.reveal(b.target) }
            .contextMenu { localMenu(b) }
    }

    private func remoteRow(_ b: Branch, label: String) -> some View {
        BranchRow(branch: b, label: label, hidden: store.isHidden(b), showAgain: { Task { await store.setHidden(b, false) } })
            .sidebarTreeRow()
            .contentShape(Rectangle())
            .draggable(RepoStore.branchPayload + b.name) { Label(b.name, symbol: "cloud").padding(6) }
            .onTapGesture(count: 2) { Task { await store.checkout(b) } }
            .onTapGesture { store.reveal(b.target) }
            .contextMenu { remoteMenu(b) }
    }

    /// Each remote with its branches in folders, narrowed to the query; a remote without a match is left out
    private func remoteGroups(_ query: String) -> [(String, BranchFolders)] {
        Dictionary(grouping: store.remoteBranches) { $0.remote ?? "" }
            .sorted { $0.key < $1.key }
            .map { ($0.key, BranchFolders($0.value) { $0.shortName }.filtered(query)) }
            .filter { $0.1.count > 0 }
    }

    @ViewBuilder
    private func localMenu(_ b: Branch) -> some View {
        Button("Check out") { Task { await store.checkout(b) } }
            .disabled(b.isCurrent)
        if let current = store.headBranch, !b.isCurrent {
            Button("Merge '\(b.name)' into '\(current)'") { Task { await store.merge(b.name) } }
            Button("Rebase '\(current)' onto '\(b.name)'") { Task { await store.rebase(onto: b.name) } }
        }
        MergeIntoMenu(source: b.name)
        Divider()
        Button("New branch from here…") { store.requestNewBranch(from: b.target, label: b.name) }
        Button("Check out in a new worktree…") { store.sheet = .addWorktree(branch: b.name, start: nil) }
            .disabled(b.isCurrent || store.worktree(using: b.name) != nil)
        if let w = store.worktree(using: b.name) {
            Button("Open this branch's worktree") { Task { await store.switchWorktree(to: w.path) } }
            Button("Run an agent in a worktree") { store.startAgent(in: w.path) }
        }
        Button("Push") { Task { await store.pushBranch(b) } }
        Button("Copy name") { store.copy(b.name) }
        if store.gitchStatus != nil {
            let protected = store.gitchProtected.contains(b.name)
            Button(protected ? "Allow direct push (gitch)" : "Protect from direct push (gitch)") {
                Task { await store.setGitchProtected(b.name, !protected) }
            }
        }
        Divider()
        Button(store.isPinned(b) ? "Unpin" : "Pin to top") { store.setPinned(b, !store.isPinned(b)) }
        Button(store.isHidden(b) ? "Show in graph again" : "Hide from graph") { Task { await store.setHidden(b, !store.isHidden(b)) } }
            .disabled(b.isCurrent && !store.isHidden(b))
        Divider()
        Button("Delete…", role: .destructive) { store.confirmDelete(b) }
            .disabled(b.isCurrent)
        Button("Force delete…", role: .destructive) { store.confirmForceDelete(b) }
            .disabled(b.isCurrent)
    }

    @ViewBuilder
    private func remoteMenu(_ b: Branch) -> some View {
        Button("Check out (local tracking branch)") { Task { await store.checkout(b) } }
        if let current = store.headBranch {
            Button("Merge '\(b.name)' into '\(current)'") { Task { await store.merge(b.name) } }
            Button("Rebase '\(current)' onto '\(b.name)'") { Task { await store.rebase(onto: b.name) } }
        }
        MergeIntoMenu(source: b.name)
        Divider()
        Button("New branch from here…") { store.requestNewBranch(from: b.target, label: b.name) }
        Button("Copy name") { store.copy(b.name) }
        Button(store.isHidden(b) ? "Show in graph again" : "Hide from graph") { Task { await store.setHidden(b, !store.isHidden(b)) } }
        Divider()
        Button("Delete from remote…", role: .destructive) { store.confirmDelete(b) }
    }
}

/// A branch row. After the name come only the marks whose state shows nowhere else (pinned, protected by gitch,
/// hidden from the graph, upstream gone), then ahead and behind. (Windows: BranchRow in Sidebar.tsx)
private struct BranchRow: View {
    let branch: Branch
    var label: String? = nil
    var hidden = false
    var pinned = false
    /// gitch 가 직접 push 를 막는 브랜치(gitch protect)
    var protected = false
    /// Shows a hidden branch in the graph again
    var showAgain: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: 10, height: 16)
                .accessibilityHidden(true)
            Group {
                if branch.isCurrent { CurrentMarker() } else { DesignIconImage(icon: .branch, size: 13).foregroundStyle(StudioStyle.Rail.icon) }
            }
                .frame(width: 13)
            Text(label ?? (branch.isRemote ? branch.shortName : branch.name))
                .fontWeight(branch.isCurrent ? .semibold : .regular)
                .foregroundStyle(hidden ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(branch.name)
            Spacer(minLength: 4)
            if pinned {
                SymbolIcon("pin.fill").font(.caption2).foregroundStyle(.secondary).help("Pinned").accessibilityLabel("Pinned")
            }
            if protected {
                SymbolIcon("lock.shield").font(.caption2).foregroundStyle(.secondary)
                    .help("Protected by gitch: no direct pushes, merge through a pull request")
            }
            if hidden {
                // only a hidden branch carries the eye: it says so and shows the branch again (hiding is in the row's menu)
                Button(action: showAgain) {
                    SymbolIcon("eye.slash")
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show in graph again").accessibilityLabel("Show in graph again")
            }
            if branch.upstreamGone {
                SymbolIcon("exclamationmark.icloud").foregroundStyle(.orange)
                    .help("The tracked remote branch was deleted")
            }
            if branch.ahead > 0 { counter("↑\(branch.ahead)") }
            if branch.behind > 0 { counter("↓\(branch.behind)") }
        }
    }

    /// Ahead or behind: plain monospaced 11 pt in the caption grey, no capsule
    private func counter(_ s: String) -> some View {
        Text(verbatim: s)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(StudioStyle.Rail.icon)
            .fixedSize()
    }
}

/// A sidebar section: a header row that folds it (remembered), and a pane that shares the sidebar's height with the
/// other sections (Windows: widgets/sidebar/ui/Section.tsx)
struct SidebarSection<Header: View, Content: View>: View {
    let id: String
    let content: Content
    let header: Header
    /// The caller keeps the state, for a section that starts folded; otherwise the folded sections are remembered by id
    let ownOpen: Binding<Bool>?
    @AppStorage(SidebarSections.key) private var collapsed = ""
    /// In the rail's flyout the section is always open and does not fold
    @Environment(\.sidebarFlyout) private var flyout

    init(_ id: String, open: Binding<Bool>? = nil, @ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) {
        self.id = id
        self.ownOpen = open
        self.content = content()
        self.header = header()
    }

    var body: some View {
        let open = flyout ? .constant(true) : ownOpen ?? SidebarSections.binding($collapsed, id)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if !flyout {
                    DesignIconImage(icon: .chevronDown, size: 10)
                        .rotationEffect(.degrees(open.wrappedValue ? 0 : -90))
                }
                header
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(StudioStyle.Rail.icon)
            .lineLimit(1)
            // the chevron stands over the rows' disclosure column, the title over their icons
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 26)
            .contentShape(Rectangle())
            .onTapGesture { open.wrappedValue.toggle() }
            if open.wrappedValue {
                SharedPane(id: id) {
                    VStack(alignment: .leading, spacing: 0) { content }
                        .padding(.horizontal, 6)
                }
            }
        }
        .padding(.top, 6)
    }
}

private struct SidebarFlyoutKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The sidebar section is shown as a flyout of the rail
    var sidebarFlyout: Bool {
        get { self[SidebarFlyoutKey.self] }
        set { self[SidebarFlyoutKey.self] = newValue }
    }
}

/// 사이드바 구역(로컬 브랜치·워크트리·원격·태그·스태시 등)을 통째로 접고 펴기 — 접은 구역은 기억해 둔다
enum SidebarSections {
    static let key = "collapsedSections"

    static func binding(_ raw: Binding<String>, _ id: String) -> Binding<Bool> {
        Binding(
            get: { !raw.wrappedValue.split(separator: ",").contains { $0 == id } },
            set: { open in
                var set = Set(raw.wrappedValue.split(separator: ",").map(String.init))
                if open { set.remove(id) } else { set.insert(id) }
                raw.wrappedValue = set.sorted().joined(separator: ",")
            })
    }
}
