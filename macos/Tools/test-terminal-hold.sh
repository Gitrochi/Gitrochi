#!/usr/bin/env bash
# Send synthetic key events only to this offscreen fixture; no microphone or global event access is used.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
cp "$ROOT/Sources/Services/TerminalHoldToTalk.swift" "$TASK_TMP/TerminalHoldToTalk.swift"
cp "$ROOT/Tools/fixtures/TerminalHoldEvents.swift" "$TASK_TMP/TerminalHoldEvents.swift"
swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos15.0" \
    -module-cache-path "${GITROCHI_TEST_MODULE_CACHE:-$TASK_TMP/module-cache}" \
    "$TASK_TMP/TerminalHoldToTalk.swift" "$TASK_TMP/TerminalHoldEvents.swift" \
    -o "$TASK_TMP/TerminalHoldEvents"
"$TASK_TMP/TerminalHoldEvents"
