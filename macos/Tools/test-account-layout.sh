#!/usr/bin/env bash
# Renders the production account button, its popover, the Add account sheet and Settings › Accounts off screen, with
# isolated defaults, fake credential reads and no network, and measures them: the badge only for the repository's own
# account, rows that wrap instead of squeezing, each state's own icon, an unreadable saved sign-in that is not called
# expired, and a failed approval shown next to the account it concerns.
#   macos/Tools/test-account-layout.sh [output folder for the screenshots]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
TASK_OUTPUT="${1:-$(mktemp -d "${TMPDIR:-/tmp}/gitrochi-account-layout.XXXXXX")}"
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

def probe(text, needle, identifier, label):
    return replace_once(text, needle, needle + '.background(AccountLayoutProbe(identifier: ' + identifier + '))', label)

for source in (root / 'Sources').rglob('*.swift'):
    relative = source.relative_to(root / 'Sources').as_posix()
    text = source.read_text().replace('UserDefaults.standard', 'accountFixtureDefaults')
    text = text.replace('defaults: UserDefaults = .standard', 'defaults: UserDefaults = accountFixtureDefaults')
    text = text.replace('URLSession.shared', 'accountFixtureSession')
    if relative == 'App/App.swift':
        start = text.index('@main\nstruct GitrochiApp: App {')
        end = text.index('/// 창(탭) 하나 = 저장소 하나', start)
        text = text[:start] + text[end:]
    elif relative == 'Services/Accounts.swift':
        text = replace_once(text, 'private let credentials = CredentialCache { await Keychain.read($0) }',
                            'private let credentials = CredentialCache { name in AccountFixtureNetworkBlocker.credentialRead(name) }', 'Credential reader')
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
    elif relative == 'Views/Shared/AccountPopover.swift':
        text = probe(text, '.frame(minHeight: size > 24 ? 52 : 44)', '"row:" + account.id', 'Account row')
        text = replace_once(text, '''            .frame(maxWidth: .infinity, alignment: .leading)
            if ownAction, busy {''', '''            .frame(maxWidth: .infinity, alignment: .leading).background(AccountLayoutProbe(identifier: "words:" + account.id))
            if ownAction, busy {''', 'Account row words')
        text = probe(text, 'Button(action) { resolve(account, status) }.buttonStyle(HostedListButtonStyle()).fixedSize()', '"action:" + account.id', 'Account row action')
        text = probe(text, '.accessibilityIdentifier("account-popover-change")', '"change"', 'Change menu')
        text = probe(text, '.accessibilityIdentifier("account-popover-identity")', '"identity"', 'Identity row')
        text = probe(text, '.accessibilityIdentifier("account-popover-refresh")', '"refresh"', 'Refresh account status')
        text = probe(text, 'title: String(localized: "Couldn\'t use the saved sign-in"), caption: failure)', '"failure:" + account.id', 'Account row failure')
        text = probe(text, '.frame(width: Self.width, alignment: .leading)', '"popover"', 'Popover width')
    elif relative == 'Views/Shared/AccountQuickControls.swift':
        text = probe(text, '.offset(x: 3, y: 3)', '"badge"', 'Warning badge')
    elif relative == 'Views/Shared/AccountStatusLabel.swift':
        text = probe(text, 'SymbolIcon(status.symbol).font(.system(size: 12)).accessibilityHidden(true)', '"status:" + status.symbol', 'Status icon')
        text = probe(text, 'SymbolIcon("lock").font(.system(size: 12)).accessibilityHidden(true)', '"status:lock"', 'Lock icon')
    elif relative == 'Views/Shared/NoticeBlock.swift':
        text = probe(text, 'NoticeButton(action: actions[index]).disabled(busy)', '"notice-action:" + actions[index].title', 'Notice action')
    elif relative == 'Views/Shared/SharedSheet.swift':
        text = probe(text, '.accessibilityIdentifier(primary.identifier ?? "shared-sheet-primary")', '"primary:" + primary.title', 'Sheet primary')
        text = probe(text, '.frame(width: width)', '"sheet"', 'Sheet width')
    elif relative == 'Views/Settings/AccountsSettings.swift':
        assert text.count('await Gitch.accounts()') == 2, 'Identity loading changed'
        text = text.replace('await Gitch.accounts()', 'accountFixtureIdentities')
        text = probe(text, 'AccountStatusPill(status: status)', '"settings-status:" + account.id', 'Settings status')
        text = probe(text, 'title: String(localized: "Couldn\'t use the saved sign-in"), caption: failure)', '"failure:" + account.id', 'Settings row failure')
        text = probe(text, '.accessibilityLabel("More actions for \\("@" + account.username)")', '"settings-more:" + account.id', 'Settings more menu')
        text = probe(text, '.accessibilityIdentifier(identifier)', 'identifier', 'Settings header action')
    dest = target / 'Sources' / relative
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(text)
PY
SOURCES=()
while IFS= read -r -d '' file; do SOURCES+=("$file"); done < <(find "$TASK_TMP/Sources" -name '*.swift' -print0)
TASK_CORE="$(CARGO_NET_OFFLINE=true bash "$ROOT/../tools/build-core-native.sh" "$ARCH")"
cp "$TASK_CORE" "$TASK_TMP/core.a"
cp "$ROOT/Tools/fixtures/AccountLayout.swift" "$TASK_TMP/AccountLayout.swift"
TASK_APP="$TASK_TMP/AccountLayoutFixture.app"
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources"
cat > "$TASK_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.gitrochi.account-layout-fixture</string>
<key>CFBundleExecutable</key><string>AccountLayout</string>
<key>CFBundleName</key><string>Gitrochi Account Layout Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
PLIST
xcrun swiftc -parse-as-library -swift-version 5 -whole-module-optimization -Onone -target "$ARCH-apple-macos15.0" \
    -I "$ST" -I "$ROOT/../crates/gitrochi-core/include" -L "$ST" -lSwiftTerm \
    "${SOURCES[@]}" "$TASK_TMP/AccountLayout.swift" "$TASK_TMP/core.a" \
    -o "$TASK_APP/Contents/MacOS/AccountLayout"
for TASK_SCENARIO in repository attention unreadable failed locked no-repository no-account settings add-account add-gitlab; do
    for TASK_APPEARANCE in light dark; do
        "$TASK_APP/Contents/MacOS/AccountLayout" "$TASK_OUTPUT" "$TASK_SCENARIO" "$TASK_APPEARANCE"
    done
done
echo "Account layout previews: $TASK_OUTPUT"
