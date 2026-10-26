import SwiftUI

struct RebaseWorkbenchPanel: View {
    @Environment(RepoStore.self) private var store
    @ViewState private var base = "main"
    @ViewState private var start = ""
    @ViewState private var planning = false
    @ViewState private var error: String?
    @ViewState private var request = UUID()
    @ViewState private var planID = UUID()
    @ViewState private var comparing = false
    @ViewState private var preview: RebasePreview?
    @ViewState private var previewLoading = false
    @ViewState private var previewError: String?
    @ViewState private var previewRequest = UUID()
    private var previewKey: String { [store.url?.path ?? "", store.headHash ?? "", base, store.repoState == .clean ? "clean" : "busy"].joined(separator: "\0") }
    private var initialBase: String { RebasePreview.defaultBase(names: store.localBranches.map(\.name) + store.remoteBranches.map(\.name), current: store.headBranch, upstream: store.status.upstream) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Rebase").font(.title2.weight(.semibold))
                    Text("Move the current branch onto a new base, or review and reorder its commits.").font(.callout).foregroundStyle(.secondary)
                }
                WorkbenchFlow { Text("Current branch"); Text(store.headBranch ?? String(localized: "Detached HEAD")).fontWeight(.semibold).lineLimit(1).truncationMode(.middle) }
                if store.repoState != .clean {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("A Git operation is in progress.").fontWeight(.semibold)
                        Text("Resolve conflicts in Changes, then continue. Abort returns to the state before the operation.").font(.callout).foregroundStyle(.secondary)
                        HStack { Button("Continue") { Task { await store.continueOperation() } }; Button("Abort…") { store.abortOperation() } }.disabled(store.busy != nil)
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Change branch base").font(.headline)
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("New base revision", text: $base).textFieldStyle(.roundedBorder)
                            WorkbenchFlow {
                            Menu("Choose a branch or tag") {
                                ForEach(store.localBranches) { b in Button(b.name) { base = b.name } }
                                ForEach(store.remoteBranches) { b in Button(b.name) { base = b.name } }
                                ForEach(store.tags) { tag in Button(tag.name) { base = tag.name } }
                            }.fixedSize()
                            Button("Start rebase") { Task { await rebase() } }.disabled(!RepositoryBrowser.validRevision(base) || store.busy != nil || store.headBranch == nil || !store.status.isEmpty)
                            }
                        }
                    }.padding(16).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 9))
                    previewCard
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Clean up commit history").font(.headline)
                        Text("Choose the oldest commit to include. Review actions and execution order before starting.").font(.callout).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("First commit to include", text: $start).textFieldStyle(.roundedBorder)
                            WorkbenchFlow {
                            Menu("Choose a commit") { ForEach(store.entries.map(\.commit).filter { RepositoryBrowser.objectID($0.id) }.prefix(300)) { commit in Button(String(commit.id.prefix(8)) + " " + commit.subject) { start = commit.id } } }.fixedSize()
                            Button("Build cleanup plan") { Task { await prepare() } }.disabled(!RepositoryBrowser.validRevision(start) || planning || store.busy != nil || store.headBranch == nil)
                            }
                        }
                    }.padding(16).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 9))
                }
                if !store.status.isEmpty && store.repoState == .clean {
                    WorkbenchFlow { Label("Commit or stash working changes before starting rebase.", systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange); Button("Open Changes") { store.navigate(.repository); store.showArea(.changes) } }
                }
                if planning { ProgressView().controlSize(.small) }
                if let error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
                if store.rebasePlan != nil {
                    InteractiveRebaseSheet(embedded: true, onClose: { store.rebasePlan = nil }).id(planID)
                        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 9))
                }
                Text("After rebase, compare the branch with its base and check the rewritten commits before pushing. Push review checks the destination and any force push.").font(.callout).foregroundStyle(.secondary)
                Button("Compare branch with base") { store.historyTools.left = base; store.historyTools.right = "HEAD"; store.historyTools.useMergeBase = false; comparing = true; Task { await store.loadRevisionComparison() } }.disabled(!RepositoryBrowser.validRevision(base))
                if comparing { CompareRevisionsSheet(store: store, embedded: true).frame(minHeight: 330) }
            }.padding(22).frame(maxWidth: .infinity, alignment: .topLeading)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { base = initialBase }
            .task(id: previewKey) { await loadPreview() }
            .onChange(of: store.url) { _, _ in request = UUID(); base = initialBase; start = ""; error = nil; planning = false; comparing = false }
            .onDisappear { request = UUID(); previewRequest = UUID() }
    }
    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            WorkbenchFlow { Label("Rebase preview", systemImage: "arrow.triangle.branch").font(.headline); Text(store.headBranch ?? String(localized: "Detached HEAD")).font(.caption.monospaced()).lineLimit(1); Image(systemName: "arrow.right").foregroundStyle(.secondary); Text(base).font(.caption.monospaced()).lineLimit(1) }
            if previewLoading { HStack { ProgressView().controlSize(.small); Text("Reading branch summary…").font(.callout).foregroundStyle(.secondary) } }
            else if let preview {
                WorkbenchFlow { Text(verbatim: String(localized: "{0} commits to replay").replacingOccurrences(of: "{0}", with: preview.replay.formatted())).font(.callout.weight(.semibold)); Text(verbatim: String(localized: "{0} commits on the base only").replacingOccurrences(of: "{0}", with: preview.incoming.formatted())).font(.caption).foregroundStyle(.secondary) }
                if preview.replay == 0 { Text("No commits need to be replayed onto this base.").font(.callout).foregroundStyle(.secondary) }
                else {
                    Text("Select the oldest commit to include in a cleanup plan.").font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(preview.commits.prefix(6))) { commit in
                        Button { start = commit.id } label: { HStack(spacing: 10) { Image(systemName: start == commit.id ? "checkmark.circle.fill" : "circle").foregroundStyle(Color.accentColor); Text(String(commit.id.prefix(8))).font(.caption.monospaced()).foregroundStyle(.secondary); Text(commit.subject).font(.callout).lineLimit(2); Spacer(minLength: 0) }.padding(9).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 7).fill(start == commit.id ? Color.accentColor.opacity(0.12) : Color.clear)) }.buttonStyle(.plain)
                    }
                    if preview.replay > min(6, preview.commits.count) { Text("Showing the latest 6 candidate commits.").font(.caption).foregroundStyle(.secondary) }
                }
            } else if let previewError { Text(previewError).font(.callout).foregroundStyle(.secondary) }
            Text("This preview only reads history. Starting rebase still requires confirmation.").font(.caption).foregroundStyle(.secondary)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color.accentColor.opacity(0.04), in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.15)))
    }
    private func loadPreview() async {
        let token = UUID(); previewRequest = token; preview = nil; previewError = nil; previewLoading = false
        guard let url = store.url, store.repoState == .clean else { return }
        guard let head = store.headHash else { previewError = String(localized: "Commit at least once to preview rebase."); return }
        guard RepositoryBrowser.validRevision(base) else { previewError = String(localized: "Choose a valid base branch to preview its commits."); return }
        let onto = base; previewLoading = true
        do {
            try await Task.sleep(for: .milliseconds(250))
            let value = try await RebasePreview.load(in: url, base: onto, head: head)
            guard !Task.isCancelled, previewRequest == token, store.url == url, store.headHash == head, base == onto else { return }
            preview = value; if start.isEmpty { start = value.commits.prefix(6).last?.id ?? "" }
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
        let onto = base, original = store.headHash
        do {
            let target = try await Git.run(["rev-parse", "--verify", onto + "^{commit}"], in: url).output.trimmingCharacters(in: .whitespacesAndNewlines)
            let head = try await Git.run(["rev-parse", "--verify", "HEAD"], in: url).output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard store.url == url, request == token, RepositoryBrowser.objectID(target), original == head else { return }
            store.confirm = ConfirmRequest(title: String(localized: "Rebase the current branch?"), message: String(localized: "Commits from the current branch will be replayed onto '\(onto)'. Commit or stash your changes first. Review the result before pushing.") + "\n\n" + String(target.prefix(12)), actionTitle: String(localized: "Start rebase"), destructive: false) { [weak store] in
                guard let store, store.url == url, store.headHash == original, request == token else { return }
                do {
                    let currentHead = try await Git.run(["rev-parse", "--verify", "HEAD"], in: url).output.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard store.url == url, request == token, currentHead == head else { return }
                    await store.rebase(onto: target)
                } catch { if store.url == url && request == token { store.errorMessage = store.describe(error) } }
            }
        } catch { if store.url == url && request == token { self.error = store.describe(error) } }
    }
}
