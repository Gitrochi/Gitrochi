#!/usr/bin/env bash
# Exercise the production reader with synthetic Git objects and capture both appearances.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
TASK_OUTPUT="${1:-$(mktemp -d /tmp/gitrochi-code-layout.XXXXXX)}"
mkdir -p "$TASK_OUTPUT"
# A stable snapshot also lets the fixture submit through the real palette action without a global key event.
TASK_SOURCES=()
for TASK_SOURCE in \
    "$ROOT/Sources/Core/RepositoryBrowser.swift" \
    "$ROOT/Sources/Core/RepositoryCodeReading.swift" \
    "$ROOT/Sources/Core/RepositoryCodeNavigation.swift" \
    "$ROOT/Sources/Views/Workbench/AdaptiveWorkbenchLayout.swift" \
    "$ROOT/Sources/Views/Workbench/RepositorySourceView.swift" \
    "$ROOT/Sources/Views/Workbench/RepositoryCodeReader.swift" \
    "$ROOT/Sources/Views/Workbench/RepositoryQuickOpen.swift" \
    "$ROOT/Sources/Views/Workbench/RepositoryCodePanel.swift" \
    "$ROOT/Tools/fixtures/RepositoryCodeLayout.swift"; do
    TASK_TARGET="$TASK_TMP/$(basename "$TASK_SOURCE")"
    cp "$TASK_SOURCE" "$TASK_TARGET"
    TASK_SOURCES+=("$TASK_TARGET")
done
python3 - "$TASK_TMP/RepositoryQuickOpen.swift" <<'PYTHON'
from pathlib import Path
import sys
path = Path(sys.argv[1])
source = path.read_text()
needle = '.onAppear { focused = true; results = RepositoryCodeNavigation.rankedPaths(paths, query: "", recent: recent); highlighted = results.first }'
assert source.count(needle) == 1, "Quick-open appearance setup changed"
replacement = needle[:-2] + """
            if repositoryCodeLayoutQuickScenario == "fresh-query" { query = "Preview"; activate() }
            if repositoryCodeLayoutQuickScenario == "keyboard" { move(1); activate() }
        }"""
path.write_text(source.replace(needle, replacement))
PYTHON
swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos15.0" \
    "${TASK_SOURCES[@]}" -o "$TASK_TMP/repository-code-layout"
"$TASK_TMP/repository-code-layout" "$TASK_OUTPUT"
