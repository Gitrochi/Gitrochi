import Foundation

/// 두 시점 비교·그래프 일괄 작업·줄과 함수의 이력
extension RepoStore {
    func cancelHistoryTools() {
        historyTools.generation = UUID()
        historyTools.comparisonFileToken = UUID()
        historyTools.comparisonLoading = false
        historyTools.batchLoading = false
        historyTools.lineLoading = false
    }
    func selectGraphCommit(_ sha: String, extend: Bool = false, toggle: Bool = false) {
        let state = historyTools
        let oldAnchor = state.anchor
        let ids = entries.filter { !$0.commit.isPending }.map(\.id)
        var selected: [String]
        if extend, let anchor = state.anchor, let a = ids.firstIndex(of: anchor), let b = ids.firstIndex(of: sha) {
            let range = Array(ids[min(a,b)...max(a,b)])
            selected = toggle ? state.selected + range.filter { !state.selected.contains($0) } : range
        } else if toggle { selected = state.selected.contains(sha) ? state.selected.filter { $0 != sha } : state.selected + [sha] }
        else { selected = [sha] }
        select(.commit(sha))
        state.selected = selected
        state.anchor = extend ? oldAnchor : sha
    }
    func openRevisionComparison(left: String? = nil, right: String? = nil) {
        cancelHistoryTools()
        let state = historyTools
        state.left = left ?? (state.selected.count == 2 ? state.selected[1] : status.upstream ?? "HEAD~1")
        state.right = right ?? (state.selected.count == 2 ? state.selected[0] : "HEAD")
        state.comparison = nil; state.comparisonError = nil; state.comparisonPatch = ""
        sheet = .compareRevisions
    }
    private func resolveHistoryRevision(_ value: String, in url: URL) async throws -> String {
        guard HistoryTools.validRevision(value) else { throw HistoryToolsError.invalidRevision }
        let r = try await Git.run(["rev-parse", "--verify", "--end-of-options", value + "^{commit}"], in: url)
        let sha = r.output.trimmed
        guard HistoryTools.objectID(sha) else { throw HistoryToolsError.invalidRevision }
        return sha
    }
    func loadRevisionComparison() async {
        guard let url else { return }
        let state = historyTools, generation = UUID()
        state.generation = generation
        let leftInput = state.left, rightInput = state.right, useMergeBase = state.useMergeBase
        func current() -> Bool { self.url == url && state.generation == generation }
        state.comparisonLoading = true; state.comparisonError = nil; state.comparison = nil; state.comparisonPatch = ""
        defer { if current() { state.comparisonLoading = false } }
        do {
            async let leftRequest = resolveHistoryRevision(leftInput, in: url)
            async let rightRequest = resolveHistoryRevision(rightInput, in: url)
            let (left, right) = try await (leftRequest, rightRequest)
            let base = useMergeBase ? try await Git.run(["merge-base", left, right], in: url).output.trimmed : left
            guard HistoryTools.objectID(base) else { throw HistoryToolsError.invalidRevision }
            async let files = Git.run(["diff", "--no-ext-diff", "-M", "--name-status", "-z", base, right, "--"], in: url)
            async let stats = Git.run(["diff", "--no-ext-diff", "-M", "--numstat", "-z", base, right, "--"], in: url)
            let (filesResult, statsResult) = try await (files, stats)
            guard current() else { return }
            state.comparison = RevisionComparison(left: left, right: right, base: base, mergeBase: useMergeBase,
                                                  files: Parsers.nameStatus(filesResult.data), stats: Parsers.numstat(statsResult.data))
            if let first = state.comparison?.files.first { await selectComparisonFile(first) }
        } catch { if current() { state.comparisonError = describe(error) } }
    }
    func selectComparisonFile(_ file: FileChange) async {
        guard let url, let comparison = historyTools.comparison else { return }
        let state = historyTools, token = UUID()
        state.comparisonFileToken = token; state.comparisonPath = file.path; state.comparisonPatch = ""
        do {
            let r = try await Git.run(["diff", "--no-ext-diff", "--no-textconv", "-M", comparison.base, comparison.right, "--"] + file.paths, in: url)
            guard self.url == url, state.comparisonFileToken == token, state.comparison?.left == comparison.left, state.comparison?.right == comparison.right else { return }
            state.comparisonPatch = String(r.output.prefix(2_000_000))
            if r.output.count > 2_000_000 { state.comparisonPatch += "\n" + String(localized: "Output truncated. Narrow the selection.") }
        } catch { if self.url == url, state.comparisonFileToken == token { state.comparisonPatch = describe(error) } }
    }
    func openBatchCommits(_ action: BatchCommitAction = .cherryPick) async {
        guard let url, !historyTools.selected.isEmpty else { return }
        cancelHistoryTools()
        let state = historyTools, generation = state.generation
        func current() -> Bool { self.url == url && state.generation == generation }
        let chosen = Set(state.selected)
        state.batchAction = action; state.batch = []; state.batchError = nil; state.batchLoading = true
        sheet = .batchCommits
        defer { if current() { state.batchLoading = false } }
        do {
            let head = try await resolveHistoryRevision("HEAD", in: url)
            let branch = try await Git.run(["symbolic-ref", "--quiet", "HEAD"], in: url).output.trimmed
            let ordered = entries.filter { chosen.contains($0.id) }.map(\.id).reversed()
            guard ordered.count == chosen.count else { throw HistoryToolsError.changed }
            var records: [BatchCommitItem] = []
            for sha in ordered {
                let r = try await Git.run(["show", "--no-patch", "--format=%H%x1f%P%x1f%an%x1f%B", sha], in: url)
                let fields = r.output.trimmingCharacters(in: .newlines).components(separatedBy: "\u{1f}")
                guard fields.count >= 4, HistoryTools.objectID(fields[0]) else { throw HistoryToolsError.invalidRevision }
                let message = fields.dropFirst(3).joined(separator: "\u{1f}")
                records.append(BatchCommitItem(sha: fields[0], parents: fields[1].split(separator: " ").map(String.init), subject: message.components(separatedBy: "\n").first ?? "", author: fields[2], message: message))
            }
            guard current() else { return }
            state.batchHead = head; state.batchBranch = branch
            state.batch = action == .revert ? Array(records.reversed()) : records
            if records.contains(where: { $0.parents.count > 1 }) { state.batchError = HistoryToolsError.merge.localizedDescription }
        } catch { if current() { state.batchError = describe(error) } }
    }
    func executeBatchCommits() async {
        guard let url, busy == nil else { return }
        let state = historyTools, generation = state.generation
        guard !state.batchLoading, state.batchError == nil, !state.batch.isEmpty else { return }
        func current() -> Bool { self.url == url && state.generation == generation }
        state.batchLoading = true
        defer { if current() { state.batchLoading = false } }
        do {
            async let headRequest = resolveHistoryRevision("HEAD", in: url)
            async let branchRequest = Git.run(["symbolic-ref", "--quiet", "HEAD"], in: url)
            async let statusRequest = Git.run(["status", "--porcelain=v1", "--untracked-files=normal"], in: url)
            let (head, branch, statusResult) = try await (headRequest, branchRequest, statusRequest)
            guard current() else { return }
            guard head == state.batchHead, branch.output.trimmed == state.batchBranch else { throw HistoryToolsError.changed }
            guard statusResult.output.isEmpty, repoState == .clean, !HistoryTools.operationInProgress(gitDir) else { throw HistoryToolsError.dirty }
            guard !state.batch.contains(where: { $0.parents.count > 1 }) else { throw HistoryToolsError.merge }
            if state.batchAction == .squash || state.batchAction == .drop {
                let selected = Set(state.batch.map(\.sha))
                guard let first = state.batch.first(where: { Set($0.parents).isDisjoint(with: selected) }) else { throw HistoryToolsError.invalidRevision }
                rebasePlan = nil
                await startInteractiveRebase(from: first.sha, present: false)
                guard current() else { return }
                guard var plan = rebasePlan else { throw HistoryToolsError.changed }
                let indexes = plan.items.indices.filter { selected.contains(plan.items[$0].sha) }
                guard indexes.count == selected.count else { throw HistoryToolsError.changed }
                if state.batchAction == .squash {
                    guard selected.count > 1, let firstIndex = indexes.first, let lastIndex = indexes.last,
                          lastIndex - firstIndex + 1 == selected.count else { throw HistoryToolsError.noncontiguous }
                    for index in indexes where index != lastIndex { plan.items[index].action = .squash }
                } else {
                    for index in indexes { plan.items[index].action = .drop }
                }
                plan.expectedHead = head
                rebasePlan = plan
                sheet = .interactiveRebase
            } else {
                let backup = "refs/gitrochi/batch/" + UUID().uuidString.lowercased()
                try await Git.run(["update-ref", "--create-reflog", backup, head, ""], in: url)
                guard current() else { return }
                sheet = nil
                let args = state.batchAction == .cherryPick ? ["cherry-pick"] : ["revert", "--no-edit"]
                await run(String(localized: "Applying selected commits…"), args + state.batch.map(\.sha))
            }
        } catch { if current() { state.batchError = describe(error); sheet = .batchCommits } }
    }
    func openLineHistory(path: String? = nil, revision: String? = nil, start: Int = 1, end: Int? = nil) {
        cancelHistoryTools()
        let state = historyTools
        state.linePath = path ?? fileInspect?.path ?? diffSource?.change.path ?? ""
        var selectedRevision: String?
        if case .commit(let sha, _, _)? = diffSource { selectedRevision = sha }
        state.lineRevision = revision ?? fileInspect?.rev ?? selectedRevision ?? "HEAD"
        state.lineStart = start; state.lineEnd = end ?? start; state.functionName = ""
        state.lineEntries = []; state.lineError = nil; state.lineTruncated = false
        sheet = .lineHistory
    }
    func openSelectedLineHistory() {
        guard let source = diffSource else { return }
        let selected = diff?.lines.filter { diffSelection.contains($0.id) } ?? []
        let lines = diffSelection.isEmpty ? [] : selected
        var path = source.change.path
        var revision: String?
        let newNumbers = lines.compactMap(\.newNo)
        var numbers = newNumbers.isEmpty ? lines.compactMap(\.oldNo) : newNumbers
        if case .commit(let sha, let change, let parent) = source {
            revision = sha
            if !lines.isEmpty, newNumbers.isEmpty {
                revision = parent
                path = change.oldPath ?? change.path
                numbers = lines.compactMap(\.oldNo)
            }
        }
        openLineHistory(path: path, revision: revision, start: numbers.min() ?? 1, end: numbers.max() ?? 1)
    }
    func loadLineHistory() async {
        guard let url else { return }
        let state = historyTools, generation = UUID()
        state.generation = generation
        func current() -> Bool { self.url == url && state.generation == generation }
        state.lineLoading = true; state.lineError = nil; state.lineEntries = []
        defer { if current() { state.lineLoading = false } }
        do {
            let range = try HistoryTools.range(path: state.linePath, start: state.lineStart, end: state.lineEnd, function: state.functionName)
            let sha = try await resolveHistoryRevision(state.lineRevision, in: url)
            let r = try await Git.run(["log", "--no-ext-diff", "--no-textconv", "--max-count=200", "--date=short", "--format=%x1e%H%x1f%an%x1f%ad%x1f%s", "-L", range, sha, "--"], in: url, timeout: 120)
            guard current() else { return }
            state.lineTruncated = r.output.count > 2_000_000
            state.lineEntries = HistoryTools.lineHistory(String(r.output.prefix(2_000_000)))
            state.lineSelected = state.lineEntries.first?.sha
        } catch { if current() { state.lineError = describe(error) } }
    }
}
