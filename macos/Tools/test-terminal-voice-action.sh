#!/usr/bin/env bash
# Exercise real voice routing against inert repository, AI and agent boundaries.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
swiftc -parse-as-library -swift-version 5 -module-cache-path "$TASK_TMP/module-cache" \
    "$ROOT/Sources/Core/TerminalInput.swift" \
    "$ROOT/Sources/Core/TerminalVoiceAction.swift" \
    "$ROOT/Sources/Services/AIPrompts.swift" \
    "$ROOT/Sources/Store/RepoStore+TerminalVoice.swift" \
    "$ROOT/Tools/fixtures/TerminalVoiceActionTests.swift" \
    -o "$TASK_TMP/TerminalVoiceActionTests"
"$TASK_TMP/TerminalVoiceActionTests"
