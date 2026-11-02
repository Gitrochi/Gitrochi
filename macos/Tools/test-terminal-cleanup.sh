#!/usr/bin/env bash
# Validate dictation cleanup and cancellation with an injected client; no provider or microphone is contacted.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
swiftc -parse-as-library -swift-version 5 -module-cache-path "$TASK_TMP/module-cache" \
    "$ROOT/Sources/Core/TerminalCleanupPolicy.swift" \
    "$ROOT/Sources/Services/TerminalTextCleanup.swift" \
    "$ROOT/Tools/fixtures/TerminalCleanupTests.swift" \
    -o "$TASK_TMP/TerminalCleanupTests"
"$TASK_TMP/TerminalCleanupTests"
