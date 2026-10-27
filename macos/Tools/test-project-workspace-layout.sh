#!/usr/bin/env bash
# Render the production Projects workspace with isolated, synthetic account and project data.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'if [[ -z "${GITROCHI_PROJECT_LAYOUT_KEEP_SOURCES:-}" ]]; then rm -rf "$TASK_TMP"; else echo "Fixture sources retained: $TASK_TMP" >&2; fi' EXIT
TASK_OUTPUT="${1:-$TASK_TMP/output}"
mkdir -p "$TASK_OUTPUT"
ARCH="$(uname -m)"
ST="$ROOT/.build/swiftterm/$ARCH"
if [[ ! -f "$ST/libSwiftTerm.a" ]]; then
    echo "SwiftTerm build is missing; run macos/build.sh first." >&2
    exit 1
fi
python3 - "$ROOT" "$TASK_TMP" <<'PY'
from pathlib import Path
import sys

root, target = map(Path, sys.argv[1:])

def replace_once(text, needle, replacement, label):
    assert text.count(needle) == 1, label + ' changed'
    return text.replace(needle, replacement)

for source in (root / 'Sources').rglob('*.swift'):
    relative = source.relative_to(root / 'Sources').as_posix()
    text = source.read_text().replace('UserDefaults.standard', 'projectFixtureDefaults')
    if relative == 'App/App.swift':
        start = text.index('@main\nstruct GitrochiApp: App {')
        end = text.index('/// 창(탭) 하나 = 저장소 하나', start)
        text = text[:start] + text[end:]
    elif relative == 'Services/Accounts.swift':
        text = replace_once(text, 'private let credentials = CredentialCache { await Keychain.read($0) }',
                            'private let credentials = CredentialCache { _ in CredentialReadResult(value: "fixture-credential", status: 0) }',
                            'Account credential reader')
        text = text.replace('        Askpass.install()', '        // Rendering never installs a credential helper.')
    elif relative == 'Services/Tools.swift':
        start = text.index('    private init() {', text.index('final class ToolStore'))
        end = text.index('\n    func detect(', start)
        text = text[:start] + '''    private init() {
        states[.git] = State(path: "/usr/bin/git", source: .auto, version: "fixture")
    }
''' + text[end:]
    elif relative == 'Views/Hub/ProjectWorkspace.swift':
        text = replace_once(text, '}.padding(.horizontal, 24).padding(.vertical, 19)',
                            '}.padding(.horizontal, 24).padding(.vertical, 19)\n            .background(ProjectWorkspaceProbe(identifier: "project-header"))',
                            'Project header measurement attachment')
        text = replace_once(text, '}.accessibilityLabel("Project board")',
                            '}.accessibilityLabel("Project board")\n                .background(ProjectWorkspaceProbe(identifier: "project-board"))',
                            'Project board measurement attachment')
        text = replace_once(text, '}.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 14).disabled(locked)',
                            '}.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 14).disabled(locked)\n            .background(ProjectWorkspaceProbe(identifier: "project-controls"))',
                            'Project controls measurement attachment')
        text = replace_once(text, '.background(Color.accentColor, in: RoundedRectangle(cornerRadius: 9)).disabled(locked || hub.uncertainWrite)',
                            '.background(Color.accentColor, in: RoundedRectangle(cornerRadius: 9)).background(ProjectWorkspaceProbe(identifier: "project-add-item")).disabled(locked || hub.uncertainWrite)',
                            'Project add-item measurement attachment')
    elif relative == 'Views/Hub/ProjectTaskViews.swift':
        text = replace_once(text, '}.buttonStyle(.plain).accessibilityLabel(row.title)',
                            '}.buttonStyle(.plain).background(ProjectWorkspaceProbe(identifier: "task:" + row.id)).accessibilityLabel(row.title)',
                            'Project card measurement attachment')
        text = replace_once(text, '.overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.1)))',
                            '.overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.1)))\n        .background(ProjectWorkspaceProbe(identifier: "column:" + column.id))',
                            'Project column measurement attachment')
    dest = target / 'Sources' / relative
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(text)
PY
SOURCES=()
while IFS= read -r -d '' file; do SOURCES+=("$file"); done < <(find "$TASK_TMP/Sources" -name '*.swift' -print0)
TASK_CORE="$(CARGO_NET_OFFLINE=true bash "$ROOT/../tools/build-core-native.sh" "$ARCH")"
cp "$TASK_CORE" "$TASK_TMP/core.a"
cp "$ROOT/Tools/fixtures/ProjectWorkspaceLayout.swift" "$TASK_TMP/ProjectWorkspaceLayout.swift"
TASK_APP="$TASK_OUTPUT/ProjectWorkspaceLayoutFixture.app"
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources"
cat > "$TASK_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.gitrochi.project-workspace-fixture</string>
<key>CFBundleExecutable</key><string>ProjectWorkspaceLayout</string>
<key>CFBundleName</key><string>Gitrochi Project Workspace Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
PLIST
xcrun swiftc -parse-as-library -swift-version 5 -whole-module-optimization -Onone -target "$ARCH-apple-macos15.0" \
    -I "$ST" -I "$ROOT/../crates/gitrochi-core/include" -L "$ST" -lSwiftTerm \
    "${SOURCES[@]}" "$TASK_TMP/ProjectWorkspaceLayout.swift" "$TASK_TMP/core.a" \
    -o "$TASK_APP/Contents/MacOS/ProjectWorkspaceLayout"
"$TASK_APP/Contents/MacOS/ProjectWorkspaceLayout" "$TASK_OUTPUT"
