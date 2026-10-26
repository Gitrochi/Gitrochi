#!/usr/bin/env bash
# 실제 NavigationSplitView의 접힘·자동 배치와 아이콘 탐색 조건, 작업 상태 보존을 함께 확인한다.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
xcrun swiftc -parse-as-library -swift-version 5 -O \
    "$ROOT/Sources/Views/Shared/SidebarVisibilityObserver.swift" \
    "$ROOT/Sources/Views/Shared/SidebarPresentationState.swift" \
    "$ROOT/Tools/fixtures/SidebarVisibility.swift" \
    -o "$TASK_TMP/sidebar-visibility"
"$TASK_TMP/sidebar-visibility"
