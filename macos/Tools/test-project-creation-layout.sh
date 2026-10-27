#!/usr/bin/env bash
# Render the production creation chooser using isolated defaults, credentials, storage and read-only HTTP fixtures.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'if [[ -z "${GITROCHI_PROJECT_CREATION_KEEP_SOURCES:-}" ]]; then rm -rf "$TASK_TMP"; else echo "Fixture sources retained: $TASK_TMP" >&2; fi' EXIT
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
    text = source.read_text().replace('UserDefaults.standard', 'projectCreationFixtureDefaults')
    text = text.replace('defaults: UserDefaults = .standard', 'defaults: UserDefaults = projectCreationFixtureDefaults')
    text = text.replace('URLSession.shared', 'projectCreationFixtureSession')
    if relative == 'App/App.swift':
        start = text.index('@main\nstruct GitrochiApp: App {')
        end = text.index('/// 창(탭) 하나 = 저장소 하나', start)
        text = text[:start] + text[end:]
    elif relative == 'Services/Accounts.swift':
        text = replace_once(text, 'private let credentials = CredentialCache { await Keychain.read($0) }',
                            'private let credentials = CredentialCache { _ in ProjectCreationFixtureNetworkBlocker.credentialRead() }', 'Credential reader')
        text = text.replace('        Askpass.install()', '        // The isolated fixture never installs an authentication helper.')
        start = text.index('    private static func withInteraction(')
        end = text.index('\n    private static func copy(', start)
        text = text[:start] + '''    private static func withInteraction(_ allowed: Bool, operation: () -> CredentialReadResult) -> CredentialReadResult { operation() }
''' + text[end:]
    elif relative == 'Services/Tools.swift':
        start = text.index('    private init() {', text.index('final class ToolStore'))
        end = text.index('\n    func detect(', start)
        text = text[:start] + '''    private init() {
        states[.git] = State(path: "/usr/bin/git", source: .auto, version: "fixture")
    }
''' + text[end:]
    elif relative == 'Services/LocalProjects.swift':
        text = replace_once(text, 'static let shared = LocalProjectStore()',
                            'static let shared = LocalProjectStore(storage: ProjectCreationFixtureStorage())', 'In-memory local storage')
    elif relative == 'Views/Shared/SavedAccountAccessNotice.swift':
        text = replace_once(text, '}.disabled(allowing)',
                            '}.disabled(allowing).background(ProjectCreationProbe(identifier: "creation-restore-access"))',
                            'Saved-account restore action measurement')
        text = replace_once(text, 'Button("Account settings…") { openSettings() }',
                            'Button("Account settings…") { openSettings() }.background(ProjectCreationProbe(identifier: "creation-account-settings"))',
                            'Saved-account settings action measurement')
        text = replace_once(text, '}.frame(maxWidth: .infinity, alignment: .leading)',
                            '}.frame(maxWidth: .infinity, alignment: .leading).background(ProjectCreationProbe(identifier: "creation-saved-access-notice"))',
                            'Saved-account recovery notice measurement')
    elif relative == 'Views/Hub/ProjectCreationSheet.swift':
        text = replace_once(text, '@ViewState private var mode = "local"', '@ViewState private var mode = projectCreationFixtureMode', 'Initial scenario')
        text = replace_once(text, '@ViewState private var title = ""', '@ViewState private var title = "Desktop release"', 'Synthetic title')
        text = replace_once(text, '@ViewState private var summary = ""', '@ViewState private var summary = "A focused plan for the next desktop release."', 'Synthetic description')
        text = replace_once(text, '@ViewState private var review = false', '@ViewState private var review = projectCreationFixtureReview', 'Inline review scenario')
        text = replace_once(text, 'if review { creationReview } else { creationForm }',
                            'if review { creationReview.background(ProjectCreationProbe(identifier: "creation-review-content")) } else { creationForm }', 'Review content measurement')
        text = replace_once(text, '.accessibilityLabel("Project creation")',
                            '.accessibilityLabel("Project creation").background(ProjectCreationProbe(identifier: creationFixtureState))', 'Chooser state measurement')
        readiness = '.disabled(!ready).keyboardShortcut(.defaultAction)'
        assert text.count(readiness) == 2, 'Form and final creation buttons changed'
        text = text.replace(readiness, readiness + '.background(ProjectCreationProbe(identifier: "creation-review:" + String(ready)))')
        text = replace_once(text, '}.buttonStyle(.plain).accessibilityIdentifier("project-create-" + value)',
                            '}.buttonStyle(.plain).accessibilityIdentifier("project-create-" + value).background(ProjectCreationProbe(identifier: "creation-choice:" + value))', 'Choice measurement')
        text += '''
extension ProjectCreationSheet {
    fileprivate var creationFixtureState: String {
        ["creation-state", mode, String(ready), String(probing), String(accounts.count),
         capabilities?.accountPlan.tier.rawValue ?? "none", capabilities?.ownerPlan.tier.rawValue ?? "none",
         capabilities.map { String($0.limits.fields) } ?? "none",
         capabilities?.limits.autoAddWorkflows.map(String.init) ?? "unknown"].joined(separator: ":")
    }
}
'''
    dest = target / 'Sources' / relative
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(text)
PY
SOURCES=()
while IFS= read -r -d '' file; do SOURCES+=("$file"); done < <(find "$TASK_TMP/Sources" -name '*.swift' -print0)
TASK_CORE="$(CARGO_NET_OFFLINE=true bash "$ROOT/../tools/build-core-native.sh" "$ARCH")"
cp "$TASK_CORE" "$TASK_TMP/core.a"
cp "$ROOT/Tools/fixtures/ProjectCreationLayout.swift" "$TASK_TMP/ProjectCreationLayout.swift"
TASK_APP="$TASK_OUTPUT/ProjectCreationLayoutFixture.app"
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources"
cat > "$TASK_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.gitrochi.project-creation-fixture</string>
<key>CFBundleExecutable</key><string>ProjectCreationLayout</string>
<key>CFBundleName</key><string>Gitrochi Project Creation Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
PLIST
xcrun swiftc -parse-as-library -swift-version 5 -whole-module-optimization -Onone -target "$ARCH-apple-macos15.0" \
    -I "$ST" -I "$ROOT/../crates/gitrochi-core/include" -L "$ST" -lSwiftTerm \
    "${SOURCES[@]}" "$TASK_TMP/ProjectCreationLayout.swift" "$TASK_TMP/core.a" \
    -o "$TASK_APP/Contents/MacOS/ProjectCreationLayout"
for TASK_SCENARIO in local private-free public-pro unknown local-review private-free-review public-pro-review unknown-review unavailable authorization-required; do
    for TASK_APPEARANCE in light dark; do
        "$TASK_APP/Contents/MacOS/ProjectCreationLayout" "$TASK_OUTPUT" "$TASK_SCENARIO" "$TASK_APPEARANCE"
    done
done
