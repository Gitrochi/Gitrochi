import SwiftUI
import AppKit

struct WorktreeSection: View {
    @Environment(RepoStore.self) private var store

    var body: some View {
        SidebarSection("worktrees") {
            ForEach(store.worktrees) { w in
                let current = w.path == store.url?.path
                WorktreeRow(worktree: w, current: current)
                    .sidebarTreeRow()
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { open(w) }
                    .contextMenu {
                        Button("Open worktree") { open(w) }.disabled(current)
                        Button("Open in new tab") {
                            Task { await store.openOrReport(URL(fileURLWithPath: w.path, isDirectory: true)) }
                        }
                        .disabled(current)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: w.path)]) }
                        Button("Open in the terminal below") { store.newTerminal(in: w.path) }
                        Button("Open in Terminal") { Launcher.openTerminal(at: w.path) }
                        Button("Run agent (\(AgentCenter.shared.defaultKind.title))") { store.startAgent(in: w.path) }
                        Button("Copy path") { store.copy(w.path) }
                        Divider()
                        Button("Remove…", role: .destructive) { store.confirmRemove(w) }.disabled(w.isMain || current)
                        Button("Force remove…", role: .destructive) { store.confirmRemove(w, force: true) }.disabled(w.isMain || current)
                    }
            }
        } header: {
            HStack {
                Text("Worktrees \(store.worktrees.count)")
                Spacer()
                if store.worktrees.contains(where: \.prunable) {
                    Button("Clean up") { Task { await store.pruneWorktrees() } }
                        .buttonStyle(.borderless).font(.caption)
                }
                Button { store.sheet = .addWorktree(branch: nil, start: nil) } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("New worktree")
            }
        }
    }

    private func open(_ w: Worktree) {
        Task { await store.switchWorktree(to: w.path) }
    }
}

/// Uses the branch rows' disclosure and icon columns so the sections line up (Windows: WorktreeSection.tsx).
private struct WorktreeRow: View {
    let worktree: Worktree
    let current: Bool

    var body: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: 12, height: 16)
                .accessibilityHidden(true)
            Image(systemName: current ? "folder.fill" : "folder")
                .foregroundStyle(current ? Color.accentColor : .secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(worktree.branch ?? String(localized: "Detached HEAD \(worktree.head.map { String($0.prefix(7)) } ?? "")"))
                    .fontWeight(current ? .semibold : .regular)
                    .lineLimit(1)
                Text((worktree.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 4)
            if isTemporary && !worktree.prunable {
                Text("Temporary").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.orange.opacity(0.15)))
                    .help("Worktree in a temporary folder — it may break when the folder is deleted on restart")
            }
            if worktree.prunable {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    .help("Worktree whose folder is gone — remove it with 'Clean up'")
            } else if worktree.locked {
                Image(systemName: "lock").foregroundStyle(.secondary).help("Locked worktree")
            }
        }
    }

    private var isTemporary: Bool {
        ["/private/tmp/", "/tmp/", "/private/var/folders/", "/var/folders/"].contains { worktree.path.hasPrefix($0) }
    }
}
