#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
cat > "$TASK_TMP/main.swift" <<'SWIFT'
import Foundation
@main struct ConfirmationTests {
    @MainActor static func main() async {
        let gate = RepositoryConfirmationGuard()
        var path: String? = "repo", count = 0
        let first = gate.wrap(path: path, currentPath: { path }) { count += 1 }
        await first(); await first(); precondition(count == 1)
        let switched = gate.wrap(path: path, currentPath: { path }) { count += 1 }
        path = "other"; await switched(); precondition(count == 1)
        path = "repo"
        let reopened = gate.wrap(path: path, currentPath: { path }) { count += 1 }
        gate.invalidate(); await reopened(); precondition(count == 1)
        let fresh = gate.wrap(path: path, currentPath: { path }) { count += 1 }
        await fresh(); precondition(count == 2)
        let noRepo = gate.wrap(path: nil, currentPath: { path }) { count += 1 }
        await noRepo(); precondition(count == 2)
        print("Confirmation guard passed: one execution, repository switch, same-path reopen and fresh-session confirmation")
    }
}
SWIFT
swiftc -parse-as-library -swift-version 5 "$ROOT/Sources/Core/RepositoryConfirmationGuard.swift" "$TASK_TMP/main.swift" -o "$TASK_TMP/confirm-tests"
"$TASK_TMP/confirm-tests"
