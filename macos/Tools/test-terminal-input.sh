#!/usr/bin/env bash
# Check reviewed terminal input and cancellation races without recording or requesting permissions.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
swiftc -parse-as-library -swift-version 5 -module-cache-path "$TASK_TMP/module-cache" \
    "$ROOT/Sources/Core/TerminalInput.swift" \
    "$ROOT/Tools/fixtures/TerminalInputTests.swift" \
    -o "$TASK_TMP/TerminalInputTests"
"$TASK_TMP/TerminalInputTests"
