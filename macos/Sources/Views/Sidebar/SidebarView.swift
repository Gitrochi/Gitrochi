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
            Picker("Repository tools", selection: $mode) {
                Text("Branches").tag("list")
                Text(activeAgents > 0 ? "Agents \(activeAgents)" : "Agents").tag("agents")
                Text("CI/CD").tag("ci")
                Text("Flows").tag("flow")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Repository tools")
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            if mode == "agents" {
                AgentsPanel()
            } else if mode == "ci" {
                CIPanel()
            } else if mode == "flow" {
                FlowPanel()
            } else {
                branchList
            }
        }
        // 반투명 사이드바는 바탕화면 색이 비쳐 물들어 보인다 — 불투명한 중립 배경으로
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
    }

    private func open(_ id: String) -> Binding<Bool> { SidebarSections.binding($collapsed, id) }

    /// 지금 일하거나 허락을 기다리는 세션 수
    private var activeAgents: Int {
        let paths = Set(store.worktrees.map { AgentCenter.normalize($0.path) })
        return AgentCenter.shared.sessions.filter { $0.status.isActive && paths.contains(AgentCenter.normalize($0.path)) }.count
    }

    private var branchList: some View {
        SharedStack {
            VStack(alignment: .leading, spacing: 0) { sections(only: nil) }
                .padding(.bottom, 8)
        }
        .onAppear(perform: expandCurrent)
        .onChange(of: store.headBranch) { _, _ in expandCurrent() }
    }

    /// The sections, or just the one with this id (the rail's flyout)
    @ViewBuilder
    private func sections(only: String?) -> some View {
        let show = { (id: String) in only == nil || only == id }

        if show("pullRequests"), let target = store.target {
            PullRequestSection(target: target)
        }

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
                }
            } header: {
                Text("Local branches \(store.localBranches.count)")
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
                        }
                    } label: {
                        HStack {
                            Label(remote, systemImage: "cloud")
                            Spacer()
                            Text("\(branches.count)").font(.caption).foregroundStyle(.secondary)
                        }
                        .sidebarRow()
                    }
                }
            } header: {
                Text("Remotes \(store.remoteBranches.count)")
            }
        }

        if show("tags"), !store.tags.isEmpty {
            SidebarSection("tags") {
                ForEach(store.tags) { t in
                    Label(t.name, systemImage: "tag")
                        .lineLimit(1)
                        .sidebarRow()
                        .contentShape(Rectangle())
                        .onTapGesture { store.reveal(t.target) }
                        .contextMenu {
                            Button("Go to this tag") { store.reveal(t.target) }
                            Button("Push tag") { Task { await store.pushTag(t) } }
                            Divider()
                            Button("Delete tag…", role: .destructive) { store.deleteTag(t) }
                        }
                }
            } header: {
                Text("Tags \(store.tags.count)")
            }
        }

        if show("stashes"), !store.stashes.isEmpty {
            SidebarSection("stashes") {
                ForEach(store.stashes) { s in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.message).lineLimit(1)
                        Text(s.ref).font(.caption).foregroundStyle(.secondary)
                    }
                    .sidebarRow()
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
                Text("Stashes \(store.stashes.count)")
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

    private func folderLabel(_ f: BranchFolder) -> some View {
        HStack {
            Label(f.name, systemImage: f.branches.contains(where: \.isCurrent) ? "folder.fill" : "folder")
            Spacer()
            Text("\(f.branches.count)").font(.caption).foregroundStyle(.secondary)
        }
        .sidebarRow()
    }

    private func localRow(_ b: Branch, label: String) -> some View {
        // the current branch always shows in the graph
        let canHide = !b.isCurrent || store.isHidden(b)
        return BranchRow(branch: b, label: label, worktreePath: store.worktree(using: b.name)?.path,
                         hidden: store.isHidden(b), pinned: store.isPinned(b), protected: store.gitchProtected.contains(b.name),
                         toggleHidden: canHide ? { Task { await store.setHidden(b, !store.isHidden(b)) } } : nil)
            .sidebarRow()
            .contentShape(Rectangle())
            .draggable(RepoStore.branchPayload + b.name) { Label(b.name, systemImage: "arrow.triangle.branch").padding(6) }
            .onTapGesture(count: 2) { Task { await store.checkout(b) } }
            .onTapGesture { store.reveal(b.target) }
            .contextMenu { localMenu(b) }
    }

    private func remoteRow(_ b: Branch, label: String) -> some View {
        BranchRow(branch: b, label: label, hidden: store.isHidden(b),
                  toggleHidden: { Task { await store.setHidden(b, !store.isHidden(b)) } })
            .sidebarRow()
            .contentShape(Rectangle())
            .draggable(RepoStore.branchPayload + b.name) { Label(b.name, systemImage: "cloud").padding(6) }
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
            Image(systemName: branch.isCurrent ? "checkmark.circle.fill" : "arrow.triangle.branch")
                .foregroundStyle(branch.isCurrent ? Color.accentColor : .secondary)
                .frame(width: 16)
            Text(label ?? (branch.isRemote ? branch.shortName : branch.name))
                .fontWeight(branch.isCurrent ? .semibold : .regular)
                .foregroundStyle(hidden ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(branch.name)
            Spacer(minLength: 4)
            if pinned {
                Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary).help("Branches pinned to the top")
            }
            if protected {
                Image(systemName: "lock.shield").font(.caption2).foregroundStyle(.secondary)
                    .help("Protected by gitch: no direct pushes, merge through a pull request")
            }
            if let toggleHidden {
                // the eye shows on hover; a hidden branch keeps it so the state stays visible
                Button(action: toggleHidden) {
                    Image(systemName: hidden ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(hovering || hidden ? 1 : 0)
                .help(hidden ? String(localized: "Show in graph again") : String(localized: "Hide from graph"))
            }
            if let worktreePath {
                Image(systemName: "folder").foregroundStyle(.secondary)
                    .help("In use by a worktree: \(worktreePath)")
            }
            if branch.upstreamGone {
                Image(systemName: "exclamationmark.icloud").foregroundStyle(.orange)
                    .help("The tracked remote branch was deleted")
            }
            if branch.ahead > 0 { counter("↑\(branch.ahead)") }
            if branch.behind > 0 { counter("↓\(branch.behind)") }
        }
        .onHover { hovering = $0 }
    }

    private func counter(_ s: String) -> some View {
        Text(s)
            .font(.caption2.monospacedDigit().weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.18)))
    }
}

/// A sidebar section: a header row that folds it (remembered), and a pane that shares the sidebar's height with the
/// other sections (Windows: widgets/sidebar/ui/Section.tsx)
struct SidebarSection<Header: View, Content: View>: View {
    let id: String
    let content: Content
    let header: Header
    @AppStorage(SidebarSections.key) private var collapsed = ""
    /// In the rail's flyout the section is always open and does not fold
    @Environment(\.sidebarFlyout) private var flyout

    init(_ id: String, @ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) {
        self.id = id
        self.content = content()
        self.header = header()
    }

    var body: some View {
        let open = flyout ? .constant(true) : SidebarSections.binding($collapsed, id)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if !flyout {
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(open.wrappedValue ? 0 : -90))
                        .frame(width: 10)
                }
                header
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 10)
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
    /// The spacing a sidebar row had inside the List
    func sidebarRow() -> some View {
        padding(.vertical, 3)
            .padding(.horizontal, 4)
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
