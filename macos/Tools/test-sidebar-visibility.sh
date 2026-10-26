#!/usr/bin/env bash
# Check native sidebar transitions, navigation access and retained detail state.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
xcrun swiftc -parse-as-library -swift-version 5 -Onone \
    "$ROOT/Sources/Views/Shared/SidebarVisibilityObserver.swift" \
    "$ROOT/Sources/Views/Shared/SidebarPresentationState.swift" \
    "$ROOT/Tools/fixtures/SidebarVisibility.swift" \
    -o "$TASK_TMP/sidebar-visibility"
"$TASK_TMP/sidebar-visibility"
