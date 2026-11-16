import SwiftUI

// MARK: - 작업 영역

struct WorkingChangesView: View {
    @Environment(RepoStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            Divider()
            if store.repoState != .clean { OperationBanner() }
            GeometryReader { geometry in
                SharedStack {
                    VStack(alignment: .leading, spacing: 12) {
                    if !store.status.conflicted.isEmpty {
                        FileSection(title: String(localized: "Conflict"), color: .red, count: store.status.conflicted.count,
                                    actionTitle: String(localized: "Mark all as resolved"),
                                    action: { Task { await store.stage(store.status.conflicted) } }) {
                            ChangeList(changes: store.status.conflicted, isSelected: isOpen,
                                       actionIcon: "checkmark.circle", actionHelp: String(localized: "Mark as resolved (stage)"),
                                       onAction: { files in Task { await store.stage(files) } },
                                       onOpen: open) { c in
                                Button("Mark as resolved") { Task { await store.stage([c]) } }
                                Divider()
                                Button("Show in Finder") { store.revealInFinder(c) }
                            }
                        }
                    }
                    FileSection(title: String(localized: "Unstaged files"), color: .orange, count: store.status.unstaged.count,
                                actionTitle: String(localized: "Stage all"),
                                action: { Task { await store.stageAll() } }) {
                        ChangeList(changes: store.status.unstaged, isSelected: isOpen, stats: store.unstagedStats,
                                   actionIcon: "plus.circle", actionHelp: String(localized: "Stage"),
                                   onAction: { files in Task { await store.stage(files) } },
                                   onOpen: open) { c in
                            Button("Stage") { Task { await store.stage([c]) } }
                            Button("Discard changes…", role: .destructive) { store.confirmDiscard(c) }
                            Divider()
                            if c.kind != .untracked {
                                Button("File history") { store.openFileHistory(c.path) }
                                Button("Show blame") { store.openBlame(c.path) }.disabled(c.kind == .deleted)
                                Divider()
                            }
                            Button("Show in Finder") { store.revealInFinder(c) }
                            Button("Copy path") { store.copy(c.path) }
                        }
                    }
                    FileSection(title: String(localized: "Staged files"), color: .green, count: store.status.staged.count,
                                actionTitle: String(localized: "Unstage all"),
                                action: { Task { await store.unstageAll() } }) {
                        ChangeList(changes: store.status.staged, isSelected: isOpen, stats: store.stagedStats,
                                   actionIcon: "minus.circle", actionHelp: String(localized: "Unstage"),
                                   onAction: { files in Task { await store.unstage(files) } },
                                   onOpen: open) { c in
                            Button("Unstage") { Task { await store.unstage([c]) } }
                            Divider()
                            if c.kind != .added {
                                Button("File history") { store.openFileHistory(c.path) }
                                Button("Show blame") { store.openBlame(c.path) }.disabled(c.kind == .deleted)
                                Divider()
                            }
                            Button("Show in Finder") { store.revealInFinder(c) }
                            Button("Copy path") { store.copy(c.path) }
                        }
                    }
                    CommitImpactView()
                    if store.status.isEmpty {
                        Card {
                            Label("Working directory is clean", symbol: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Modified files appear here.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    }
                    .frame(width: max(0, geometry.size.width - 24), alignment: .topLeading)
                    .padding(12)
                }
            }
            Divider()
            CommitComposer()
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Changed files").font(.headline)
                Spacer(minLength: 4)
                FileViewToggle()
            }
            if !store.status.isEmpty {
                let total = totals
                WorkbenchFlow(spacing: 6) {
                    Text("\(store.status.count) files")
                    if total.added + total.deleted > 0 { LineStatText(added: total.added, deleted: total.deleted) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var totals: (added: Int, deleted: Int) {
        let all = Array(store.stagedStats.values) + Array(store.unstagedStats.values)
        return (all.compactMap(\.added).reduce(0, +), all.compactMap(\.deleted).reduce(0, +))
    }

    private func isOpen(_ c: FileChange) -> Bool { store.diffSource == .working(c) }

    private func open(_ c: FileChange) { store.openDiff(.working(c)) }
}

private struct FileSection<Content: View>: View {
    @Environment(RepoStore.self) private var store
    let title: String
    let color: Color
    let count: Int
    let actionTitle: String
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        if count > 0 {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text("\(count)").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Button(actionTitle, action: action).buttonStyle(.borderless).font(.caption)
                        .disabled(store.busy != nil)
                }
                .padding(.bottom, 4)
                SharedPane(id: title) { content }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct OperationBanner: View {
    @Environment(RepoStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(store.repoState.title, symbol: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(store.status.conflicted.isEmpty
                 ? "All conflicts are resolved. Continue."
                 : "Fix the conflicted files in an editor, then click 'Mark as resolved'.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("Abort…") { store.abortOperation() }
                Spacer()
                Button("Continue") { Task { await store.continueOperation() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.status.conflicted.isEmpty)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.10))
    }
}
