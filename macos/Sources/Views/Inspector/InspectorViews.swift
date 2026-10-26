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
            ScrollView {
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
                    if store.status.isEmpty {
                        Card {
                            Label("Working directory is clean", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Modified files appear here.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(12)
            }
            Divider()
            CommitComposer()
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Uncommitted changes").font(.title3.weight(.semibold))
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                    Text(store.headBranch ?? String(localized: "Detached HEAD"))
                    if store.status.ahead > 0 { Text("↑\(store.status.ahead)") }
                    if store.status.behind > 0 { Text("↓\(store.status.behind)") }
                    if !store.status.isEmpty {
                        let total = totals
                        Text("·")
                        Text("\(store.status.count) files")
                        if total.added + total.deleted > 0 { LineStatText(added: total.added, deleted: total.deleted) }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            FileViewToggle()
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
    let title: String
    let color: Color
    let count: Int
    let actionTitle: String
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        if count > 0 {
            Card(spacing: 4) {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 7, height: 7)
                    Text(title).font(.subheadline.weight(.semibold))
                    Text("\(count)").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Button(actionTitle, action: action).buttonStyle(.link).font(.caption)
                }
                .padding(.bottom, 4)
                content
            }
        }
    }
}

private struct OperationBanner: View {
    @Environment(RepoStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(store.repoState.title, systemImage: "exclamationmark.triangle.fill")
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

struct CommitComposer: View {
    @Environment(RepoStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let me = store.me {
                    AuthorAvatar(name: me.name, email: me.email, size: 22)
                        .help("\(me.name) <\(me.email)>")
                }
                Text("Commit").font(.headline)
                Spacer()
                Button { Task { await store.planSplit() } } label: {
                    Label("Split into commits", systemImage: "square.stack.3d.up")
                }
                .controlSize(.small)
                .disabled(store.splittableChanges.count < 2 || store.aiWorking != nil || !store.status.conflicted.isEmpty)
                .help("\(AIStore.shared.short(for: .commit)) groups the changed files by topic and splits them into several commits. Review and edit the result, then commit. Rules are in Settings > Rules.")
                Button { Task { await store.generateCommitMessage() } } label: {
                    if store.aiWorking != nil {
                        HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Working") }
                    } else {
                        Label("Write with \(AIStore.shared.short(for: .commit))", systemImage: "sparkles")
                    }
                }
                .controlSize(.small)
                .disabled(store.status.staged.isEmpty || store.aiWorking != nil)
                .help("\(AIStore.shared.provider.title) writes a commit message from the staged changes (⌥⌘M). Change the AI in Settings > AI.")
            }
            GitchBar()
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    TextField("Summary (required)", text: $store.summary)
                        .textFieldStyle(.plain)
                        .font(.body.weight(.medium))
                    Text("\(store.summary.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(store.summary.count > 72 ? Color.orange : Color.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                Divider()
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $store.message)
                        .font(.callout)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 4)
                    if store.message.isEmpty {
                        Text("Description (optional)")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 70)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))

            if let working = store.aiWorking {
                HStack(spacing: 4) { ProgressView().controlSize(.mini); Text(working) }
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let notice = store.aiNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Toggle("Amend previous commit", isOn: Binding(get: { store.amend },
                                                  set: { v in Task { await store.setAmend(v) } }))
                    .toggleStyle(.checkbox)
                    .disabled(store.headHash == nil)
                    .help("Amend: combine into the last commit")
                Spacer()
                Button {
                    Task { await store.commit() }
                } label: {
                    Text(buttonTitle).frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!store.canCommit)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var buttonTitle: String {
        if store.amend { return String(localized: "Amend previous commit") }
        if store.repoState == .merging { return String(localized: "Merge commit") }
        let n = store.status.staged.count
        return n == 0 ? String(localized: "No staged files") : String(localized: "Commit \(n) files  ⌘↩")
    }
}

// MARK: - 커밋 상세

struct CommitDetailView: View {
    @Environment(RepoStore.self) private var store
    let sha: String
    @ViewState private var bodyExpanded = false

    var body: some View {
        if let d = store.detail, d.sha == sha {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: d.parents.count > 1 ? "arrow.triangle.merge" : "smallcircle.filled.circle")
                        .foregroundStyle(.secondary)
                    Text(d.parents.count > 1 ? "Merge commit" : "Commit").font(.headline)
                    Text(String(d.sha.prefix(8))).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                    Spacer()
                    Text(Fmt.short(d.commitDate)).font(.callout).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        message(d)
                        people(d)
                        claude
                        files(d)
                    }
                    .padding(12)
                }
                .id(sha)   // 다른 커밋을 고르면 맨 위부터 보이게
            }
            .background(Color(nsColor: .windowBackgroundColor))
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private func message(_ d: CommitDetail) -> some View {
        Card {
            let refs = store.refsByCommit[sha] ?? []
            if !refs.isEmpty {
                let tint = store.commitIndex[sha].map { Palette.lane(store.entries[$0].row.color) } ?? .accentColor
                HStack(spacing: 4) {
                    ForEach(refs.prefix(4)) { RefBadge(label: $0, color: tint) }
                    if refs.count > 4 { Text("+\(refs.count - 4)").font(.caption2).foregroundStyle(.secondary) }
                }
            }
            Text(d.summary)
                .font(.system(size: 15, weight: .semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !d.body.isEmpty {
                let long = d.body.count > 400 || d.body.filter { $0 == "\n" }.count > 8
                let collapsed = long && !bodyExpanded
                MarkdownView(d.body, target: store.target)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxHeight: collapsed ? 160 : nil, alignment: .top)
                    .clipped()
                    .mask { LinearGradient(stops: [.init(color: .black, location: collapsed ? 0.7 : 1), .init(color: collapsed ? .clear : .black, location: 1)], startPoint: .top, endPoint: .bottom) }
                if long {
                    Button(bodyExpanded ? "Collapse" : "Show all") { bodyExpanded.toggle() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
    }

    private func people(_ d: CommitDetail) -> some View {
        Card {
            HStack(spacing: 10) {
                AuthorAvatar(name: d.author, email: d.email, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(d.author).fontWeight(.semibold)
                    Text(d.email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Fmt.short(d.date)).font(.callout)
                    Text(Fmt.long(d.date)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if d.committer != d.author || abs(d.commitDate.timeIntervalSince(d.date)) > 60 {
                Label(d.committer == d.author ? "Commit: \(Fmt.long(d.commitDate))" : "Commit: \(d.committer) · \(Fmt.long(d.commitDate))",
                      systemImage: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            HStack(spacing: 6) {
                Pill(text: String(d.sha.prefix(8)), icon: "number") { store.copy(d.sha) }
                    .help("Copy full SHA")
                if !d.parents.isEmpty {
                    Image(systemName: "arrow.left").font(.caption2).foregroundStyle(.tertiary)
                    ForEach(d.parents, id: \.self) { p in
                        Pill(text: String(p.prefix(7)), icon: d.parents.count > 1 ? "arrow.triangle.merge" : nil) { store.reveal(p) }
                            .help("Go to parent commit")
                    }
                }
                Spacer()
            }
        }
    }

    private var claude: some View {
        Card {
            HStack {
                Label("\(AIStore.shared.short(for: .explain)) explanation", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Spacer()
                if store.explaining.contains(sha) {
                    HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Loading").font(.caption) }
                } else {
                    Button(store.explanations[sha] == nil ? "Explain this commit" : "Explain again") {
                        Task { await store.explainCommit(sha) }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
            if let text = store.explanations[sha] {
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func files(_ d: CommitDetail) -> some View {
        Card(spacing: 6) {
            let stats = store.detailStats.values
            let added = stats.compactMap(\.added).reduce(0, +)
            let deleted = stats.compactMap(\.deleted).reduce(0, +)
            HStack(spacing: 8) {
                Text("Changed files").font(.subheadline.weight(.semibold))
                Text("\(store.detailFiles.count)").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                FileViewToggle()
            }
            if added + deleted > 0 {
                HStack(spacing: 8) {
                    LineStatText(added: added, deleted: deleted)
                    ChangeBar(added: added, deleted: deleted)
                    Spacer()
                }
                .padding(.bottom, 4)
            }
            ChangeList(changes: store.detailFiles,
                       isSelected: { store.diffSource == .commit(sha: sha, change: $0, parent: d.parents.first) },
                       stats: store.detailStats,
                       onOpen: { store.openDiff(.commit(sha: sha, change: $0, parent: d.parents.first)) }) { f in
                Button("File history") { store.openFileHistory(f.path) }
                Button("Show blame at this commit") { store.openBlame(f.path, rev: sha) }.disabled(f.kind == .deleted)
                Divider()
                Button("Show in Finder") { store.revealInFinder(f) }
                Button("Copy path") { store.copy(f.path) }
            }
        }
    }
}

/// 작은 둥근 버튼(SHA·부모 커밋)
private struct Pill: View {
    let text: String
    var icon: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let icon { Image(systemName: icon).font(.system(size: 9, weight: .semibold)) }
                Text(text).font(.system(size: 11, design: .monospaced))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}
