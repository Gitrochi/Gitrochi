#!/usr/bin/env bash
# Checks selection restore, commit readiness, graph widths and page navigation without a real Git repository.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
ARCH="$(uname -m)"
ST="${GITROCHI_SWIFTTERM_DIR:-$ROOT/.build/swiftterm/$ARCH}"
if [[ ! -f "$ST/libSwiftTerm.a" ]]; then
    echo 'Run macos/build.sh once to build SwiftTerm.' >&2
    exit 1
fi
# private(set) 데이터의 테스트 주입은 같은 파일의 테스트 전용 확장에서만 허용한다.
sed 's/UserDefaults\.standard/workspaceNavigationFixtureDefaults/g' "$ROOT/Sources/Store/RepoStore.swift" > "$TASK_TMP/RepoStore.swift"
sed 's/UserDefaults\.standard/workspaceNavigationFixtureDefaults/g' "$ROOT/Sources/Store/RepoStore+Navigation.swift" > "$TASK_TMP/Navigation.swift"
cat >> "$TASK_TMP/RepoStore.swift" <<'SWIFT'
let workspaceNavigationFixtureSuiteName = "dev.gitrochi.navigation-fixture." + UUID().uuidString
let workspaceNavigationFixtureDefaults = UserDefaults(suiteName: workspaceNavigationFixtureSuiteName)!
extension RepoStore {
    func fixtureRepository(_ path: String?) { url = path.map { URL(fileURLWithPath: $0, isDirectory: true) } }
    func resetNavigationFixture() { resetState() }
    func fixture(status: WorkingStatus, head: String?, commits: [Commit] = []) {
        self.status = status
        headHash = head
        let layout = GraphLayout.compute(commits)
        entries = zip(commits, layout.rows).map { GraphEntry(commit: $0, row: $1) }
        commitIndex = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.element.id, $0.offset) })
    }
    func reconcileFixture() { fixSelection() }
    func branchFixture(_ branches: [Branch]) { localBranches = branches.filter { !$0.isRemote }; remoteBranches = branches.filter(\.isRemote) }
    func worktreeFixture(_ list: [Worktree]) { worktrees = list }
}
SWIFT
cat > "$TASK_TMP/main.swift" <<'SWIFT'
import SwiftUI

@main struct WorkspaceNavigationTests {
    @MainActor static func main() {
        defer { workspaceNavigationFixtureDefaults.removePersistentDomain(forName: workspaceNavigationFixtureSuiteName) }
        let store = RepoStore()
        let file = FileChange(path: "src/a.swift", oldPath: nil, kind: .modified, staged: false)
        let staged = FileChange(path: file.path, oldPath: nil, kind: .modified, staged: true)
        let head = String(repeating: "a", count: 40)
        let parent = String(repeating: "b", count: 40)
        let commits = [Commit.wip(parent: head), Commit(id: head, parents: [parent], author: "Demo", email: "demo@example.com", date: Date(), subject: "A long commit message"), Commit(id: parent, parents: [], author: "Demo", email: "demo@example.com", date: Date(), subject: "Initial commit")]
        store.fixture(status: WorkingStatus(unstaged: [file]), head: head, commits: commits)
        store.select(.wip)
        store.openDiff(.working(file))
        store.summary = "Keep my draft"
        store.message = "Keep my description"
        store.showArea(.history)
        precondition(store.selection == .commit(head) && store.diffSource == nil)
        let historySource = DiffSource.commit(sha: head, change: staged, parent: parent)
        store.openDiff(historySource)
        store.showArea(.changes)
        precondition(store.selection == .wip && store.diffSource == .working(file))
        precondition(store.summary == "Keep my draft" && store.message == "Keep my description")
        store.showArea(.history)
        precondition(store.selection == .commit(head) && store.diffSource == historySource)
        store.select(.commit(parent))
        precondition(store.diffSource == nil, "Changing commits must clear an unrelated diff")
        store.moveSelection(-1)
        store.moveSelection(-1)
        precondition(store.selection == .wip, "Keyboard navigation must reach the visible latest-main WIP row")
        store.select(.wip)
        precondition(store.diffSource == .working(file), "Command-1 must restore the selected file")
        store.fixture(status: WorkingStatus(staged: [staged]), head: head, commits: commits)
        store.reconcileFixture()
        precondition(store.diffSource == .working(staged), "Staging must follow the same file into the index")
        precondition(store.canCommit)
        store.showArea(.history)
        store.select(.commit(parent))
        store.showArea(.changes)
        store.fixture(status: WorkingStatus(staged: [staged]), head: head, commits: [commits[1]])
        store.showArea(.history)
        precondition(store.selection == .commit(head) && store.diffSource == nil, "Removed history must fall back to HEAD")
        store.showArea(.changes)
        store.summary = "  "
        precondition(!store.canCommit)
        store.summary = "Ready"
        store.busy = "Staging…"
        precondition(!store.canCommit && store.commitGuidance == "Staging…")
        store.busy = nil
        store.fixture(status: WorkingStatus(conflicted: [file]), head: head)
        precondition(!store.canCommit)
        store.fixture(status: WorkingStatus(), head: head)
        precondition(!store.canCommit)
        store.amend = true
        precondition(store.canCommit, "Amend without staged files retains its existing meaning")
        store.gitchChecking = true
        precondition(!store.canCommit)
        store.gitchChecking = false
        store.gitchPreflight = Gitch.Preflight(result: "STOP", checks: [])
        precondition(!store.canCommit, "A known gitch STOP must remain blocked")
        store.gitchPreflight = Gitch.Preflight(result: "WARN", checks: [])
        precondition(store.canCommit, "Warnings remain reviewable without blocking")
        for width: CGFloat in [410, 520, 780, 1200] {
            for lanes in [1, 6, 24] {
                let columns = GraphMetrics.columns(width: width, graph: GraphMetrics.width(lanes: lanes))
                let message = width - columns.ref - columns.graph - 32 - columns.trailing
                precondition(message >= 199, "The commit message needs readable width")
            }
        }
        precondition(GraphMetrics.width(lanes: 24) == GraphMetrics.width(lanes: GraphMetrics.maxVisibleLanes), "Lanes past the visible limit do not widen the graph column")
        precondition(WorkspaceDestination.allCases.count == 13)
        // Ledger is hidden until its core is connected: listed and restorable only with GITROCHI_LEDGER_PREVIEW=1
        let ledgerShown = ProcessInfo.processInfo.environment["GITROCHI_LEDGER_PREVIEW"] == "1"
        precondition(WorkspaceDestination.shown.count == (ledgerShown ? 13 : 12) && WorkspaceDestination.ledger.isShown == ledgerShown)
        // the Ledger only adds: every page main has keeps its order, raw value and title
        let mainPages: [WorkspaceDestination] = [.home, .repository, .compare, .rebase, .code, .pullRequests, .issues, .actions, .releases, .projects, .account, .flows]
        precondition(Array(WorkspaceDestination.shown.prefix(12)) == mainPages && Array(WorkspaceDestination.allCases.prefix(12)) == mainPages)
        precondition(mainPages.allSatisfy { WorkspaceDestination(rawValue: $0.rawValue) == $0 && $0.isShown }, "Existing pages restore as before")
        precondition(!WorkspaceDestination.ledger.needsRepository, "Ledger opens without a repository")
        let nav = RepoStore()
        for page in WorkspaceDestination.allCases {
            let previous = nav.destination
            let allowed = nav.navigate(page, prepare: false)
            precondition(allowed == !page.needsRepository, "Repository pages need a repository; Home, Issues, Releases, Projects and Account stay available")
            precondition(nav.destination == (page.needsRepository ? previous : page))
        }
        let firstPath = NSTemporaryDirectory() + "gitrochi-navigation-first", secondPath = NSTemporaryDirectory() + "gitrochi-navigation-second"
        nav.fixtureRepository(firstPath)
        nav.fixture(status: WorkingStatus(), head: head, commits: commits)
        for page in WorkspaceDestination.allCases { precondition(nav.navigate(page, prepare: false)); precondition(nav.destination == page) }
        for page in WorkspaceDestination.allCases where ![WorkspaceDestination.repository, .pullRequests].contains(page) {
            nav.navigate(page, prepare: false)
            for selection in [Selection.wip, .commit(head), .pullRequest(7)] {
                nav.select(selection)
                precondition(nav.destination == page, "Background selection must not replace a full-width page")
            }
            nav.syncWorkspaceSelection(nil)
            precondition(nav.destination == page)
        }
        nav.navigate(.repository); nav.select(.commit(parent)); nav.diffSource = .commit(sha: parent, change: staged, parent: nil)
        nav.showArea(.changes)
        precondition(nav.destination == .repository && nav.selection == .wip, "Changes must activate the working-tree selection")
        nav.showArea(.history)
        precondition(nav.selection == .commit(parent), "History must restore the previous history selection")
        nav.select(.pullRequest(7)); precondition(nav.destination == .repository, "A request chosen on the repository screen opens in the inspector")
        nav.showArea(.history)
        precondition(nav.selection == .commit(parent), "Leaving a request for history must restore the previous history selection")
        nav.navigate(.pullRequests); nav.select(.wip); precondition(nav.destination == .repository, "A graph selection leaves the Pull requests page")
        nav.navigate(.pullRequests); nav.select(.pullRequest(7)); precondition(nav.destination == .pullRequests)
        nav.navigate(.repository); nav.showArea(.history)
        nav.diffSource = .working(file); nav.fileInspect = FileInspect(mode: .history, path: file.path)
        nav.navigate(.pullRequests)
        precondition(nav.destination == .pullRequests && nav.selection == .pullRequest(7) && nav.diffSource == nil && nav.fileInspect == nil, "The Pull requests page must bring back its request and clear unrelated file panels")
        let reviewSource = DiffSource.review(number: 7, change: file, patch: "+fixture")
        nav.diffSource = reviewSource; nav.navigate(.code); nav.navigate(.pullRequests)
        precondition(nav.diffSource == reviewSource, "An existing PR review should survive page navigation")
        nav.navigate(.code); nav.reveal(parent)
        precondition(nav.destination == .repository && nav.scrollTarget == parent, "Explicit graph reveal must open the repository screen")
        nav.navigate(.code); nav.openDiff(.working(file), revealPage: false)
        precondition(nav.destination == .code, "Restoring a background diff must not take over a utility page")
        nav.openDiff(.working(file))
        precondition(nav.destination == .repository && nav.diffSource == .working(file), "An explicit working diff should open the repository screen")
        nav.navigate(.flows); nav.openDiff(.commit(sha: head, change: staged, parent: parent))
        precondition(nav.destination == .repository, "An explicit commit diff should open the repository screen")
        nav.navigate(.issues); nav.selection = .pullRequest(7); nav.openDiff(reviewSource)
        precondition(nav.destination == .pullRequests && nav.diffSource == reviewSource, "An explicit review diff should open Pull requests")
        nav.navigate(.code); nav.openFileHistory(file.path)
        precondition(nav.destination == .repository && nav.fileInspect?.mode == .history)
        nav.navigate(.account); nav.openBlame(file.path, rev: head)
        precondition(nav.destination == .repository && nav.fileInspect?.mode == .blame && nav.fileInspect?.rev == head)
        nav.navigate(.repository); nav.navigate(.issues)
        precondition(nav.cameFromRepository, "Issues opened from the repository screen offers the way back")
        nav.navigate(.issues); precondition(nav.cameFromRepository, "Staying on the page keeps the way back")
        nav.navigate(.code); precondition(!nav.cameFromRepository)
        nav.navigate(.pullRequests); precondition(!nav.cameFromRepository, "Only a page opened from the repository screen offers the way back")
        nav.navigate(.repository); nav.navigate(.pullRequests); precondition(nav.cameFromRepository)
        nav.navigate(.repository); nav.navigate(.actions); precondition(nav.cameFromRepository, "Actions opened from a commit's CI icon offers the way back")
        workspaceNavigationFixtureDefaults.set([firstPath: "code", secondPath: "issues"], forKey: "workspaceDestinations")
        nav.fixtureRepository(firstPath); nav.restoreWorkspaceDestination()
        precondition(nav.destination == .code)
        nav.resetNavigationFixture(); nav.fixtureRepository(secondPath); nav.restoreWorkspaceDestination()
        precondition(nav.destination == .issues, "A repository must restore its own page")
        workspaceNavigationFixtureDefaults.set([secondPath: "ledger"], forKey: "workspaceDestinations")
        nav.restoreWorkspaceDestination()
        precondition(nav.destination == (ledgerShown ? .ledger : .repository), "A remembered Ledger page opens only while the Ledger is shown")
        for saved in ["missing-page", "settings", "__proto__", "changes", "branches", "worktrees"] {
            workspaceNavigationFixtureDefaults.set([secondPath: saved], forKey: "workspaceDestinations")
            nav.restoreWorkspaceDestination()
            precondition(nav.destination == .repository, "Unknown saved pages must fall back to the repository screen")
        }
        nav.navigate(.issues)
        workspaceNavigationFixtureDefaults.set([secondPath: 7], forKey: "workspaceDestinations")
        nav.restoreWorkspaceDestination()
        precondition(nav.destination == .repository, "Incorrectly typed saved pages must fall back safely")
        nav.resetNavigationFixture(); nav.fixtureRepository(nil)
        workspaceNavigationFixtureDefaults.set([secondPath: "code"], forKey: "workspaceDestinations")
        nav.restoreWorkspaceDestination(); precondition(nav.destination == .home, "Without a repository the window shows Home")
        precondition(!nav.navigate(.repository) && nav.destination == .home)
        do {
        let contexts = RepoStore()
        contexts.fixtureRepository(firstPath)
        let worktreePath = firstPath + "-linked"
        let pendingCommit = Commit.worktreeWIP(path: worktreePath, parent: head)
        let contextCommits = [commits[0], pendingCommit, commits[1], commits[2]]
        contexts.fixture(status: WorkingStatus(unstaged: [file]), head: head, commits: contextCommits)
        contexts.worktreeFixture([Worktree(path: worktreePath, head: head, branch: "feature/demo", isMain: false, locked: false, prunable: false)])
        let workingSource = DiffSource.working(file)
        let historySource = DiffSource.commit(sha: parent, change: staged, parent: nil)
        let linkedSource = DiffSource.worktree(path: worktreePath, change: file)
        let contextReviewSource = DiffSource.review(number: 17, change: file, patch: "+context fixture")
        let workingInspect = FileInspect(mode: .history, path: file.path)
        let commitInspect = FileInspect(mode: .blame, path: file.path, rev: parent)
        contexts.navigate(.repository); contexts.showArea(.changes); contexts.diffSource = workingSource; contexts.fileInspect = workingInspect
        contexts.showArea(.history); contexts.select(.commit(parent))
        contexts.diffSource = historySource; contexts.fileInspect = commitInspect
        contexts.select(.pullRequest(17)); contexts.diffSource = contextReviewSource
        contexts.showArea(.history)
        precondition(contexts.selection == .commit(parent) && contexts.diffSource == historySource && contexts.fileInspect == commitInspect, "PR review must not overwrite commit document context")
        contexts.navigate(.pullRequests)
        precondition(contexts.selection == .pullRequest(17) && contexts.diffSource == contextReviewSource, "Returning to requests must restore its selected file")
        contexts.select(.pullRequest(18))
        precondition(contexts.diffSource == nil && contexts.pullRequestDiff == nil, "A different request must not inherit the previous request's file")
        contexts.showArea(.history)
        precondition(contexts.selection == .commit(parent) && contexts.diffSource == historySource)
        contexts.select(.worktree(worktreePath)); contexts.diffSource = linkedSource
        contexts.showArea(.changes)
        precondition(contexts.diffSource == workingSource && contexts.fileInspect == workingInspect, "Linked-worktree browsing must not overwrite the working document")
        contexts.select(.worktree(worktreePath), restoringContext: true)
        precondition(contexts.diffSource == linkedSource, "Linked-worktree files have their own document context")
        contexts.showArea(.history)
        precondition(contexts.selection == .commit(parent) && contexts.diffSource == historySource, "A worktree row must not become the saved history commit")
        let currentBranch = Branch(name: "main", target: head, upstream: nil, ahead: 0, behind: 0, upstreamGone: false, isCurrent: true, isRemote: false)
        let featureBranch = Branch(name: "feature/demo", target: head, upstream: nil, ahead: 0, behind: 0, upstreamGone: false, isCurrent: false, isRemote: false)
        contexts.branchFixture([currentBranch, featureBranch])
        contexts.select(.commit(head)); precondition(contexts.selectedBranchContext?.id == currentBranch.id)
        contexts.selectedBranchID = featureBranch.id
        precondition(contexts.selectedBranchContext?.id == featureBranch.id, "References at the same SHA must keep the chosen branch identity")
        contexts.select(.commit(parent)); precondition(contexts.selectedBranchContext == nil)
        contexts.select(.wip); precondition(contexts.selectedBranchContext == nil)
        contexts.selectGraphCommit(head); contexts.selectGraphCommit(parent, extend: true)
        precondition(contexts.historyTools.selected == [head, parent], "Batch commit selection must exclude linked-worktree WIP nodes")
        contexts.select(.commit(head)); contexts.moveSelection(-1)
        precondition(contexts.selection == .worktree(worktreePath), "Keyboard graph navigation must retain linked-worktree rows")
        contexts.showArea(.history); contexts.select(.commit(parent)); contexts.navigate(.flows)
        contexts.fixture(status: WorkingStatus(unstaged: [file]), head: head, commits: [commits[0], commits[1]])
        contexts.reconcileFixture()
        precondition(contexts.destination == .flows && contexts.selection == .commit(head), "Background reload must repair removed history without replacing a full-width page")
        contexts.showCommandPalette = true; contexts.selectedBranchID = featureBranch.id
        contexts.resetNavigationFixture()
        precondition(!contexts.showCommandPalette && contexts.selectedBranchID == nil && contexts.destination == .home)
        let wide = GraphMetrics.contentWidth(lanes: 40), window = GraphMetrics.width(lanes: 40)
        precondition(wide > window, "Lanes past the visible limit scroll instead of widening the column")
        precondition(GraphMetrics.clampOffset(-5, content: wide, visible: window) == 0 && GraphMetrics.clampOffset(10_000, content: wide, visible: window) == wide - window)
        let reveal = GraphMetrics.offset(revealing: 30, current: 0, content: wide, visible: window)
        precondition(reveal > 0 && GraphMetrics.leftPad + GraphMetrics.laneWidth * 31 <= reveal + window, "Selecting a commit on a hidden lane scrolls it into view")
        precondition(GraphMetrics.offset(revealing: 1, current: reveal, content: wide, visible: window) <= GraphMetrics.leftPad + GraphMetrics.laneWidth)
        precondition(GraphMetrics.offset(revealing: 3, current: 0, content: wide, visible: window) == 0, "A visible lane leaves the offset alone")
        let plain = GraphMetrics.columns(width: 1400, graph: 300)
        precondition(plain.trailing == 0, "Author, time and SHA columns are off by default")
        let all = GraphMetrics.columns(width: 1600, graph: 300, shown: ["author", "time", "sha"])
        precondition(all.author == 120 && all.time == 84 && all.sha == 72)
        let narrow = GraphMetrics.columns(width: 950, graph: 300, shown: ["author", "time", "sha"])
        precondition(narrow.sha == 0 && narrow.time == 0 && narrow.author > 0, "Narrow windows drop SHA, then time, before author")
        let dragged = GraphMetrics.columns(width: 1600, graph: 300, shown: ["author"], widths: GraphMetrics.widths("author:200,time:5,bogus:9"))
        precondition(dragged.author == 200 && GraphMetrics.widths("time:5")["time"] == GraphMetrics.widthRange("time").lowerBound, "Dragged widths stay inside each column's range")
        let hiddenColumns = GraphMetrics.columns(width: 520, graph: 600, hidden: ["ref", "graph", "time"])
        precondition(hiddenColumns.ref == 0 && hiddenColumns.graph == 0 && hiddenColumns.time == 0, "Latest-main graph column visibility must survive UI integration")
        precondition(SharedHeights.share([1000, 30], available: 300, floor: 96) == [270, 30])
        precondition(SharedHeights.share([1000, 1000], available: 300, floor: 96) == [150, 150])
        precondition(SharedHeights.share([1000, 1000], available: 100, floor: 96) == [96, 96])
        }
        print("PASS: independent PR/commit/worktree documents, same-SHA branch identity, background reload, WIP keyboard/batch selection, shared pane heights; workspace/file context, drafts, graph sizing; lane scrolling and optional, resizable columns; 13 page gates (Ledger hidden without its preview), changes/history areas on the repository screen, background selection, explicit document/review navigation and isolated per-repository restore")
    }
}
SWIFT
SOURCES=()
while IFS= read -r -d '' file; do
    case "$file" in */App/App.swift|*/Store/RepoStore.swift|*/Store/RepoStore+Navigation.swift) continue ;; esac
    SOURCES+=("$file")
done < <(find "$ROOT/Sources" -name '*.swift' -print0)
TASK_CORE="$(bash "$ROOT/../tools/build-core-native.sh" "$ARCH")"
cp "$TASK_CORE" "$TASK_TMP/core.a"
TASK_CORE="$TASK_TMP/core.a"
swiftc -whole-module-optimization -Onone -parse-as-library -swift-version 5 -target "$ARCH-apple-macos15.0" -I "$ST" -I "$ROOT/../crates/gitrochi-core/include" -L "$ST" -lSwiftTerm \
    "${SOURCES[@]}" "$TASK_TMP/RepoStore.swift" "$TASK_TMP/Navigation.swift" "$TASK_TMP/main.swift" "$TASK_CORE" -o "$TASK_TMP/workspace-tests"
"$TASK_TMP/workspace-tests"
