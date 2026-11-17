import SwiftUI

// MARK: - 작업 영역

/// The uncommitted changes, as the redesign board draws them (aside.insp of RepositoryChanges): a header as tall as the
/// graph's, "Changed files" with the list/tree toggle, the Unstaged and Staged groups, and the commit composer below.
/// (Windows: WorkingChanges in widgets/inspector/ui/Inspector.tsx)
struct WorkingChangesView: View {
    @Environment(RepoStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Uncommitted changes").font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            // as tall as the graph's column header beside it, so the two dividers meet in one line
            .frame(height: GraphMetrics.headerHeight)
            Divider()
            if store.repoState != .clean { OperationBanner().padding(EdgeInsets(top: 12, leading: 16, bottom: 0, trailing: 16)) }
            if store.status.isEmpty {
                HostedListEmpty(symbol: "checkmark.circle", title: String(localized: "Working directory is clean"),
                                caption: String(localized: "Modified files appear here."))
            } else {
                files
            }
            Divider()
            CommitComposer()
        }
        .background(StudioStyle.surface)
    }

    private var files: some View {
        GeometryReader { geometry in
            SharedStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("Changed files").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 0)
                        FileViewToggle()
                    }
                    .frame(height: 28)
                    .padding(.bottom, 4)
                    FileSection(title: String(localized: "Conflicted"), count: store.status.conflicted.count,
                                actionTitle: String(localized: "Mark all as resolved"),
                                action: { Task { await store.stage(store.status.conflicted) } }) {
                        ChangeList(changes: store.status.conflicted, isSelected: isOpen,
                                   actionIcon: "checkmark.circle", actionHelp: String(localized: "Mark as resolved (stage)"),
                                   actionTitle: String(localized: "Mark as resolved"),
                                   onAction: { files in Task { await store.stage(files) } },
                                   onOpen: open) { c in
                            Button("Mark as resolved") { Task { await store.stage([c]) } }
                            Divider()
                            Button("Show in Finder") { store.revealInFinder(c) }
                        }
                    }
                    FileSection(title: String(localized: "Unstaged"), count: store.status.unstaged.count,
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
                    FileSection(title: String(localized: "Staged"), count: store.status.staged.count,
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
                }
                .frame(width: max(0, geometry.size.width - 32), alignment: .topLeading)
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
        }
    }

    private func isOpen(_ c: FileChange) -> Bool { store.diffSource == .working(c) }

    private func open(_ c: FileChange) { store.openDiff(.working(c)) }
}

/// A group of the working changes: its name in 12 pt semibold grey, a neutral count pill and one text button for the
/// whole group, then its files. A group after another keeps 10 pt above it.
private struct FileSection<Content: View>: View {
    @Environment(RepoStore.self) private var store
    let title: String
    let count: Int
    let actionTitle: String
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        if count > 0 {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(verbatim: title).font(.system(size: 12, weight: .semibold)).foregroundStyle(HostedList.caption).lineLimit(1)
                    StatusPill(title: String(count), symbol: nil, tone: .neutral)
                    Spacer(minLength: 0)
                    Button(actionTitle, action: action).buttonStyle(HostedListTextButtonStyle())
                        .fixedSize()
                        // a running git command blocks it; the tip names the command
                        .disabled(store.busy != nil).help(store.busy ?? "")
                }
                .frame(height: 28)
                // the rows' fill reaches past the column so their text lines up with the heading above
                SharedPane(id: title) { content }.padding(.horizontal, -8)
            }
            .padding(.bottom, 6)
        }
    }
}

/// A merge, rebase, cherry-pick or revert in progress: a white strip with a hairline (a tint means selection), what is
/// going on in the waiting tone, what to do next, and the way out and the way on.
private struct OperationBanner: View {
    @Environment(RepoStore.self) private var store

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SymbolIcon("exclamationmark.triangle.fill").font(.system(size: 14)).foregroundStyle(StudioStyle.Tone.waiting.text)
                .frame(height: 17).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: store.repoState.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(StudioStyle.Tone.waiting.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(store.status.conflicted.isEmpty
                     ? "All conflicts are resolved. Continue."
                     : "Fix the conflicted files in an editor, then click 'Mark as resolved'.")
                    .font(.system(size: 12)).foregroundStyle(HostedList.caption)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Abort…") { store.abortOperation() }.buttonStyle(HostedListButtonStyle())
                    Spacer(minLength: 0)
                    // the caption above is the reason while conflicts remain
                    Button("Continue") { Task { await store.continueOperation() } }
                        .hostedListFilledButton()
                        .disabled(!store.status.conflicted.isEmpty)
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.surface))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(StudioStyle.border))
        .accessibilityElement(children: .contain)
    }
}
