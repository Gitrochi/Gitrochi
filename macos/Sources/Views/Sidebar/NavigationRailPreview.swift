import SwiftUI

/// A rail preview uses the current workspace model and never starts a network request on hover.
struct NavigationRailPreview: View {
    @Environment(RepoStore.self) private var store
    let page: WorkspaceDestination
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(page.title(gitlab: store.target?.provider == .gitlab), systemImage: page.symbol).font(.headline)
                Spacer(minLength: 8)
                Button { close() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction).accessibilityLabel("Close preview")
            }.padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 6) { contents }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            Divider()
            Button("Open page") { open { store.navigate(page) } }.buttonStyle(.link).padding(12)
        }
        .frame(width: 300, height: 380)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Navigation preview")
    }

    @ViewBuilder private var contents: some View {
        switch page {
        case .repository:
            ForEach(RepositorySection.allCases) { section in
                Button { open { store.selectRepositorySection(section) } } label: {
                    Label(section.title, systemImage: section.symbol).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).padding(.vertical, 6)
            }
        case .changes:
            ForEach(Array((store.status.conflicted + store.status.unstaged + store.status.staged).prefix(16))) { file in
                Button { open { store.openDiff(.working(file)) } } label: {
                    Label(file.path, systemImage: "doc.text").lineLimit(1).truncationMode(.middle)
                }.buttonStyle(.plain).padding(.vertical, 5).help(file.path)
            }
            if store.status.isEmpty { Text("Working directory is clean").foregroundStyle(.secondary) }
        case .commits:
            ForEach(Array(store.entries.filter { !$0.commit.isWIP && $0.commit.wipWorktree == nil }.prefix(10))) { entry in
                Button { open { store.reveal(entry.id) } } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.commit.subject).lineLimit(1)
                        Text(entry.commit.short).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain).padding(.vertical, 5)
            }
        case .branches:
            referenceList
        case .pullRequests:
            ForEach(Array(store.pullRequests.prefix(12))) { request in
                Button { open { store.navigate(.pullRequests); store.select(.pullRequest(request.number)) } } label: {
                    Text("#\(request.number) " + request.title).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).padding(.vertical, 5)
            }
            if store.pullRequests.isEmpty { Text("Select a pull request").foregroundStyle(.secondary) }
        case .agents, .worktrees:
            ForEach(Array(store.worktrees.prefix(12))) { worktree in
                Button { open { Task { await store.switchWorktree(to: worktree.path) } } } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(worktree.branch ?? String(localized: "Detached HEAD")).lineLimit(1)
                        Text(worktree.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }.buttonStyle(.plain).padding(.vertical, 5)
            }
        default: EmptyView()
        }
    }

    private var referenceList: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array((store.localBranches + store.remoteBranches).prefix(16))) { branch in
                Button { open { store.selectedBranchID = branch.id; store.reveal(branch.target) } } label: {
                    Label(branch.name, systemImage: branch.isRemote ? "cloud" : "arrow.triangle.branch")
                        .lineLimit(1).truncationMode(.middle)
                }.buttonStyle(.plain).padding(.vertical, 4).help(branch.name)
            }
            if !store.tags.isEmpty {
                Divider()
                ForEach(Array(store.tags.prefix(6))) { tag in
                    Button { open { store.reveal(tag.target) } } label: { Label(tag.name, systemImage: "tag").lineLimit(1) }
                        .buttonStyle(.plain).padding(.vertical, 4)
                }
            }
            if !store.stashes.isEmpty {
                Divider()
                ForEach(Array(store.stashes.prefix(6))) { stash in
                    Button { open { store.reveal(stash.hash) } } label: { Label(stash.ref, systemImage: "tray").lineLimit(1) }
                        .buttonStyle(.plain).padding(.vertical, 4)
                }
            }
        }
    }

    private func open(_ action: () -> Void) { close(); action() }
}
