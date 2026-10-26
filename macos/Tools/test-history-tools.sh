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
        print("History tools passed: safe revisions, SHA-256, line/function selectors, patch records, cancellation and hooks-preserving cleanup")
    }
}
SWIFT
swiftc -parse-as-library -swift-version 5 \
  "$ROOT/Sources/Core/Markdown.swift" "$ROOT/Sources/Core/MarkdownInline.swift" \
  "$ROOT/Sources/Core/Models.swift" "$ROOT/Sources/Core/HistoryTools.swift" \
  "$ROOT/Sources/Core/RebasePlan.swift" "$TASK_TMP/main.swift" -o "$TASK_TMP/test-history-tools"
"$TASK_TMP/test-history-tools"
