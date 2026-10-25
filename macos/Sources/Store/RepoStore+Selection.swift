import SwiftUI
import AppKit

/// 선택한 커밋·작업 영역의 상세와 diff
extension RepoStore {
    // MARK: - 선택

    func showArea(_ destination: Area) {
        guard destination != area else { return }
        if destination == .history, case .commit(let sha)? = historySelection,
           commitIndex[sha] == nil && !stashes.contains(where: { $0.hash == sha }) {
            historySelection = nil
            historyDiff = nil
            historyInspect = nil
        }
        select(destination == .changes ? .wip : historySelection ?? headHash.map { .commit($0) }, restoringContext: true)
    }

    func select(_ sel: Selection?, restoringContext: Bool = false) {
        let destination: Area = sel == .wip ? .changes : .history
        let switching = destination != area
        if switching {
            if area == .changes {
                changesDiff = diffSource
                changesInspect = fileInspect
            } else {
                historySelection = selection
                historyDiff = diffSource
                historyInspect = fileInspect
            }
            closeFileInspect()
            area = destination
        }
        guard sel != selection else { return }
        closeFileInspect()
        selection = sel
        closeDiff()
        detailTask?.cancel()
        detail = nil
        detailFiles = []
        detailStats = [:]
        if switching, restoringContext || sel == .wip {
            let source = destination == .changes ? changesDiff : historyDiff
            if case .working(let old)? = source {
                let files = status.staged + status.unstaged + status.conflicted
                if let current = files.first(where: { $0.path == old.path && $0.staged == old.staged }) ?? files.first(where: { $0.path == old.path }) {
                    openDiff(.working(current))
                }
            } else if let source { openDiff(source) }
            if let inspect = destination == .changes ? changesInspect : historyInspect {
                fileInspect = inspect
                Task { await loadFileInspect() }
            }
        }
        guard case .commit(let sha)? = sel, let url else { return }
        let empty = emptyTree
        detailTask = Task {
            do {
                let show = try await Git.run(["show", "-s", "--format=" + Parsers.detailFormat, sha], in: url)
                let d = Parsers.commitDetail(show.output)
                let base = d?.parents.first ?? empty
                async let filesR = Git.run(["diff-tree", "-r", "-M", "--name-status", "-z", base, sha], in: url)
                async let numR = Git.run(["diff-tree", "-r", "-M", "--numstat", "-z", base, sha], in: url)
                let (files, num) = try await (filesR, numR)
                guard !Task.isCancelled, self.selection == .commit(sha) else { return }
                self.detail = d
                self.detailFiles = Parsers.nameStatus(files.data)
                self.detailStats = Parsers.numstat(num.data)
            } catch {
                guard !Task.isCancelled else { return }
                self.errorMessage = describe(error)
            }
        }
    }

    /// 사이드바에서 브랜치·태그를 누르면 그래프에서 해당 커밋을 찾아 보여 준다.
    func reveal(_ sha: String) {
        if commitIndex[sha] != nil || stashes.contains(where: { $0.hash == sha }) {
            select(.commit(sha))
            scrollTarget = sha
        } else if busy == nil {
            Task { await revealLoadingHistory(sha) }
        }
    }

    /// 그래프에 아직 없는 오래된 커밋이면 기록을 더 불러와(2000 → 8000 → …) 찾아 보여 준다.
    private func revealLoadingHistory(_ sha: String) async {
        busy = String(localized: "Loading earlier history…")
        while commitIndex[sha] == nil, hasMore, limit < 1_000_000 {
            limit *= 4
            await reload()
        }
        busy = nil
        if commitIndex[sha] != nil {
            select(.commit(sha))
            scrollTarget = sha
        } else {
            errorMessage = String(localized: "This commit is in history that isn't shown in the graph.")
        }
    }

    func moveSelection(_ delta: Int) {
        guard !entries.isEmpty else { return }
        let first = entries.startIndex
        let current: Int
        switch selection {
        case .wip?: current = commitIndex[Commit.wipID] ?? -1
        case .worktree(let p)?: current = commitIndex[Commit.worktreeWIP(path: p, parent: "").id] ?? -1
        case .commit(let s)?: current = commitIndex[s] ?? -1
        case .pullRequest?, nil: current = -1
        }
        let next = max(first, min(entries.count - 1, current + delta))
        let e = entries[next]
        select(e.commit.rowSelection)
        scrollTarget = e.id
    }

    // MARK: - Diff

    func openDiff(_ source: DiffSource) {
        if case .working = source, area != .changes { showArea(.changes) }
        if fileInspect != nil { closeFileInspect() }
        guard source != diffSource else { return }
        diffSource = source
        diffSelection = []
        diffSelectionAnchor = nil
        loadDiff(keepCurrent: false)
    }

    func closeDiff() {
        diffTask?.cancel()
        diffSource = nil
        diff = nil
        diffImages = nil
        diffSelection = []
        diffLoading = false
    }

    func loadDiff(keepCurrent: Bool) {
        diffTask?.cancel()
        guard let source = diffSource, let url else { diff = nil; return }
        if !keepCurrent { diff = nil; diffImages = nil }
        diffLoading = true
        let empty = emptyTree
        let ws = diffIgnoreWhitespace ? ["-w"] : []
        diffTask = Task {
            var args: [String]
            var ok: Set<Int32> = [0]
            var dir = url
            switch source {
            case .working(let c):
                if c.kind == .untracked {
                    args = ["diff", "--no-index", "--no-ext-diff"] + ws + ["--", "/dev/null", c.path]
                    ok = [0, 1]
                } else if c.staged {
                    args = ["diff", "--cached", "--no-ext-diff", "-M"] + ws + ["--"] + c.paths
                } else {
                    args = ["diff", "--no-ext-diff"] + ws + ["--"] + c.paths
                }
            case .commit(let sha, let c, let parent):
                args = ["diff", "--no-ext-diff", "-M"] + ws + [parent ?? empty, sha, "--"] + c.paths
            case .worktree(let path, let c):
                dir = URL(fileURLWithPath: path, isDirectory: true)
                if c.kind == .untracked {
                    args = ["diff", "--no-index", "--no-ext-diff"] + ws + ["--", "/dev/null", c.path]
                    ok = [0, 1]
                } else {
                    // staged and unstaged together, as the worktree's whole change
                    args = ["diff", "HEAD", "--no-ext-diff", "-M"] + ws + ["--"] + c.paths
                }
            case .review(_, let c, let patch):
                // 서버가 준 덩어리만 있는 패치에 머리를 붙여 그대로 읽는다(git 실행 없음)
                let old = c.oldPath ?? c.path
                let text = "diff --git a/\(old) b/\(c.path)\n--- a/\(old)\n+++ b/\(c.path)\n" + patch
                let doc = patch.isEmpty ? DiffDocument(isBinary: true) : await Task.detached { Parsers.diff(text) }.value
                guard !Task.isCancelled, self.diffSource == source else { return }
                self.diff = doc
                self.diffImages = nil
                self.diffLoading = false
                return
            }
            do {
                async let images = loadDiffImages(source)
                let r = try await Git.run(args, in: dir, ok: ok)
                let doc = await Task.detached { Parsers.diff(r.output) }.value
                let imgs = await images
                guard !Task.isCancelled, self.diffSource == source else { return }
                self.diff = doc
                self.diffImages = imgs
                // 다시 읽은 diff 에 없는 줄은 고른 것에서 뺀다
                let ids = Set(doc.lines.map(\.id))
                self.diffSelection = self.diffSelection.filter { ids.contains($0) }
            } catch {
                guard !Task.isCancelled, self.diffSource == source else { return }
                self.diff = DiffDocument(error: describe(error))
            }
            self.diffLoading = false
        }
    }
}
