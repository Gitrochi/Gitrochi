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
s=(root/'Sources/Views/Workspace/PullRequestParts.swift').read_text();(target/'RequestAuthorAvatar.swift').write_text('import SwiftUI\n'+s[s.index('/// Hosting conversations use'):])
s=(root/'Sources/Views/Shared/HostingAvatar.swift').read_text().replace('AsyncImage(url: AvatarStore.shared.enabled ? avatarURL : nil)', 'IssueFixtureAvatarImage(url: AvatarStore.shared.enabled ? avatarURL : nil)');(target/'HostingAvatar.swift').write_text(s)
s=(root/'Sources/Services/HostingHub.swift').read_text();a=s.index('    static func safeAvatarURL(');b=s.index('    static func avatarURL(',a);(target/'HostingHubAPI.swift').write_text('import Foundation\n@MainActor enum HostingHubAPI {\n'+s[a:b]+'}\n')
s=(root/'Sources/Views/Shared/Theme.swift').read_text();a=s.index('enum Palette {');b=s.index('enum Fmt {',a);(target/'Palette.swift').write_text('import SwiftUI\n'+s[a:b])
s=(root/'Sources/Views/Inspector/IssueDevelopmentPanel.swift').read_text().replace('private var requests: [IssueLinkedRequest] = []','private var requests: [IssueLinkedRequest] = fixtureLinkedRequests').replace('private var page = 0','private var page = 1');(target/'IssueDevelopmentPanel.swift').write_text(s)
PY
swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos15.0" \
    "$ROOT/Sources/Core/Models.swift" "$ROOT/Sources/Core/ProjectTaskReference.swift" "$ROOT/Sources/Core/IssueWorkflow.swift" "$ROOT/Sources/Core/WorkState.swift" \
    "$ROOT/Sources/Core/Markdown.swift" "$ROOT/Sources/Core/MarkdownInline.swift" \
    "$ROOT/Sources/Core/IssuePage.swift" "$ROOT/Sources/Core/ListDate.swift" "$ROOT/Sources/Core/GitAccountPresentation.swift" \
    "$ROOT/Sources/Views/Shared/MarkdownView.swift" "$ROOT/Sources/Views/Shared/HostingDate.swift" \
    "$ROOT/Sources/Views/Shared/StudioStyle.swift" "$ROOT/Sources/Views/Shared/StatusPill.swift" "$ROOT/Sources/Views/Shared/DesignIcon.swift" "$ROOT/Sources/Views/Shared/DesignSymbols.swift" "$ROOT/Sources/Views/Shared/HostedList.swift" \
    "$ROOT/Sources/Views/Workbench/AdaptiveWorkbenchLayout.swift" "$ROOT/Sources/Views/Inspector/IssueDetailView.swift" \
    "$TASK_TMP/CollaborationModels.swift" "$TASK_TMP/InspectorScrollView.swift" "$TASK_TMP/IssueDevelopmentPanel.swift" \
    "$TASK_TMP/RequestAuthorAvatar.swift" "$TASK_TMP/HostingAvatar.swift" "$TASK_TMP/HostingHubAPI.swift" "$TASK_TMP/Palette.swift" \
    "$ROOT/Tools/fixtures/IssueWorkspaceLayout.swift" -o "$TASK_TMP/issue-layout"
"$TASK_TMP/issue-layout" "$TASK_OUTPUT"
