#!/usr/bin/env bash
# Render production issue components with isolated in-memory data and no network or credentials.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
TASK_OUTPUT="${1:-$(mktemp -d /tmp/gitrochi-issue-layout.XXXXXX)}"
mkdir -p "$TASK_OUTPUT"
python3 - "$ROOT" "$TASK_TMP" <<'PY'
from pathlib import Path
import sys
root,target=map(Path,sys.argv[1:])
s=(root/'Sources/Services/Collaboration.swift').read_text();(target/'CollaborationModels.swift').write_text(s[:s.index('/// 호스팅 서버')])
s=(root/'Sources/Views/Shared/Theme.swift').read_text();a=s.index('struct InspectorScrollView<');b=s.index('/// +12',a);(target/'InspectorScrollView.swift').write_text('import SwiftUI\n'+s[a:b])
s=(root/'Sources/Views/Inspector/IssueDevelopmentPanel.swift').read_text().replace('private var requests: [IssueLinkedRequest] = []','private var requests: [IssueLinkedRequest] = fixtureLinkedRequests').replace('private var page = 0','private var page = 1');(target/'IssueDevelopmentPanel.swift').write_text(s)
PY
swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos15.0" \
    "$ROOT/Sources/Core/Models.swift" "$ROOT/Sources/Core/ProjectTaskReference.swift" "$ROOT/Sources/Core/IssueWorkflow.swift" "$ROOT/Sources/Core/WorkState.swift" \
    "$ROOT/Sources/Core/Markdown.swift" "$ROOT/Sources/Core/MarkdownInline.swift" \
    "$ROOT/Sources/Views/Shared/MarkdownView.swift" "$ROOT/Sources/Views/Shared/HostingDate.swift" \
    "$ROOT/Sources/Views/Workbench/AdaptiveWorkbenchLayout.swift" "$ROOT/Sources/Views/Inspector/IssueDetailView.swift" \
    "$TASK_TMP/CollaborationModels.swift" "$TASK_TMP/InspectorScrollView.swift" "$TASK_TMP/IssueDevelopmentPanel.swift" \
    "$ROOT/Tools/fixtures/IssueWorkspaceLayout.swift" -o "$TASK_TMP/issue-layout"
"$TASK_TMP/issue-layout" "$TASK_OUTPUT"
