#!/usr/bin/env bash
# Exercise hint privacy, locale choice and app-local hold state without permission requests or audio.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
TASK_SOURCES=()
for TASK_SOURCE in \
    "$ROOT/Sources/Core/TerminalInput.swift" \
    "$ROOT/Sources/Core/TerminalSpeechVocabulary.swift" \
    "$ROOT/Sources/Services/TerminalDictation.swift" \
    "$ROOT/Sources/Services/TerminalHoldToTalk.swift" \
    "$ROOT/Tools/fixtures/TerminalVoiceTests.swift"; do
    TASK_TARGET="$TASK_TMP/$(basename "$TASK_SOURCE")"
    cp "$TASK_SOURCE" "$TASK_TARGET"
    TASK_SOURCES+=("$TASK_TARGET")
done
swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos15.0" \
    -module-cache-path "$TASK_TMP/module-cache" "${TASK_SOURCES[@]}" \
    -o "$TASK_TMP/TerminalVoiceTests"
"$TASK_TMP/TerminalVoiceTests"
