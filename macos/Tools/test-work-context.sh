#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/gitrochi-work-context.XXXXXX")"
trap 'rm -rf "$TASK_TMP"' EXIT
cat > "$TASK_TMP/main.swift" <<'SWIFT'
import Foundation

func require(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}
let first = WorkContext(repositoryPath: "C:/fixture/workspace", head: String(repeating: "a", count: 40), scope: "worktree", selectedPaths: ["src/b.ts", "src/a.ts"], selectedNodeIDs: ["src/a.ts"], screenID: "changes", observedAt: "first")
let later = WorkContext(repositoryPath: "C:\\fixture\\workspace", head: String(repeating: "a", count: 40), scope: "worktree", selectedPaths: ["src/a.ts", "src/b.ts"], selectedNodeIDs: ["src/a.ts"], screenID: "changes", observedAt: "later")
require(first.fingerprint == later.fingerprint, "Time and input order must not invalidate context")
require(first.fingerprint == "cef08fad", "Context fingerprints must match the TypeScript contract fixture")
require(!first.json.contains("C:/fixture"), "Local repository roots must not be serialized")
require(!WorkContext.safePath("../outside") && !WorkContext.safePath(".env.local") && !WorkContext.safePath(".aws/config"), "Unsafe context paths must be excluded")
let changed = WorkContext(repositoryPath: "C:/fixture/workspace", head: String(repeating: "a", count: 40), scope: "worktree", selectedPaths: first.selectedPaths, selectedNodeIDs: first.selectedNodeIDs, screenID: "changes", revision: String(repeating: "b", count: 40))
require(changed.fingerprint != first.fingerprint, "A selected revision is part of the context identity")
let graph = WorkGraphSnapshot(schemaVersion: 1, id: "snapshot-a", nodeIDs: ["a.ts", "b.ts", "c.ts"], edges: [WorkGraphEdge(source: "a.ts", target: "b.ts")])
func validate(_ actions: [[String: Any]], version: Any = 1, snapshot: String = "snapshot-a") -> WorkGraphActions? { WorkGraphActions.validate(["schemaVersion": version, "snapshotID": snapshot, "actions": actions], snapshot: graph) }
require(validate([["kind": "nodes", "nodeIDs": ["a.ts"]], ["kind": "path", "nodeIDs": ["a.ts", "b.ts"]], ["kind": "clear"]])?.actions.count == 3, "Known graph actions must be accepted")
require(validate([["kind": "path", "nodeIDs": ["b.ts", "a.ts"]]]) == nil, "A path must follow directed edges")
require(validate([["kind": "nodes", "nodeIDs": ["missing.ts"]]]) == nil, "Unknown nodes must be rejected")
require(validate([["kind": "clear", "command": "anything"]]) == nil, "Executable action properties must be rejected")
require(validate([], version: true) == nil && validate([], snapshot: "old") == nil, "Version and snapshot must match exactly")
require(WorkPrompts.render(id: "impact", context: first).contains("src/a.ts"), "Task starters must include the selected files")
require(ScreenCodeMap.entry(for: "changes") != nil, "Maintained source mapping must exist")
print("Work context and typed graph action checks passed")
SWIFT
swiftc "$ROOT/Sources/Core/WorkContext.swift" "$ROOT/Sources/Core/WorkPrompts.swift" "$ROOT/Sources/Core/ScreenCodeMap.swift" "$TASK_TMP/main.swift" -o "$TASK_TMP/test-work-context"
"$TASK_TMP/test-work-context"
