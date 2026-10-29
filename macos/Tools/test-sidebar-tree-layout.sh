#!/usr/bin/env bash
# Check production branch rows and disclosure spacing without account or repository access.
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
icon = '                .frame(width: 16)\n'
assert row.count(icon) == 1, 'Branch icon measurement attachment changed'
row = row.replace(icon, icon + '                .background(TreeLayoutProbe(identifier: "icon:" + branch.name))\n')
label = '                .help(branch.name)\n'
assert row.count(label) == 1, 'Branch label measurement attachment changed'
row = row.replace(label, label + '                .background(TreeLayoutProbe(identifier: "label:" + branch.name))\n')
models = (root / 'Sources/Core/Models.swift').read_text()
branch = models[models.index('struct Branch: Identifiable, Hashable {'):models.index('\nstruct Tag:')]
(target / 'BranchRow.swift').write_text('import SwiftUI\ntypealias ViewState<Value> = SwiftUI.State<Value>\n' + branch + '\n' + row)
PY
xcrun swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos15.0" \
    "$ROOT/Sources/Views/Sidebar/SidebarTreeGroup.swift" \
    "$TASK_TMP/BranchRow.swift" "$ROOT/Tools/fixtures/SidebarTreeLayout.swift" \
    -o "$TASK_TMP/sidebar-tree-layout"
"$TASK_TMP/sidebar-tree-layout" "$TASK_OUTPUT"
