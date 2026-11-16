#!/usr/bin/env bash
# Check the Branches tab's field, production branch rows, disclosure spacing and filter without account or repository access.
# GITROCHI_SIDEBAR_TREE_LANGUAGE=ko renders the screenshots in that language.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
TASK_OUTPUT="${1:-$(mktemp -d /tmp/gitrochi-sidebar-tree.XXXXXX)}"
mkdir -p "$TASK_OUTPUT"
python3 - "$ROOT" "$TASK_TMP" <<'PY'
from pathlib import Path
import sys

root, target = map(Path, sys.argv[1:])
source = (root / 'Sources/Views/Sidebar/SidebarView.swift').read_text()
start = source.index('private struct BranchRow: View {')
end = source.index('/// A sidebar section:', start)
row = source[start:end].replace('private struct BranchRow:', 'struct BranchRow:', 1)
icon = '                .frame(width: 13)\n'
assert row.count(icon) == 1, 'Branch icon measurement attachment changed'
row = row.replace(icon, icon + '                .background(TreeLayoutProbe(identifier: "icon:" + branch.name))\n')
label = '                .help(branch.name)\n'
assert row.count(label) == 1, 'Branch label measurement attachment changed'
row = row.replace(label, label + '                .background(TreeLayoutProbe(identifier: "label:" + branch.name))\n')
models = (root / 'Sources/Core/Models.swift').read_text()
branch = models[models.index('struct Branch: Identifiable, Hashable {'):models.index('\nstruct Tag:')]
(target / 'BranchRow.swift').write_text('import SwiftUI\ntypealias ViewState<Value> = SwiftUI.State<Value>\n' + branch + '\n' + row)
# The empty form and the buttons it draws, without the rest of the hosted pages' parts.
hosted = (root / 'Sources/Views/Shared/HostedList.swift').read_text()
parts = hosted[hosted.index('enum HostedList {'):hosted.index('/// The row above the page:')]
empty = hosted[hosted.index('/// An empty or blocked page or column:'):hosted.index('/// A list on its way:')]
(target / 'HostedListEmpty.swift').write_text('import AppKit\nimport SwiftUI\n' + parts + empty)
PY
xcrun swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos15.0" \
    "$ROOT/Sources/Views/Shared/DesignIcon.swift" "$ROOT/Sources/Views/Shared/DesignSymbols.swift" "$ROOT/Sources/Views/Shared/StudioStyle.swift" \
    "$ROOT/Sources/Views/Shared/StatusPill.swift" "$ROOT/Sources/Views/Shared/CurrentMarker.swift" "$ROOT/Sources/Views/Shared/PageControls.swift" \
    "$ROOT/Sources/Views/Sidebar/SidebarTreeGroup.swift" "$ROOT/Sources/Views/Sidebar/SidebarFilterField.swift" "$ROOT/Sources/Core/BranchFilter.swift" \
    "$TASK_TMP/BranchRow.swift" "$TASK_TMP/HostedListEmpty.swift" "$ROOT/Tools/fixtures/SidebarTreeLayout.swift" \
    -o "$TASK_TMP/sidebar-tree-layout"
if [[ -n "${GITROCHI_SIDEBAR_TREE_LANGUAGE:-}" ]]; then
    # a bare executable reads its translations from the folder it is in
    cp -R "$ROOT/Resources/Localizations/$GITROCHI_SIDEBAR_TREE_LANGUAGE.lproj" "$TASK_TMP/"
    "$TASK_TMP/sidebar-tree-layout" "$TASK_OUTPUT" -AppleLanguages "($GITROCHI_SIDEBAR_TREE_LANGUAGE)"
else
    "$TASK_TMP/sidebar-tree-layout" "$TASK_OUTPUT"
fi
