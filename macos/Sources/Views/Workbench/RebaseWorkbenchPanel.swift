import SwiftUI

/// The Rebase page, as the redesign's Rebase board draws it: choose the new base in a list column, then review the
/// commits that replay and start. "Clean up history" chooses the oldest commit to include instead and builds the plan.
/// (Windows: widgets/local-workbench/ui/LocalWorkbench.tsx)
struct RebaseWorkbenchPanel: View {
    private enum Mode { case move, cleanup }

    @Environment(RepoStore.self) private var store
    @ViewState private var mode = Mode.move
    @ViewState private var base = ""
    @ViewState private var search = ""
    @ViewState private var bases: [RebaseBase] = []
    /// Stash uncommitted changes for the rebase and restore them after
    @ViewState private var stash = false
    /// Clean up history: the oldest commit to include
    @ViewState private var start = ""
    @ViewState private var planning = false
    @ViewState private var error: String?
    @ViewState private var request = UUID()
    @ViewState private var planID = UUID()
    @ViewState private var preview: RebasePreview?
    @ViewState private var previewLoading = false
    @ViewState private var previewError: String?
    @ViewState private var previewRequest = UUID()
    @ViewState private var hovered: String?

    private var previewKey: String { [store.url?.path ?? "", store.headHash ?? "", base, store.repoState == .clean ? "clean" : "busy"].joined(separator: "\0") }
    private var basesKey: String { [store.url?.path ?? "", store.headHash ?? "", String(store.localBranches.count + store.remoteBranches.count + store.tags.count)].joined(separator: "\0") }
    private var initialBase: String { RebasePreview.defaultBase(names: store.localBranches.map(\.name) + store.remoteBranches.map(\.name), current: store.headBranch, upstream: store.status.upstream) }
    private var dirty: Bool { !store.status.isEmpty }
    private var chosen: RebaseBase? { bases.first { $0.name == base } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.repoState != .clean {
                operation
            } else {
                HStack(spacing: 0) {
                    listColumn
                        .frame(width: 312)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .background(StudioStyle.canvas)
                    Divider()
                    ScrollView {
                        detail
                            .padding(EdgeInsets(top: 16, leading: 24, bottom: 32, trailing: 24))
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { if base.isEmpty { base = initialBase } }
        .task(id: basesKey) { await loadBases() }
        .task(id: previewKey) { await loadPreview() }
        .onChange(of: store.url) { _, _ in request = UUID(); base = initialBase; start = ""; error = nil; planning = false; search = "" }
        .onDisappear { request = UUID(); previewRequest = UUID() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Text(store.headBranch ?? String(localized: "Detached HEAD")).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                Text(verbatim: "→").foregroundStyle(StudioStyle.Rail.icon).accessibilityHidden(true)
                Text(mode == .cleanup ? String(localized: "Clean up history") : base.isEmpty ? String(localized: "choose a new base") : base)
                    .foregroundStyle(StudioStyle.Rail.icon).lineLimit(1).truncationMode(.middle)
            }
            .font(.system(size: 13))
            Spacer(minLength: 12)
            Picker("Rebase mode", selection: $mode) {
                Text("Move onto another branch").tag(Mode.move)
                Text("Clean up history").tag(Mode.cleanup)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
        .padding(.leading, 12).padding(.trailing, 20)
        .frame(height: 44)
    }

    // MARK: List column

    @ViewBuilder private var listColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            if mode == .move {
                stepTitle(1, "Choose the new base")
                caption("Replays this branch's commits on top of a new base, as if the branch had started there.")
                HStack(spacing: 6) {
                    DesignIconImage(icon: .search, size: 12).foregroundStyle(StudioStyle.Rail.icon)
                    TextField("Search branches and tags", text: $search).textFieldStyle(.plain).font(.system(size: 13))
                }
                .padding(.horizontal, 10).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.surface))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.16)))
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(bases.filter { RebaseBase.matches($0, search: search) }) { option($0) }
                    }
                }
                .accessibilityLabel("New base")
            } else {
                stepTitle(1, "First commit to include")
                caption("Choose the oldest commit to include. Review actions and execution order before starting.")
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(cleanupCommits) { commit in
                            row(id: commit.id, selected: start == commit.id, disabled: false) {
                                Text(String(commit.id.prefix(7))).font(.system(size: 11, design: .monospaced)).foregroundStyle(StudioStyle.Rail.icon)
                                Text(commit.subject).lineLimit(1).fontWeight(start == commit.id ? .semibold : .regular)
                                Spacer(minLength: 0)
                            } action: { start = commit.id }
                        }
                    }
                }
            }
        }
        .padding(EdgeInsets(top: 16, leading: 12, bottom: 20, trailing: 12))
    }

    /// The commits this branch has on top of the chosen base, or its latest ones when there is no base to compare with
    private var cleanupCommits: [RebasePreview.Commit] {
        if let preview, !preview.commits.isEmpty { return preview.commits }
        return store.entries.map(\.commit).filter { RepositoryBrowser.objectID($0.id) }.prefix(30).map { RebasePreview.Commit(id: $0.id, subject: $0.subject, date: $0.date) }
    }

    private func option(_ option: RebaseBase) -> some View {
        let selected = option.name == base, disabled = option.incoming == 0
        return row(id: option.id, selected: selected, disabled: disabled) {
            Image(systemName: option.kind == .remote ? "cloud" : option.kind == .tag ? "tag" : "arrow.triangle.branch")
                .font(.system(size: 12)).foregroundStyle(disabled ? StudioStyle.Rail.blocked : StudioStyle.Rail.icon).frame(width: 14)
            // only the name dims; the reason beside it stays readable
            Text(option.name).lineLimit(1).truncationMode(.middle).fontWeight(selected ? .semibold : .regular)
                .foregroundStyle(disabled ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            Spacer(minLength: 8)
            if let incoming = option.incoming {
                Text(incoming == 0 ? String(localized: "Already in this branch") : String(localized: "\(incoming) new commits"))
                    .font(.system(size: 12)).foregroundStyle(StudioStyle.Rail.icon).lineLimit(1).fixedSize()
            }
        } action: { base = option.name }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func row<Content: View>(id: String, selected: Bool, disabled: Bool, @ViewBuilder content: () -> Content, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) { content() }
                .font(.system(size: 13))
                .padding(.horizontal, 10).frame(height: 28)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(selected ? StudioStyle.selection : hovered == id && !disabled ? StudioStyle.hover : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovered = $0 ? id : (hovered == id ? nil : hovered) }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            if mode == .move {
                step(2, "Review the commits") { review }
                step(3, "Start", last: true) { startControls }
            } else {
                step(2, "Clean up commit history", last: true) {
                    HStack(spacing: 8) {
                        Button("Build cleanup plan") { Task { await prepare() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(!RepositoryBrowser.validRevision(start) || planning || store.busy != nil || store.headBranch == nil)
                        if planning { ProgressView().controlSize(.small) }
                    }
                    if let error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
                    if store.rebasePlan != nil {
                        InteractiveRebaseSheet(embedded: true, onClose: { store.rebasePlan = nil }).id(planID)
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(StudioStyle.border))
                    }
                }
            }
        }
    }

    @ViewBuilder private var review: some View {
        if previewLoading {
            HStack(spacing: 6) { ProgressView().controlSize(.small); caption("Reading branch summary…") }
        } else if let preview {
            if preview.replay == 0 {
                caption("No commits need to be replayed onto this base.")
            } else {
                Text("\(preview.replay) commits replay on top of \(base), newest first.").font(.system(size: 12)).foregroundStyle(StudioStyle.Rail.icon)
                VStack(spacing: 0) {
                    ForEach(preview.commits) { commit in
                        HStack(spacing: 10) {
                            Text(String(commit.id.prefix(7))).font(.system(size: 11, design: .monospaced)).foregroundStyle(StudioStyle.Rail.icon).frame(width: 56, alignment: .leading)
                            Text(commit.subject).font(.system(size: 13)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            if let date = commit.date { Text(Fmt.short(date)).font(.system(size: 12)).foregroundStyle(StudioStyle.Rail.icon).fixedSize() }
                        }
                        .padding(.horizontal, 12).frame(height: 28)
                    }
                }
                .padding(.vertical, 4)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(StudioStyle.border))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Commits to replay")
            }
        } else if let previewError {
            caption(previewError)
        } else {
            caption("Choose a base to see the commits that replay.")
        }
    }

    /// Why Start is disabled, when uncommitted changes are the reason
    private var blocked: String? {
        dirty && !stash ? String(localized: "\(store.status.count) uncommitted files. Stash them above or commit first.") : nil
    }

    @ViewBuilder private var startControls: some View {
        Toggle("Stash uncommitted changes and restore them after", isOn: $stash).toggleStyle(.checkbox).font(.system(size: 13))
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button("Start rebase") { Task { await rebase() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!RepositoryBrowser.validRevision(base) || chosen?.incoming == 0 || preview?.replay == 0 || store.busy != nil || store.headBranch == nil || blocked != nil)
                Button("Open changes") { store.navigate(.repository); store.showArea(.changes) }
            }
            if let blocked {
                // the icon and the sentence carry the warning, not the colour alone
                Label(blocked, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(StudioStyle.Tone.waiting.text)
            }
        }
        if let error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
        caption("Conflicts pause the rebase until you continue or abort, and a finished rebase can be undone.")
    }

    private var operation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("A Git operation is in progress.").font(.system(size: 15, weight: .semibold))
            caption("Resolve conflicts in Changes, then continue. Abort returns to the state before the operation.")
            HStack(spacing: 8) {
                Button("Continue") { Task { await store.continueOperation() } }.buttonStyle(.borderedProminent)
                Button("Abort…") { store.abortOperation() }
            }
            .disabled(store.busy != nil)
        }
        .padding(EdgeInsets(top: 16, leading: 24, bottom: 32, trailing: 24))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Parts

    private func caption(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(StudioStyle.Rail.icon).fixedSize(horizontal: false, vertical: true)
    }

    private func caption(_ text: String) -> some View {
        Text(verbatim: text).font(.system(size: 12)).foregroundStyle(StudioStyle.Rail.icon).fixedSize(horizontal: false, vertical: true)
    }

    private func number(_ value: Int) -> some View {
        Text(verbatim: String(value)).font(.system(size: 12, weight: .semibold)).foregroundStyle(StudioStyle.Tone.neutral.text)
            .frame(width: 22, height: 22).background(Circle().fill(StudioStyle.Tone.neutral.fill)).accessibilityHidden(true)
    }

    private func stepTitle(_ value: Int, _ title: LocalizedStringKey) -> some View {
        HStack(spacing: 10) {
            number(value)
            Text(title).font(.system(size: 15, weight: .semibold))
        }
    }

    /// A numbered step: its number with a line down to the next one, and its title and content beside them
    private func step<Content: View>(_ value: Int, _ title: LocalizedStringKey, last: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 6) {
                number(value)
                if !last { Rectangle().fill(StudioStyle.border).frame(width: 2).frame(maxHeight: .infinity) }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.system(size: 15, weight: .semibold)).frame(minHeight: 22)
                content()
            }
            .padding(.bottom, last ? 0 : 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Reading and starting

    private func loadBases() async {
        guard let url = store.url else { bases = []; return }
        let current = store.headBranch
        if let output = try? await Git.run(RebaseBase.listArgs, in: url).output {
            guard !Task.isCancelled, store.url == url else { return }
            bases = RebaseBase.parse(output, current: current)
        } else {
            // an older Git has no ahead-behind: the names without their counts
            guard !Task.isCancelled, store.url == url else { return }
            bases = store.localBranches.filter { $0.name != current }.map { RebaseBase(name: $0.name, kind: .branch, incoming: nil) }
                + store.remoteBranches.map { RebaseBase(name: $0.name, kind: .remote, incoming: nil) }
                + store.tags.map { RebaseBase(name: $0.name, kind: .tag, incoming: nil) }
        }
    }

    private func loadPreview() async {
        let token = UUID(); previewRequest = token; preview = nil; previewError = nil; previewLoading = false
        guard let url = store.url, store.repoState == .clean else { return }
        guard let head = store.headHash else { previewError = String(localized: "Commit at least once to preview rebase."); return }
        guard !base.isEmpty else { return }
        guard RepositoryBrowser.validRevision(base) else { previewError = String(localized: "Choose a valid base branch to preview its commits."); return }
        let onto = base; previewLoading = true
        do {
            try await Task.sleep(for: .milliseconds(250))
            let value = try await RebasePreview.load(in: url, base: onto, head: head)
            guard !Task.isCancelled, previewRequest == token, store.url == url, store.headHash == head, base == onto else { return }
            preview = value; if start.isEmpty { start = value.commits.last?.id ?? "" }
        } catch { if !Task.isCancelled && previewRequest == token && store.url == url { previewError = String(localized: "The branch summary could not be read. Refresh and try again.") } }
        if previewRequest == token { previewLoading = false }
    }

    private func prepare() async {
        guard let url = store.url, RepositoryBrowser.validRevision(start) else { return }
        let token = UUID(); request = token; planning = true; error = nil
        do {
            let sha = try await Git.run(["rev-parse", "--verify", start + "^{commit}"], in: url).output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard request == token, store.url == url, RepositoryBrowser.objectID(sha) else { return }
            await store.startInteractiveRebase(from: sha, present: false)
            guard request == token, store.url == url else { return }
            planID = UUID()
        } catch { if request == token && store.url == url { self.error = store.describe(error) } }
        if request == token && store.url == url { planning = false }
    }

    private func rebase() async {
        guard let url = store.url, RepositoryBrowser.validRevision(base), store.busy == nil else { return }
        let token = UUID(); request = token
        let onto = base, original = store.headHash, autostash = stash && dirty
        do {
            let target = try await Git.run(["rev-parse", "--verify", onto + "^{commit}"], in: url).output.trimmingCharacters(in: .whitespacesAndNewlines)
            let head = try await Git.run(["rev-parse", "--verify", "HEAD"], in: url).output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard store.url == url, request == token, RepositoryBrowser.objectID(target), original == head else { return }
            store.confirm = ConfirmRequest(title: String(localized: "Rebase the current branch?"), message: String(localized: "Commits from the current branch will be replayed onto '\(onto)'. Commit or stash your changes first. Review the result before pushing.") + "\n\n" + String(target.prefix(12)), actionTitle: String(localized: "Start rebase"), destructive: false) { [weak store] in
                guard let store, store.url == url, store.headHash == original, request == token else { return }
                do {
                    let currentHead = try await Git.run(["rev-parse", "--verify", "HEAD"], in: url).output.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard store.url == url, request == token, currentHead == head else { return }
                    await store.rebase(onto: target, autostash: autostash)
                } catch { if store.url == url && request == token { store.errorMessage = store.describe(error) } }
            }
        } catch { if store.url == url && request == token { self.error = store.describe(error) } }
    }
}
