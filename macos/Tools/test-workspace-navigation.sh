#!/usr/bin/env bash
# 실제 Git 작업 없이 선택 복원·커밋 준비 조건·그래프 너비를 확인한다.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
ARCH="$(uname -m)"
ST="$ROOT/.build/swiftterm/$ARCH"
if [[ ! -f "$ST/libSwiftTerm.a" ]]; then
    echo 'Run macos/build.sh once to build SwiftTerm.' >&2
    exit 1
fi
# private(set) 데이터의 테스트 주입은 같은 파일의 테스트 전용 확장에서만 허용한다.
cat "$ROOT/Sources/Store/RepoStore.swift" > "$TASK_TMP/RepoStore.swift"
cat >> "$TASK_TMP/RepoStore.swift" <<'SWIFT'
extension RepoStore {
    func fixture(status: WorkingStatus, head: String?, commits: [Commit] = []) {
        self.status = status
        headHash = head
        let layout = GraphLayout.compute(commits)
        entries = zip(commits, layout.rows).map { GraphEntry(commit: $0, row: $1) }
        commitIndex = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.element.id, $0.offset) })
    }
    func reconcileFixture() { fixSelection() }
}
SWIFT
cat > "$TASK_TMP/main.swift" <<'SWIFT'
import SwiftUI

@main struct WorkspaceNavigationTests {
    @MainActor static func main() {
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
        precondition(store.selection == .commit(head), "Keyboard navigation must stay in history")
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
        precondition(GraphMetrics.width(lanes: 24, expanded: true) > GraphMetrics.width(lanes: 24))
        print("PASS: workspace and file context, drafts, keyboard history, staging continuity, commit conditions, narrow and expanded graph columns")
    }
}
SWIFT
SOURCES=()
while IFS= read -r -d '' file; do
    case "$file" in */App/App.swift|*/Store/RepoStore.swift) continue ;; esac
    SOURCES+=("$file")
done < <(find "$ROOT/Sources" -name '*.swift' -print0)
swiftc -parse-as-library -swift-version 5 -target "$ARCH-apple-macos15.0" -I "$ST" -L "$ST" -lSwiftTerm \
    "${SOURCES[@]}" "$TASK_TMP/RepoStore.swift" "$TASK_TMP/main.swift" -o "$TASK_TMP/workspace-tests"
"$TASK_TMP/workspace-tests"
