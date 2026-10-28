#!/usr/bin/env bash
# Check the actual columns without touching repositories, credentials or user preferences.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
xcrun swiftc -parse-as-library -swift-version 5 -O \
    "$ROOT/Sources/Views/Shared/WorkspaceColumns.swift" \
    "$ROOT/Tools/fixtures/InspectorVisibility.swift" \
    -o "$TASK_TMP/inspector-visibility"
"$TASK_TMP/inspector-visibility"
