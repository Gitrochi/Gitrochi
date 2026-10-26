#!/usr/bin/env bash
# 실제 Git 작업 없이 선택 복원·커밋 준비 조건·그래프 너비를 확인한다.
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
                let message = width - columns.ref - columns.graph - 32 - (columns.time ? 90 : 0)
                precondition(message >= 199, "The commit message needs readable width")
            }
        }
        precondition(GraphMetrics.width(lanes: 24) == GraphMetrics.width(lanes: GraphMetrics.maxVisibleLanes), "Lanes past the visible limit do not widen the graph column")
        precondition(WorkspaceDestination.allCases.count == 23)
        let nav = RepoStore()
        func navMatches(_ page: WorkspaceDestination) -> Bool {
            nav.destination == (page.repositorySection == nil ? page : .repository) && (page.repositorySection == nil || nav.repositorySection == page.repositorySection)
        }
        for page in WorkspaceDestination.allCases {
            let previous = nav.destination, trail = nav.navigationTrail
            let allowed = nav.navigate(page, prepare: false)
            precondition(allowed == !page.needsRepository, "Local pages require a repository; global menus remain available")
            if page.needsRepository { precondition(nav.destination == previous && nav.navigationTrail == trail) }
            else { precondition(navMatches(page)) }
        }
        let firstPath = NSTemporaryDirectory() + "gitrochi-navigation-first", secondPath = NSTemporaryDirectory() + "gitrochi-navigation-second"
        nav.fixtureRepository(firstPath)
        nav.fixture(status: WorkingStatus(), head: head, commits: commits)
        for page in WorkspaceDestination.allCases { precondition(nav.navigate(page, prepare: false)); precondition(navMatches(page)) }
        for page in WorkspaceDestination.allCases where ![WorkspaceDestination.repository, .changes, .commits, .pullRequests].contains(page) {
            nav.navigate(page, prepare: false)
            let trail = nav.navigationTrail
            for selection in [Selection.wip, .commit(head), .pullRequest(7)] {
                nav.select(selection)
                precondition(navMatches(page), "Background selection must not replace a utility or hosting page")
            }
            nav.syncWorkspaceSelection(nil)
            precondition(nav.navigationTrail == trail)
        }
        nav.select(.commit(parent)); nav.diffSource = .commit(sha: parent, change: staged, parent: nil)
        nav.navigate(.changes)
        precondition(navMatches(.changes) && nav.selection == .wip, "Changes must activate working-tree selection")
        nav.navigate(.commits)
        precondition(navMatches(.commits) && nav.selection == .commit(parent), "Commits must restore the user's previous history selection")
        nav.select(.pullRequest(7)); nav.navigate(.commits)
        precondition(navMatches(.commits) && nav.selection == .commit(parent), "Leaving PR selection for Commits must restore the previous history selection")
        nav.diffSource = .working(file); nav.fileInspect = FileInspect(mode: .history, path: file.path)
        nav.navigate(.pullRequests)
        precondition(nav.destination == .pullRequests && nav.diffSource == nil && nav.fileInspect == nil, "PR menu must clear unrelated file panels")
        nav.select(.pullRequest(7)); let reviewSource = DiffSource.review(number: 7, change: file, patch: "+fixture")
        nav.diffSource = reviewSource; nav.navigate(.code); nav.navigate(.pullRequests)
        precondition(nav.diffSource == reviewSource, "An existing PR review should survive menu navigation")
        nav.navigate(.changes); nav.select(.commit(parent)); precondition(navMatches(.commits))
        nav.select(.pullRequest(7)); precondition(nav.destination == .pullRequests)
        nav.select(.wip); precondition(navMatches(.changes))
        nav.navigate(.branches); nav.reveal(parent)
        precondition(navMatches(.commits) && nav.scrollTarget == parent, "Explicit graph reveal must open the commit menu")
        nav.navigate(.code); nav.openDiff(.working(file), revealPage: false)
        precondition(navMatches(.code), "Restoring a background diff must not take over a utility page")
        nav.openDiff(.working(file))
        precondition(navMatches(.changes) && nav.diffSource == .working(file), "An explicit working diff should open Changes")
        nav.navigate(.gists); nav.openDiff(.commit(sha: head, change: staged, parent: parent))
        precondition(navMatches(.commits), "An explicit commit diff should open Commits")
        nav.navigate(.issues); nav.selection = .pullRequest(7); nav.openDiff(reviewSource)
        precondition(nav.destination == .pullRequests && nav.diffSource == reviewSource, "An explicit review diff should open Pull requests")
        nav.navigate(.code); nav.openFileHistory(file.path)
        precondition(navMatches(.commits) && nav.fileInspect?.mode == .history)
        nav.navigate(.organizations); nav.openBlame(file.path, rev: head)
        precondition(navMatches(.commits) && nav.fileInspect?.mode == .blame && nav.fileInspect?.rev == head)
        nav.navigate(.changes); nav.openBlame(file.path)
        precondition(navMatches(.changes), "File inspection should retain an active local document menu")
        nav.destination = .home; nav.navigationTrail = [WorkspaceLocation(.home)]; nav.navigationPosition = 0
        for page in [WorkspaceDestination.code, .branches, .rebase] { nav.navigate(page, prepare: false) }
        let trail = nav.navigationTrail
        nav.moveWorkspaceHistory(-1); precondition(navMatches(.branches))
        nav.moveWorkspaceHistory(1); precondition(navMatches(.rebase) && nav.navigationTrail == trail)
        nav.moveWorkspaceHistory(10); nav.moveWorkspaceHistory(-10)
        precondition(navMatches(.rebase) && nav.navigationTrail == trail)
        nav.moveWorkspaceHistory(-1); nav.navigate(.issues)
        precondition(nav.navigationTrail == [WorkspaceLocation(.home), WorkspaceLocation(.code), WorkspaceLocation(.branches), WorkspaceLocation(.issues, section: .branches)] && nav.navigationPosition == 3, "A new page after Back must remove Forward history")
        nav.moveWorkspaceHistory(1); precondition(nav.destination == .issues)
        nav.navigate(.issues); precondition(nav.navigationTrail.count == 4, "The current page must not add duplicate entries")
        for index in 0..<60 { nav.navigate(index.isMultiple(of: 2) ? .branches : .code, prepare: false) }
        precondition(nav.navigationTrail.count == 40 && nav.navigationPosition == 39)
        workspaceNavigationFixtureDefaults.set([firstPath: "code", secondPath: "issues"], forKey: "workspaceDestinations")
        nav.fixtureRepository(firstPath); nav.restoreWorkspaceDestination()
        precondition(navMatches(.code) && nav.navigationTrail == [WorkspaceLocation(.code)] && nav.navigationPosition == 0)
        nav.resetNavigationFixture(); nav.fixtureRepository(secondPath); nav.restoreWorkspaceDestination()
        precondition(nav.destination == .issues && nav.navigationTrail == [WorkspaceLocation(.issues)], "A repository must restore its own menu, without another repository's history")
        for saved in ["missing-page", "settings", "__proto__"] {
            workspaceNavigationFixtureDefaults.removeObject(forKey: "workspaceRepositorySections")
            workspaceNavigationFixtureDefaults.set([secondPath: saved], forKey: "workspaceDestinations")
            nav.area = .history; nav.selection = .commit(head); nav.restoreWorkspaceDestination()
            precondition(navMatches(.commits) && nav.navigationTrail == [WorkspaceLocation(.commits)], "Unknown saved pages must fall back safely")
        }
        workspaceNavigationFixtureDefaults.removeObject(forKey: "workspaceRepositorySections")
        workspaceNavigationFixtureDefaults.set([secondPath: 7], forKey: "workspaceDestinations")
        nav.area = .changes; nav.selection = .wip; nav.restoreWorkspaceDestination()
        precondition(navMatches(.changes) && nav.navigationTrail == [WorkspaceLocation(.changes)], "Incorrectly typed saved pages must fall back safely")
        nav.navigate(.compare, prepare: false); nav.navigate(.issues, prepare: false); nav.navigate(.repository, prepare: false)
        precondition(navMatches(.compare), "The unified repository must retain the previous internal tool")
        let beforePin = nav.navigationTrail
        precondition(nav.pinnedRepositoryPages.isEmpty)
        nav.toggleRepositoryPagePin(.compare); nav.toggleRepositoryPagePin(.changes)
        precondition(nav.pinnedRepositoryPages == [.changes, .compare] && nav.navigationTrail == beforePin)
        let otherWindow = RepoStore()
        precondition(otherWindow.pinnedRepositoryPages == [.changes, .compare], "Pinned shortcuts are shared between windows")
        otherWindow.toggleRepositoryPagePin(.compare)
        precondition(!nav.isRepositoryPagePinned(.compare) && navMatches(.compare), "Removing a shortcut must not close its workspace")
        workspaceNavigationFixtureDefaults.set([firstPath: "repository", secondPath: "repository"], forKey: "workspaceDestinations")
        workspaceNavigationFixtureDefaults.set([firstPath: "compare", secondPath: "rebase"], forKey: "workspaceRepositorySections")
        nav.fixtureRepository(firstPath); nav.restoreWorkspaceDestination(); precondition(navMatches(.compare))
        nav.resetNavigationFixture(); nav.fixtureRepository(secondPath); nav.restoreWorkspaceDestination(); precondition(navMatches(.rebase))
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
        contexts.navigate(.changes); contexts.diffSource = workingSource; contexts.fileInspect = workingInspect
        contexts.navigate(.commits); contexts.select(.commit(parent))
        contexts.diffSource = historySource; contexts.fileInspect = commitInspect
        contexts.select(.pullRequest(17)); contexts.diffSource = contextReviewSource
        contexts.navigate(.commits)
        precondition(contexts.selection == .commit(parent) && contexts.diffSource == historySource && contexts.fileInspect == commitInspect, "PR review must not overwrite commit document context")
        contexts.navigate(.pullRequests)
        precondition(contexts.selection == .pullRequest(17) && contexts.diffSource == contextReviewSource, "Returning to requests must restore its selected file")
        contexts.select(.pullRequest(18))
        precondition(contexts.diffSource == nil && contexts.pullRequestDiff == nil, "A different request must not inherit the previous request's file")
        contexts.navigate(.commits)
        precondition(contexts.selection == .commit(parent) && contexts.diffSource == historySource)
        contexts.select(.worktree(worktreePath)); contexts.diffSource = linkedSource
        contexts.navigate(.changes)
        precondition(contexts.diffSource == workingSource && contexts.fileInspect == workingInspect, "Linked-worktree browsing must not overwrite the working document")
        contexts.select(.worktree(worktreePath), restoringContext: true)
        precondition(contexts.diffSource == linkedSource, "Linked-worktree files have their own document context")
        contexts.navigate(.commits)
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
        contexts.navigate(.commits); contexts.select(.commit(parent)); contexts.navigate(.agents)
        let backgroundTrail = contexts.navigationTrail, backgroundPosition = contexts.navigationPosition
        contexts.fixture(status: WorkingStatus(unstaged: [file]), head: head, commits: [commits[0], commits[1]])
        contexts.reconcileFixture()
        precondition(contexts.destination == .agents && contexts.selection == .commit(head), "Background reload must repair removed history without replacing a tool page")
        precondition(contexts.navigationTrail == backgroundTrail && contexts.navigationPosition == backgroundPosition, "Background reload must not add page visits or erase Forward history")
        contexts.showCommandPalette = true; contexts.showHistoryInspector = false
        contexts.resetNavigationFixture()
        precondition(!contexts.showCommandPalette && contexts.showHistoryInspector && contexts.selectedBranchID == nil)
        let hiddenColumns = GraphMetrics.columns(width: 520, graph: 600, hidden: ["ref", "graph", "time"])
        precondition(hiddenColumns.ref == 0 && hiddenColumns.graph == 0 && !hiddenColumns.time, "Latest-main graph column visibility must survive UI integration")
        precondition(SharedHeights.share([1000, 30], available: 300, floor: 96) == [270, 30])
        precondition(SharedHeights.share([1000, 1000], available: 300, floor: 96) == [150, 150])
        precondition(SharedHeights.share([1000, 1000], available: 100, floor: 96) == [96, 96])
        }
        print("PASS: independent PR/commit/worktree documents, same-SHA branch identity, background reload, WIP keyboard/batch selection, shared pane heights; workspace/file context, drafts, graph sizing; 23 route gates, six tools in one repository, pin persistence/shared windows, internal-section restore, background selection, explicit document/review navigation, history branching/limits and isolated per-repository restore")
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
