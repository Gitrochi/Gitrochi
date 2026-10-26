#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
cat > "$TASK_TMP/main.swift" <<'SWIFT'
import Foundation
@main struct LocalWorkflowTests {
    static func main() {
        for path in ["../private", "/absolute", "C:/private", "a/.git/config", "-option", "a\\b", "a\nfile"] { precondition(!LocalWorkflowState.safePath(path), path) }
        for path in ["source/main.swift", "한글/파일.txt", "[literal].txt"] { precondition(LocalWorkflowState.safePath(path), path) }
        for url in ["file:///private", "ext::command", "../relative", "https://user:token@example.com/repo", "ssh://-oProxyCommand=bad/repo", "https://example.com/a%0arepo"] { precondition(!LocalWorkflowState.safeURL(url), url) }
        for url in ["https://example.com/repo.git", "git@example.com:org/repo.git", "ssh://git@example.com:2222/org/repo.git"] { precondition(LocalWorkflowState.safeURL(url), url) }
        let oid = String(repeating: "a", count: 40), scope = String(repeating: "b", count: 40)
        let refs = ["worktree", "index", "head"].map { "refs/gitrochi/safety/\(scope)/123-a/\($0) \(oid)" }.joined(separator: "\n")
        let copies = LocalWorkflowState.parseSafety(refs)
        precondition(copies.count == 1 && copies[0].head == oid)
        precondition(LocalWorkflowState.parseSafety("refs/gitrochi/safety/123-a/worktree \(oid)").isEmpty)
        let doc = ConflictDocument.parse("before\r\n<<<<<<< HEAD\r\nmine\r\n||||||| base\r\nold\r\n=======\r\ntheirs\r\n>>>>>>> topic\r\nafter\r\n")
        precondition(doc.projection("ours") == "before\r\nmine\r\nafter\r\n")
        precondition(doc.projection("base") == "before\r\nold\r\nafter\r\n")
        precondition(ConflictDocument.parse(doc.projection("result")).blocks.count == 1)
        precondition(doc.projection("result", choices: [0: .theirs]) == "before\r\ntheirs\r\nafter\r\n")
        var state = LocalWorkflowState(); let generation = state.generation; state.recovery = copies; state.reset()
        precondition(state.recovery.isEmpty && state.generation != generation)
        print("LocalWorkflows passed: safe paths and URLs, scoped recovery refs, three-way CRLF projections, unresolved markers and reset invalidation")
    }
}
SWIFT
TASK_CORE="$(bash "$ROOT/../tools/build-core-native.sh")"
swiftc -I "$ROOT/../crates/gitrochi-core/include" "$ROOT/Sources/Core/RustCore.swift" "$TASK_CORE" -parse-as-library "$ROOT/Sources/Core/LocalWorkflows.swift" "$ROOT/Sources/Core/Conflict.swift" "$TASK_TMP/main.swift" -o "$TASK_TMP/test-local-workflows"
"$TASK_TMP/test-local-workflows"
