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
                DesignIconImage(icon: .branch).foregroundStyle(.secondary)
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
                            Label("Open worktree", symbol: "arrow.right.circle")
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
        return FileRow(change: f, selected: store.diffSource == source, open: { store.openDiff(source) })
            // the row's fill reaches past the column so its text lines up with the heading above
            .padding(.horizontal, -8)
    }
}
