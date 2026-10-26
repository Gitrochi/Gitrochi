#!/usr/bin/env bash
# 실제 반응형 분할 화면의 자식 State가 창 크기 전환에도 보존되는지 확인한다. 계정·저장소·사용자 설정은 쓰지 않는다.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
xcrun swiftc -parse-as-library -swift-version 5 -O \
    "$ROOT/Sources/Views/Workbench/AdaptiveWorkbenchLayout.swift" \
    "$ROOT/Tools/fixtures/AdaptiveWorkbenchIdentity.swift" \
    -o "$TASK_TMP/adaptive-workbench-identity"
"$TASK_TMP/adaptive-workbench-identity"
