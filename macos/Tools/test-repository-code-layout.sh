#!/usr/bin/env bash
# Exercise the production reader with synthetic Git objects and capture both appearances. The History and Blame
# views read through the shared core's parsers, so the fixture links it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
TASK_OUTPUT="${1:-$(mktemp -d /tmp/gitrochi-code-layout.XXXXXX)}"
mkdir -p "$TASK_OUTPUT"
# A stable snapshot also lets the fixture submit through the real palette action without a global key event.
TASK_SOURCES=()
for TASK_SOURCE in \
    "$ROOT/Sources/Core/RustCore.swift" \
    "$ROOT/Sources/Core/Markdown.swift" \
    "$ROOT/Sources/Core/MarkdownInline.swift" \
    "$ROOT/Sources/Core/ProjectTaskReference.swift" \
    "$ROOT/Sources/Core/Models.swift" \
    "$ROOT/Sources/Core/Parsers.swift" \
    "$ROOT/Sources/Core/AppLanguage.swift" \
    "$ROOT/Sources/Core/RepositoryBrowser.swift" \
    "$ROOT/Sources/Core/RepositoryCodeHistory.swift" \
    "$ROOT/Sources/Core/RepositoryCodeReading.swift" \
    "$ROOT/Sources/Core/RepositoryCodeEditing.swift" \
    "$ROOT/Sources/Core/RepositoryCodeNavigation.swift" \
    "$ROOT/Sources/Core/RepositoryLanguages.swift" \
    "$ROOT/Sources/Services/ExternalEditors.swift" \
    "$ROOT/Sources/Services/RepositoryHTMLDocument.swift" \
    "$ROOT/Sources/Views/Shared/Theme.swift" \
    "$ROOT/Sources/Views/Shared/StudioStyle.swift" \
    "$ROOT/Sources/Views/Shared/StatusPill.swift" \
    "$ROOT/Sources/Views/Workbench/AdaptiveWorkbenchLayout.swift" \
    "$ROOT/Sources/Views/Workbench/RepositorySourceView.swift" \
    "$ROOT/Sources/Views/Workbench/RepositoryCodeReader.swift" \
    "$ROOT/Sources/Views/Workbench/RepositoryQuickOpen.swift" \
    "$ROOT/Sources/Views/Workbench/RepositoryLanguageSummary.swift" \
    "$ROOT/Sources/Views/Workbench/RepositoryExternalEditorMenu.swift" \
    "$ROOT/Sources/Views/Workbench/RepositoryHTMLPreview.swift" \
    "$ROOT/Sources/Views/Shared/DesignIcon.swift" "$ROOT/Sources/Views/Shared/PageControls.swift" "$ROOT/Sources/Core/ChangeQuestion.swift" "$ROOT/Sources/Core/ListDate.swift" "$ROOT/Sources/Views/Workbench/RepositoryCodeChangesView.swift" \
    "$ROOT/Sources/Views/Workbench/RepositoryCodeHistoryView.swift" \
    "$ROOT/Sources/Views/Workbench/RepositoryCodeBlameView.swift" \
    "$ROOT/Sources/Views/Workbench/RepositoryCodePanel.swift" \
    "$ROOT/Tools/fixtures/RepositoryCodeLayout.swift" \
    "$ROOT/Tools/fixtures/RepositoryHTMLLayout.swift"; do
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
# The fixture opens the first file on History or Blame, as choosing that tab would.
python3 - "$TASK_TMP/RepositoryCodePanel.swift" <<'PYTHON'
from pathlib import Path
import sys
path = Path(sys.argv[1])
source = path.read_text()
needle = 'revisionInput = "HEAD"; findText = ""; await loadTree() }'
assert source.count(needle) == 1, "The Code panel's first load changed"
replacement = 'revisionInput = "HEAD"; findText = ""; await loadTree(reopen: repositoryCodeLayoutView == nil ? nil : "src/Preview.swift", view: repositoryCodeLayoutView ?? "Source") }'
path.write_text(source.replace(needle, replacement))
PYTHON
TASK_APP="$TASK_TMP/RepositoryCodeLayout.app"
mkdir -p "$TASK_APP/Contents/MacOS"
cat > "$TASK_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.gitrochi.code-layout-fixture</string>
<key>CFBundleExecutable</key><string>RepositoryCodeLayout</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
TASK_CORE="$(bash "$ROOT/../tools/build-core-native.sh")"
swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos15.0" -I "$ROOT/../crates/gitrochi-core/include" \
    "${TASK_SOURCES[@]}" "$TASK_CORE" -o "$TASK_APP/Contents/MacOS/RepositoryCodeLayout"
"$TASK_APP/Contents/MacOS/RepositoryCodeLayout" "$TASK_OUTPUT"
