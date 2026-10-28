#!/usr/bin/env bash
# Check narrow and wide production Markdown rendering in light and dark appearances.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
TASK_OUTPUT="${1:-$(mktemp -d /tmp/gitrochi-markdown-layout.XXXXXX)}"
mkdir -p "$TASK_OUTPUT"
swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos15.0" \
    "$ROOT/Sources/Core/Markdown.swift" "$ROOT/Sources/Core/MarkdownInline.swift" \
    "$ROOT/Sources/Core/Models.swift" "$ROOT/Sources/Core/ProjectTaskReference.swift" \
    "$ROOT/Sources/Views/Shared/MarkdownView.swift" \
    "$ROOT/Tools/fixtures/MarkdownLayout.swift" -o "$TASK_TMP/markdown-layout"
"$TASK_TMP/markdown-layout" "$TASK_OUTPUT"
