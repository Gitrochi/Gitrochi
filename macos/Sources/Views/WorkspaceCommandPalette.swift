import SwiftUI

struct WorkspaceCommand: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let group: String
    var shortcut = ""
    var enabled = true
    let action: () -> Void
}

/// 화면과 참조를 한곳에서 찾되 브랜치 선택은 기존의 '탐색' 의미를 유지한다.
struct WorkspaceCommandPalette: View {
    @Environment(RepoStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @ViewState private var query = ""
    @ViewState private var highlighted: String?
    @FocusState private var searchFocused: Bool
    let execute: (WorkspaceCommand) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(StudioStyle.accent)
                TextField("Search views, branches and actions…", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 14))
                    .focused($searchFocused)
                    .onSubmit(activateHighlighted)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .accessibilityLabel("Quick navigation")
                Button { dismiss() } label: {
                    Text("esc").font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary).padding(.horizontal, 5).padding(.vertical, 3)
                        .background(StudioStyle.canvas, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain).keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close quick navigation")
            }
            .padding(18)
            Divider()
            results
            Divider()
            HStack {
                Text("↑ ↓ to navigate · Return to open · Esc to close")
                Spacer()
                Text("\(items.count) results").monospacedDigit()
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
            .padding(.horizontal, 16).frame(height: 31)
            .background(StudioStyle.canvas)
        }
        .frame(width: 620, height: 460)
        .background(StudioStyle.surface)
        .tint(StudioStyle.accent)
        .onAppear { searchFocused = true; highlighted = items.first?.id }
        .onChange(of: query) { _, _ in highlighted = items.first?.id }
        .onChange(of: items.map(\.id)) { _, ids in
            if highlighted == nil || !ids.contains(highlighted ?? "") { highlighted = ids.first }
        }
    }

    @ViewBuilder private var results: some View {
        if items.isEmpty {
            WorkspaceEmptyState(title: "No matching commands", systemImage: "magnifyingglass",
                                description: "Try a view, branch name or action.")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if index == 0 || items[index - 1].group != item.group {
                                Text(item.group).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 5)
                            }
                            Button { if item.enabled { execute(item) } } label: {
                                commandRow(item)
                            }
                            .buttonStyle(.plain).disabled(!item.enabled)
                            .id(item.id)
                            .accessibilityLabel(item.title)
                            .accessibilityHint(item.subtitle)
                            .accessibilityAddTraits(highlighted == item.id ? .isSelected : [])
                        }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 8)
                }
                .onChange(of: highlighted) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
    }

    private func commandRow(_ item: WorkspaceCommand) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon).font(.system(size: 14)).foregroundStyle(StudioStyle.accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if !item.shortcut.isEmpty {
                Text(item.shortcut).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 39, alignment: .leading)
        .background(highlighted == item.id ? StudioStyle.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
        .opacity(item.enabled ? 1 : 0.5)
        .contentShape(Rectangle())
        .onHover { if $0 { highlighted = item.id } }
    }

    private func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == highlighted } ?? 0
        highlighted = items[min(max(current + delta, 0), items.count - 1)].id
    }

    private func activateHighlighted() {
        guard let item = items.first(where: { $0.id == highlighted }), item.enabled else { return }
        execute(item)
    }

    private var items: [WorkspaceCommand] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return Array(commands.filter { command in
            words.allSatisfy { (command.title + " " + command.subtitle + " " + command.id).localizedStandardContains($0) }
        }.prefix(60))
    }

    private var commands: [WorkspaceCommand] {
        let go = String(localized: "Go to")
        let pages: [WorkspaceDestination] = [.home, .repositories, .repository, .changes, .commits, .branches, .compare, .rebase, .code, .inbox, .myWork, .pullRequests, .issues, .actions, .releases, .projects, .organizations, .gists, .assistant, .agents, .flows, .worktrees, .operations]
        let shortcuts: [WorkspaceDestination: String] = [.home: "0", .changes: "1", .commits: "2", .branches: "3", .pullRequests: "4", .actions: "5", .agents: "6"]
        var result = pages.map { page in
            WorkspaceCommand(id: "view-\(page.rawValue)", title: page.title(gitlab: store.target?.provider == .gitlab),
                             subtitle: page == .repository ? store.name : "", icon: page.symbol,
                             group: go, shortcut: shortcuts[page].map { "⌘" + $0 } ?? "",
                             enabled: !page.needsRepository || store.url != nil) { store.navigate(page) }
        }
        let available = store.url != nil && store.busy == nil
        let waiting = String(localized: "Wait for the current operation to finish.")
        let branches = store.localBranches + store.remoteBranches
        result += (query.isEmpty ? Array(branches.prefix(8)) : branches).map { branch in
            WorkspaceCommand(id: "branch-\(branch.name)", title: branch.name,
                             subtitle: !available && store.commitIndex[branch.target] == nil ? waiting
                                : branch.isCurrent ? String(localized: "Current branch") : String(localized: "View branch in history"),
                             icon: branch.isRemote ? "cloud" : "arrow.triangle.branch", group: String(localized: "Branches"),
                             enabled: store.url != nil && (available || store.commitIndex[branch.target] != nil)) {
                store.navigate(.commits)
                store.selectedBranchID = branch.id
                store.closeFileInspect(); store.closeDiff(); store.reveal(branch.target)
            }
        }
        result += (query.isEmpty ? Array(store.pullRequests.prefix(4)) : store.pullRequests).map { request in
            WorkspaceCommand(id: "request-\(request.number)", title: "#\(request.number) " + request.title,
                             subtitle: "\(request.source) → \(request.target)", icon: "arrow.triangle.pull",
                             group: String(localized: "Pull requests")) { store.navigate(.pullRequests); store.select(.pullRequest(request.number)) }
        }
        let actions = String(localized: "Actions")
        result += [
            WorkspaceCommand(id: "action-search-commits", title: String(localized: "Search commits"), subtitle: "",
                             icon: "magnifyingglass", group: actions, shortcut: "⌘F") { store.requestSearchFocus() },
            WorkspaceCommand(id: "action-new-branch", title: String(localized: "New branch…"), subtitle: available ? (store.headBranch ?? "") : waiting,
                             icon: "plus", group: actions, shortcut: "⇧⌘B", enabled: available) { store.requestNewBranch() },
            WorkspaceCommand(id: "action-new-worktree", title: String(localized: "New worktree…"), subtitle: available ? "" : waiting,
                             icon: "folder.badge.plus", group: actions, enabled: available) { store.sheet = .addWorktree(branch: nil, start: nil) },
            WorkspaceCommand(id: "action-terminal", title: String(localized: "Terminal"), subtitle: String(localized: "Show or hide the terminal"),
                             icon: "terminal", group: actions, shortcut: "⌃` ") { store.toggleTerminal() },
            WorkspaceCommand(id: "action-open-repository", title: String(localized: "Open repository…"), subtitle: "",
                             icon: "folder", group: actions, shortcut: "⌘O") { store.presentOpenPanel() },
            WorkspaceCommand(id: "action-clone-repository", title: String(localized: "Clone repository…"), subtitle: "",
                             icon: "square.and.arrow.down", group: actions) { store.sheet = .clone },
            WorkspaceCommand(id: "action-settings", title: String(localized: "Settings"), subtitle: "",
                             icon: "gearshape", group: actions, shortcut: "⌘,") { openSettings() },
        ]
        result += store.recents.filter { $0 != store.url }.prefix(query.isEmpty ? 5 : 30).map { url in
            WorkspaceCommand(id: "repository-" + url.path, title: url.lastPathComponent,
                             subtitle: (url.path as NSString).abbreviatingWithTildeInPath,
                             icon: "externaldrive", group: String(localized: "Repositories")) {
                Task { await store.openOrReport(url) }
            }
        }
        return result
    }
}
