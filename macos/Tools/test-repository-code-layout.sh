#!/usr/bin/env bash
# Exercise the production reader with synthetic Git objects and capture both appearances.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
TASK_OUTPUT="${1:-$(mktemp -d /tmp/gitrochi-code-layout.XXXXXX)}"
mkdir -p "$TASK_OUTPUT"
swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos15.0" \
    "$ROOT/Sources/Core/RepositoryBrowser.swift" \
    "$ROOT/Sources/Core/RepositoryCodeReading.swift" \
    "$ROOT/Sources/Views/Shared/StudioStyle.swift" \
    "$ROOT/Sources/Views/Workbench/AdaptiveWorkbenchLayout.swift" \
    "$ROOT/Sources/Views/Workbench/RepositorySourceView.swift" \
    "$ROOT/Sources/Views/Workbench/RepositoryCodeReader.swift" \
    "$ROOT/Sources/Views/Workbench/RepositoryCodePanel.swift" \
    "$ROOT/Tools/fixtures/RepositoryCodeLayout.swift" \
    -o "$TASK_TMP/repository-code-layout"
"$TASK_TMP/repository-code-layout" "$TASK_OUTPUT"
