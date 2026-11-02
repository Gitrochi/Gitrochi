#!/usr/bin/env bash
# Check production voice presentation and cancellation with inert action and microphone boundaries.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
TASK_SOURCES=()
for TASK_SOURCE in \
    "$ROOT/Sources/Core/TerminalInput.swift" \
    "$ROOT/Sources/Core/TerminalVoiceAction.swift" \
    "$ROOT/Sources/Core/TerminalSpeechVocabulary.swift" \
    "$ROOT/Sources/Services/TerminalHoldToTalk.swift" \
    "$ROOT/Sources/Services/TerminalVoiceCoordinator.swift" \
    "$ROOT/Tools/fixtures/TerminalVoiceCoordinatorTests.swift"; do
    TASK_COPY="$TASK_TMP/$(basename "$TASK_SOURCE")"
    cp "$TASK_SOURCE" "$TASK_COPY"
    TASK_SOURCES+=("$TASK_COPY")
done
swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos15.0" \
    -module-cache-path "$TASK_TMP/module-cache" "${TASK_SOURCES[@]}" \
    -o "$TASK_TMP/TerminalVoiceCoordinatorTests"
# These read-only argument-domain preferences do not change Gitrochi's saved settings.
"$TASK_TMP/TerminalVoiceCoordinatorTests" -terminalDictationLocale ko-KR -appLanguage ko \
    -terminalDictationUseRepositoryWords YES -terminalDictationWords "FixtureTerm, 라우터"
