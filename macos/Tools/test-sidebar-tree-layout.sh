#!/usr/bin/env bash
# Check the Branches tab's field, production branch and tag rows, disclosure spacing, pinned branches, remotes and tags,
# hidden tags and the filter without account or repository access.
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
middle = source.index('/// A tag row,', start)
end = source.index('/// A sidebar section:', start)

def attach(text, anchor, probe, what):
    """Puts a probe after the one line that matches, so a change to the row fails here rather than measuring nothing"""
    assert text.count(anchor) == 1, what + ' measurement attachment changed'
    return text.replace(anchor, anchor.rstrip('\n') + probe + ('\n' if anchor.endswith('\n') else ''))

row = source[start:middle].replace('private struct BranchRow:', 'struct BranchRow:', 1)
row = attach(row, '                .frame(width: 13)\n', '\n                .background(TreeLayoutProbe(identifier: "icon:" + branch.name))', 'Branch icon')
row = attach(row, '                .help(branch.name)\n', '\n                .background(TreeLayoutProbe(identifier: "label:" + branch.name))', 'Branch label')
row = attach(row, 'CurrentMarker()', '.background(TreeLayoutProbe(identifier: "current:" + branch.name))', 'Current marker')
row = attach(row, 'PinnedMark()', '.background(TreeLayoutProbe(identifier: "pin:" + branch.name))', 'Pin mark')
row = attach(row, 'ShowAgainButton(action: showAgain)', '.background(TreeLayoutProbe(identifier: "eye:" + branch.name))', 'Eye')
# the production tag row and the marks both rows share
tag = source[middle:end].replace('private struct TagRow:', 'struct TagRow:', 1)
tag = attach(tag, '            DesignIconImage(icon: .releases, size: 13).foregroundStyle(StudioStyle.Rail.icon)\n', '\n                .background(TreeLayoutProbe(identifier: "icon:tag:" + tag.name))', 'Tag icon')
tag = attach(tag, '                .truncationMode(.tail)\n', '\n                .background(TreeLayoutProbe(identifier: "label:tag:" + tag.name))', 'Tag label')
tag = attach(tag, 'PinnedMark()', '.background(TreeLayoutProbe(identifier: "pin:tag:" + tag.name))', 'Tag pin')
tag = attach(tag, 'ShowAgainButton(action: showAgain)', '.background(TreeLayoutProbe(identifier: "eye:tag:" + tag.name))', 'Tag eye')
models = (root / 'Sources/Core/Models.swift').read_text()
branch = models[models.index('struct Branch: Identifiable, Hashable {'):models.index('\nstruct Stash:')]
(target / 'BranchRow.swift').write_text('import SwiftUI\ntypealias ViewState<Value> = SwiftUI.State<Value>\n' + branch + '\n' + row + tag)
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
