import SwiftUI
import AppKit

/// Another worktree's row in the graph: its uncommitted files, read-only (GitKraken's worktree WIP node)
struct WorktreeChangesView: View {
    @Environment(RepoStore.self) private var store
    let path: String

    var body: some View {
        let worktree = store.worktrees.first { $0.path == path }
        let files = store.worktreeStatus[path]?.files ?? []
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                Text(worktree?.branch ?? String(localized: "Detached HEAD")).font(.headline).lineLimit(1)
                Spacer()
                Text("Worktree").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text((path as NSString).abbreviatingWithTildeInPath)
                        .font(.callout).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.head)
                        .textSelection(.enabled)
                    HStack {
                        Button { Task { await store.switchWorktree(to: path) } } label: {
                            Label("Open worktree", systemImage: "arrow.right.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Open in new tab") { Task { await store.openOrReport(URL(fileURLWithPath: path, isDirectory: true)) } }
                    }
                    Text("Uncommitted changes in this worktree. Open it to stage and commit.")
                        .font(.caption).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Changed files \(files.count)").font(.subheadline.weight(.semibold))
                        ForEach(files, id: \.path) { f in row(f) }
                        if files.isEmpty { Text("No changes").foregroundStyle(.secondary) }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func row(_ f: FileChange) -> some View {
        let source = DiffSource.worktree(path: path, change: f)
        return HStack(spacing: 6) {
            StatusBadge(kind: f.kind)
            Text((f.path as NSString).lastPathComponent).lineLimit(1)
            Text((f.path as NSString).deletingLastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 4)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(store.diffSource == source ? Color.accentColor.opacity(0.18) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { store.openDiff(source) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { store.openDiff(source) }
        .help("Click to see the diff in the center")
    }
}
