#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
cat > "$TASK_TMP/main.swift" <<'SWIFT'
import Foundation

@main struct HistoryToolsTests {
    @MainActor static func main() throws {
        for value in ["HEAD", "HEAD~4", "origin/topic", "v1.2.0", String(repeating: "a", count: 40)] { precondition(HistoryTools.validRevision(value)) }
        for value in ["", "--output=path", " bad", "a\nb", "HEAD\0"] { precondition(!HistoryTools.validRevision(value)) }
        precondition(HistoryTools.objectID(String(repeating: "a", count: 40)))
        precondition(HistoryTools.objectID(String(repeating: "b", count: 64)))
        precondition(!HistoryTools.objectID("--help"))
        let range = try HistoryTools.range(path: "src/이름 with spaces.swift", start: 2, end: 9)
        precondition(range == "2,9:src/이름 with spaces.swift")
        let function = try HistoryTools.range(path: "file.ts", start: 1, end: 1, function: "load.value")
        precondition(function == ":load\\.value:file.ts")
        for pair in [(0, 2), (4, 3)] {
            do { _ = try HistoryTools.range(path: "a", start: pair.0, end: pair.1); preconditionFailure("Invalid range accepted") } catch {}
        }
        let sha = String(repeating: "a", count: 40)
        let records = HistoryTools.lineHistory("\u{1e}\(sha)\u{1f}Fixture\u{1f}2026-01-01\u{1f}Change\n\ndiff --git a/f b/f\n+new\n")
        precondition(records.count == 1 && records[0].patch.contains("+new"))
        let state = HistoryToolsState()
        let old = state.generation
        state.selected = [sha]; state.lineLoading = true; state.reset()
        precondition(old != state.generation && state.selected.isEmpty && !state.lineLoading)
        let item = RebaseItem(sha: sha, message: "New message", author: "Fixture")
        var plan = RebasePlan(base: nil, items: [item]); plan.items[0].action = .reword; plan.items[0].newMessage = "Edited"
        let todo = plan.todo { _ in "/fixture/msg" }
        precondition(todo.contains("--amend") && !todo.contains("--no-verify"))
        // the Compare page (Windows: tests/history-tools.test.ts)
        let other = String(repeating: "b", count: 40)
        precondition(HistoryTools.comparisonLogArgs(base: sha, right: other) == ["log", "-n", "201", "--format=%H%x1f%an%x1f%ct%x1f%s%x1e", sha + ".." + other, "--"])
        let commits = HistoryTools.comparisonCommits("\(sha)\u{1f}Alex Kim\u{1f}1762300800\u{1f}Split\u{1f}subject\u{1e}\n\(other)\u{1f}Sam Lee\u{1f}\u{1f}No time\u{1e}\nnot a commit\u{1e}\n")
        precondition(commits == [ComparisonCommit(id: sha, author: "Alex Kim", date: Date(timeIntervalSince1970: 1_762_300_800), subject: "Split\u{1f}subject"), ComparisonCommit(id: other, author: "Sam Lee", date: nil, subject: "No time")])
        precondition(HistoryTools.comparisonCommits("").isEmpty)
        precondition(HistoryTools.commitCountLabel(8) == "8" && HistoryTools.commitCountLabel(200) == "200" && HistoryTools.commitCountLabel(201) == "200+")
        let references = HistoryTools.comparisonReferences(local: ["topic", "feature/a", "main"], remote: ["origin/HEAD", "origin/main", "origin/topic"], tags: ["v1.1", "v1.0"], current: "topic")
        precondition(references.map(\.name) == ["origin/main", "main", "feature/a", "origin/topic", "v1.1", "v1.0"] && references.map(\.kind) == [.remote, .branch, .branch, .remote, .tag, .tag], "The usual bases come first, without the current branch or a remote's HEAD")
        precondition(HistoryTools.comparisonReferences(local: ["main"], remote: [], tags: [], current: nil).map(\.name) == ["main"])
        precondition(references.filter { HistoryTools.referenceMatches($0.name, filter: " MAIN ") }.map(\.name) == ["origin/main", "main"])
        let targets = ["main": sha, "topic": other]
        let key = HistoryTools.comparisonKey(repository: "/repo", left: "main", right: "topic", mergeBase: true, head: sha, targets: targets)
        precondition(HistoryTools.comparisonKey(repository: "/repo", left: "main", right: "topic", mergeBase: true, head: sha, targets: targets) == key)
        precondition(HistoryTools.comparisonKey(repository: "/repo", left: "main", right: "topic", mergeBase: true, head: sha, targets: ["main": sha, "topic": sha]) != key, "A moved branch compares again")
        precondition(HistoryTools.comparisonKey(repository: "/repo", left: "main", right: "topic", mergeBase: false, head: sha, targets: targets) != key)
        precondition(HistoryTools.comparisonKey(repository: "/repo", left: "topic", right: "main", mergeBase: true, head: sha, targets: targets) != key)
        precondition(HistoryTools.comparisonKey(repository: "/repo", left: "main", right: "topic", mergeBase: true, head: other, targets: targets) != key)
        print("History tools passed: safe revisions, SHA-256, line/function selectors, patch records, cancellation, hooks-preserving cleanup and the Compare page's commits, references and change key")
    }
}
SWIFT
swiftc -parse-as-library -swift-version 5 \
  "$ROOT/Sources/Core/Markdown.swift" "$ROOT/Sources/Core/MarkdownInline.swift" \
  "$ROOT/Sources/Core/ProjectTaskReference.swift" "$ROOT/Sources/Core/Models.swift" "$ROOT/Sources/Core/HistoryTools.swift" \
  "$ROOT/Sources/Core/RebasePlan.swift" "$TASK_TMP/main.swift" -o "$TASK_TMP/test-history-tools"
"$TASK_TMP/test-history-tools"
