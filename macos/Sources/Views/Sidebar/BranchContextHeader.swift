import SwiftUI

/// 선택한 커밋이 브랜치 끝일 때만 브랜치 문맥을 더하고 실제 체크아웃과 구분한다.
struct BranchContextHeader: View {
    @Environment(RepoStore.self) private var store

    private var branch: Branch? {
        store.selectedBranchContext
    }

    var body: some View {
        if let branch {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: branch.isRemote ? "cloud" : "arrow.triangle.branch")
                        .foregroundStyle(StudioStyle.accent)
                        .accessibilityHidden(true)
                    Text(branch.name).font(.system(size: 13, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle).help(branch.name)
                        .layoutPriority(1)
                    if branch.isCurrent {
                        Text("Current branch")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(StudioStyle.accent)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(StudioStyle.selection, in: Capsule())
                    }
                    Spacer(minLength: 0)
                    if !branch.isCurrent {
                        Button("Check out") {
                            store.selectedBranchID = branch.id
                            Task { await store.checkout(branch) }
                        }
                            .disabled(store.busy != nil)
                            .help("Make this branch the current branch")
                    }
                    branchMenu(branch)
                }
                .controlSize(.small)
                tracking(branch)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(StudioStyle.surface)
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private func tracking(_ branch: Branch) -> some View {
        HStack(spacing: 6) {
            if branch.upstreamGone {
                Label("The tracked remote branch was deleted", systemImage: "exclamationmark.icloud")
                    .foregroundStyle(.orange)
            } else if let upstream = branch.upstream {
                Label(upstream, systemImage: "cloud")
                    .lineLimit(1).truncationMode(.middle).help(upstream)
                Text("·").accessibilityHidden(true)
                if branch.ahead == 0 && branch.behind == 0 {
                    Text("Up to date").lineLimit(1)
                } else {
                    Text("↑\(branch.ahead) to push · ↓\(branch.behind) to pull")
                        .monospacedDigit().lineLimit(1).layoutPriority(1)
                }
            } else if branch.isRemote {
                Text("Remote branch")
            } else {
                Text("No upstream")
            }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func branchMenu(_ branch: Branch) -> some View {
        Menu {
            Button("Show in history") {
                store.navigate(.commits)
                store.closeFileInspect()
                store.closeDiff()
                store.reveal(branch.target)
            }
            Button("New branch from here…") { store.requestNewBranch(from: branch.target, label: branch.name) }
                .disabled(store.busy != nil)
            if !branch.isRemote {
                Button("Check out in a new worktree…") { store.sheet = .addWorktree(branch: branch.name, start: nil) }
                    .disabled(store.busy != nil || branch.isCurrent || store.worktree(using: branch.name) != nil)
            }
            Divider()
            Button("Copy name") { store.copy(branch.name) }
        } label: { Image(systemName: "ellipsis") }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Branch actions")
        .accessibilityLabel("Branch actions")
    }
}
