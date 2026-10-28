#!/usr/bin/env bash
# Render the production release UI with in-memory repositories and no account access.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
TASK_OUTPUT="${1:-$(mktemp -d /tmp/gitrochi-release-layout.XXXXXX)}"
mkdir -p "$TASK_OUTPUT"
python3 - "$ROOT/Sources/Services/HostingHub.swift" "$TASK_TMP/HubModels.swift" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
Path(sys.argv[2]).write_text(source[:source.index('/// Every authenticated request')])
PY
swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos15.0" \
    "$ROOT/Sources/Core/Models.swift" "$ROOT/Sources/Core/ProjectTaskReference.swift" \
    "$ROOT/Sources/Core/Markdown.swift" "$ROOT/Sources/Core/MarkdownInline.swift" \
    "$ROOT/Sources/Core/ReleaseCatalog.swift" "$ROOT/Sources/Views/Shared/MarkdownView.swift" \
    "$ROOT/Sources/Views/Workbench/AdaptiveWorkbenchLayout.swift" \
    "$ROOT/Sources/Views/Hub/ReleaseWorkspace.swift" "$TASK_TMP/HubModels.swift" \
    "$ROOT/Tools/fixtures/ReleaseWorkspaceLayout.swift" -o "$TASK_TMP/release-layout"
"$TASK_TMP/release-layout" "$TASK_OUTPUT"
