import SwiftUI

struct SidebarView: View {
    @Environment(RepoStore.self) private var store
    @ViewState private var expanded: Set<String> = []
    /// Set: only this section, as a flyout of the rail (the sidebar folded away)
    var flyout: String? = nil
    @ViewState private var flyoutHeight: CGFloat = 200

    @AppStorage("sidebarMode") private var mode = "list"
    @AppStorage(SidebarSections.key) private var collapsed = ""

    var body: some View {
        if let flyout {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) { sections(only: flyout) }
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
        VStack(spacing: 0) {
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
                branchList
            }
        }
        // 반투명 사이드바는 바탕화면 색이 비쳐 물들어 보인다 — 불투명한 중립 배경으로
        .scrollContentBackground(.hidden)
        .background(StudioStyle.sidebar.ignoresSafeArea())
    }

    private func open(_ id: String) -> Binding<Bool> { SidebarSections.binding($collapsed, id) }

    /// 지금 일하거나 허락을 기다리는 세션 수
    private var activeAgents: Int {
        let paths = Set(store.worktrees.map { AgentCenter.normalize($0.path) })
        return AgentCenter.shared.sessions.filter { $0.status.isActive && paths.contains(AgentCenter.normalize($0.path)) }.count
    }

    private var branchList: some View {
        SharedStack {
            // with each section's own 6 pt on top, a head stands 12 pt under the rows before it
            VStack(alignment: .leading, spacing: 6) { sections(only: nil) }
                .padding(.horizontal, 4)
                .padding(.bottom, 8)
        }
        .onAppear(perform: expandCurrent)
        .onChange(of: store.headBranch) { _, _ in expandCurrent() }
    }

    /// The sections, or just the one with this id (the rail's flyout)
    @ViewBuilder
    private func sections(only: String?) -> some View {
        let show = { (id: String) in only == nil || only == id }

        let pinned = store.localBranches.filter { store.isPinned($0) }
        if show("pinned"), !pinned.isEmpty {
            SidebarSection("pinned") {
                ForEach(pinned) { b in localRow(b, label: b.name) }
            } header: {
                Text("Pinned")
            }
        }

        if show("local") {
            SidebarSection("local") {
                let groups = BranchFolders(store.localBranches) { $0.name }
                ForEach(groups.loose) { b in localRow(b, label: b.name) }
                ForEach(groups.folders) { f in
                    DisclosureGroup(isExpanded: expansion("l:" + f.name)) {
                        ForEach(f.branches) { b in localRow(b, label: BranchFolders.leaf(b.name)) }
                    } label: {
                        folderLabel(f)
                    }
                    .disclosureGroupStyle(SidebarTreeGroup())
                }
            } header: {
                Text("Local branches")
                Spacer(minLength: 4)
                StatusPill(title: "\(store.localBranches.count)", tone: .neutral)
            }
        }

        if show("worktrees"), store.worktrees.count > 1 {
            WorktreeSection()
        }

        if show("remotes"), !store.remoteBranches.isEmpty {
            SidebarSection("remotes") {
                ForEach(remoteGroups, id: \.0) { remote, branches in
                    DisclosureGroup(isExpanded: expansion("r:" + remote)) {
                        let groups = BranchFolders(branches) { $0.shortName }
                        ForEach(groups.loose) { b in remoteRow(b, label: b.shortName) }
                        ForEach(groups.folders) { f in
                            DisclosureGroup(isExpanded: expansion("r:\(remote)/\(f.name)")) {
                                ForEach(f.branches) { b in remoteRow(b, label: BranchFolders.leaf(b.shortName)) }
                            } label: {
                                folderLabel(f)
                            }
                            .disclosureGroupStyle(SidebarTreeGroup())
                        }
                    } label: {
                        groupLabel(remote, icon: .cloud, count: branches.count)
                    }
                    .disclosureGroupStyle(SidebarTreeGroup())
                }
            } header: {
                // each remote's own row carries its count
                Text("Remotes")
            }
        }

        // the hosting lists sit between the branches and the tags
        if show("pullRequests"), let target = store.target {
            PullRequestSection(target: target)
        }
        if show("issues"), store.target != nil {
            IssueListSection()
        }

        // with a hosting remote the section stays, even without tags, for its way to the Releases page
        if show("tags"), !store.tags.isEmpty || store.target != nil {
            SidebarSection("tags") {
                ForEach(store.tags) { t in
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
                HStack(spacing: 6) {
                    Text("Tags")
                    // beside the title when the head has a button, at the right edge when it has none
                    if store.target != nil { StatusPill(title: "\(store.tags.count)", tone: .neutral) }
                    Spacer(minLength: 4)
                    if store.target == nil { StatusPill(title: "\(store.tags.count)", tone: .neutral) }
                    if store.target != nil {
                        Button { store.navigate(.releases) } label: { DesignIconImage(icon: .external) }
                            .buttonStyle(.borderless)
                            .help("Open in Releases")
                    }
                }
            }
        }

        if show("stashes"), !store.stashes.isEmpty {
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

    private func expansion(_ id: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) },
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
        // the current branch always shows in the graph
        let canHide = !b.isCurrent || store.isHidden(b)
        return BranchRow(branch: b, label: label, worktreePath: store.worktree(using: b.name)?.path,
                         hidden: store.isHidden(b), pinned: store.isPinned(b), protected: store.gitchProtected.contains(b.name),
                         toggleHidden: canHide ? { Task { await store.setHidden(b, !store.isHidden(b)) } } : nil)
            .sidebarTreeRow()
            .contentShape(Rectangle())
            .draggable(RepoStore.branchPayload + b.name) { Label(b.name, symbol: "arrow.triangle.branch").padding(6) }
            .onTapGesture(count: 2) { Task { await store.checkout(b) } }
            .onTapGesture { store.reveal(b.target) }
            .contextMenu { localMenu(b) }
    }

    private func remoteRow(_ b: Branch, label: String) -> some View {
        BranchRow(branch: b, label: label, hidden: store.isHidden(b),
                  toggleHidden: { Task { await store.setHidden(b, !store.isHidden(b)) } })
            .sidebarTreeRow()
            .contentShape(Rectangle())
            .draggable(RepoStore.branchPayload + b.name) { Label(b.name, symbol: "cloud").padding(6) }
            .onTapGesture(count: 2) { Task { await store.checkout(b) } }
            .onTapGesture { store.reveal(b.target) }
            .contextMenu { remoteMenu(b) }
    }

    private var remoteGroups: [(String, [Branch])] {
        Dictionary(grouping: store.remoteBranches) { $0.remote ?? "" }
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value) }
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

/// 브랜치 이름의 첫 '/' 앞부분(feature, fix, hotfix …)으로 묶은 폴더
struct BranchFolder: Identifiable {
    let name: String
    let branches: [Branch]
    var id: String { name }
}

struct BranchFolders {
    let loose: [Branch]
    let folders: [BranchFolder]

    init(_ branches: [Branch], key: (Branch) -> String) {
        var loose: [Branch] = []
        var byFolder: [String: [Branch]] = [:]
        for b in branches {
            let k = key(b)
            if let slash = k.firstIndex(of: "/") {
                byFolder[String(k[..<slash]), default: []].append(b)
            } else {
                loose.append(b)
            }
        }
        var folders: [BranchFolder] = []
        for (name, list) in byFolder {
            if list.count == 1 { loose.append(list[0]) } else { folders.append(BranchFolder(name: name, branches: list)) }
        }
        self.loose = loose.sorted { key($0).localizedStandardCompare(key($1)) == .orderedAscending }
        self.folders = folders.sorted { $0.name < $1.name }
    }

    /// 폴더 이름을 뺀 나머지(feature/auth-jwt → auth-jwt)
    static func leaf(_ name: String) -> String {
        guard let slash = name.firstIndex(of: "/") else { return name }
        return String(name[name.index(after: slash)...])
    }
}

private struct BranchRow: View {
    let branch: Branch
    var label: String? = nil
    var worktreePath: String? = nil
    var hidden = false
    var pinned = false
    /// gitch 가 직접 push 를 막는 브랜치(gitch protect)
    var protected = false
    /// Hides the branch from the graph or shows it again (nil: not allowed, the eye is not shown)
    var toggleHidden: (() -> Void)? = nil
    @ViewState private var hovering = false

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
                SymbolIcon("pin.fill").font(.caption2).foregroundStyle(.secondary).help("Branches pinned to the top")
            }
            if protected {
                SymbolIcon("lock.shield").font(.caption2).foregroundStyle(.secondary)
                    .help("Protected by gitch: no direct pushes, merge through a pull request")
            }
            if let toggleHidden {
                // the eye shows on hover; a hidden branch keeps it so the state stays visible
                Button(action: toggleHidden) {
                    SymbolIcon(hidden ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(hovering || hidden ? 1 : 0)
                .help(hidden ? String(localized: "Show in graph again") : String(localized: "Hide from graph"))
            }
            if let worktreePath {
                DesignIconImage(icon: .repository).foregroundStyle(.secondary)
                    .help("In use by a worktree: \(worktreePath)")
            }
            if branch.upstreamGone {
                SymbolIcon("exclamationmark.icloud").foregroundStyle(.orange)
                    .help("The tracked remote branch was deleted")
            }
            if branch.ahead > 0 { counter("↑\(branch.ahead)") }
            if branch.behind > 0 { counter("↓\(branch.behind)") }
        }
        .onHover { hovering = $0 }
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

extension View {
    /// A sidebar row without the tree's columns (a pull request, an issue, a notice), with the tree rows' side padding
    func sidebarRow() -> some View {
        padding(.vertical, 3)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
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
