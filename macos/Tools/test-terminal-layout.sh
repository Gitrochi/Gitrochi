#!/usr/bin/env bash
# Exercise production terminal and voice views with inert recording and an injected local AI fixture.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'if [[ -z "${GITROCHI_TERMINAL_LAYOUT_KEEP_SOURCES:-}" ]]; then rm -rf "$TASK_TMP"; else echo "Fixture sources retained: $TASK_TMP" >&2; fi' EXIT
TASK_OUTPUT="${1:-$(mktemp -d /tmp/gitrochi-terminal-layout.XXXXXX)}"
mkdir -p "$TASK_OUTPUT"
python3 - "$ROOT" "$TASK_TMP" <<'PY'
from pathlib import Path
import re
import sys
root, target = map(Path, sys.argv[1:])
for relative in ['Sources/Core/TerminalPanelLayout.swift', 'Sources/Core/TerminalInput.swift', 'Sources/Core/TerminalVoiceAction.swift', 'Sources/Core/TerminalSpeechVocabulary.swift', 'Sources/Core/TerminalCleanupPolicy.swift', 'Sources/Services/TerminalTextCleanup.swift', 'Sources/Views/Shared/DesignIcon.swift', 'Sources/Views/Shared/DesignSymbols.swift', 'Sources/Views/Shared/StudioStyle.swift', 'Sources/Views/Shared/SharedSheet.swift', 'Sources/Views/Shared/NoticeBlock.swift', 'Sources/Views/Shared/PageControls.swift', 'Sources/Views/TerminalChrome.swift', 'Tools/fixtures/TerminalLayout.swift']:
    source = root / relative
    (target / source.name).write_bytes(source.read_bytes())
service = (root / 'Sources/Services/TerminalDictation.swift').read_text()
start = service.index('    enum Recovery: Equatable {')
end, depth = start, 0
for at in range(service.index('{', start), len(service)):
    if service[at] == '{': depth += 1
    elif service[at] == '}':
        depth -= 1
        if depth == 0:
            end = at + 1
            break
fixture = target / 'TerminalLayout.swift'
fixture.write_text(fixture.read_text().replace('    /* TERMINAL_DICTATION_RECOVERY */', service[start:end]))
chrome = target / 'TerminalChrome.swift'
text = chrome.read_text()
needle = '.accessibilityValue(Text(verbatim: directory))'
assert text.count(needle) == 1, 'The folder copy control changed'
text = text.replace(needle, needle + '.background(TerminalLayoutProbe(identifier: "folder-copy"))')
# the tab bar's own controls are measured where production draws them
for name in ['tabs', 'overflow', 'new', 'voice', 'actions', 'hide', 'commands']:
    needle = '.accessibilityIdentifier("terminal-' + name + '")'
    assert text.count(needle) == 1, 'The terminal tab bar changed: ' + name
    text = text.replace(needle, needle + '.background(TerminalLayoutProbe(identifier: "' + name + '"))')
assert 'TerminalBrand' not in text[text.index('struct TerminalTabBar'):text.index('struct TerminalSessionTab')], 'The tab bar has no logo'
chrome.write_text(text)

def instrument(text, needle, suffix):
    assert text.count(needle) == 1, 'Terminal voice probe changed: ' + needle
    return text.replace(needle, needle + '.background(TerminalLayoutProbe(identifier: "' + suffix + '"))')

text = (root / 'Sources/Views/TerminalDictationComposer.swift').read_text()
needle = '@ViewState private var destination = TerminalVoiceDestination.terminal'
assert text.count(needle) == 1, 'The initial voice destination changed'
text = text.replace(needle, '@ViewState private var destination = terminalLayoutInitialDestination')
for needle, suffix in [('.accessibilityLabel("Your draft")', 'composer-editor'), ('.disabled(dictation.state != .listening)', 'composer-stop')]:
    text = instrument(text, needle, suffix)
for name in ['cleanup', 'cleanup-failure', 'restore', 'destination', 'recovery', 'insertion-preview', 'confirmation']:
    text = instrument(text, '.accessibilityIdentifier("terminal-dictation-' + name + '")', 'composer-' + name)
assert text.count('NSWorkspace.shared.open(url)') == 1, 'The Settings recovery action changed'
text = text.replace('NSWorkspace.shared.open(url)', 'terminalLayoutOpenSettings(url)')
(target / 'TerminalDictationComposer.swift').write_text(text)
# The shared sheet draws the composer's header and footer; the notice file brings the failure blocks and the reason
# beside a disabled primary.
sheet = target / 'SharedSheet.swift'
text = sheet.read_text()
text = instrument(text, '.accessibilityIdentifier("shared-sheet-cancel")', 'composer-cancel')
text = instrument(text, '.accessibilityIdentifier(primary.identifier ?? "shared-sheet-primary")', 'composer-insert')
sheet.write_text(text)
notice = target / 'NoticeBlock.swift'
notice.write_text(instrument(notice.read_text(), '.disabledReason(action.disabledReason)', 'composer-notice-action'))
# The 28 pt button and the caption grey, without the hosted pages the rest of the file draws
text = (root / 'Sources/Views/Shared/HostedList.swift').read_text()
(target / 'HostedList.swift').write_text('import AppKit\nimport SwiftUI\n\n' + text[text.index('enum HostedList {'):text.index('/// A 12 pt grey text button')])
text = (root / 'Sources/Views/TerminalVoiceReview.swift').read_text()
needle = '@ViewState private var expanded = false'
assert text.count(needle) == 1, 'The word-hint disclosure changed'
text = text.replace(needle, '@ViewState private var expanded = terminalLayoutShowVocabulary')
for name in ['comparison', 'discard', 'vocabulary']:
    text = instrument(text, '.accessibilityIdentifier("terminal-dictation-' + name + '")', 'composer-' + name)
text = instrument(text, '.disabled(!canApply)', 'composer-use-cleaned')
text = instrument(text, '.accessibilityLabel("Custom recognition words")', 'composer-custom-words')
(target / 'TerminalVoiceReview.swift').write_text(text)
cli = (root.parent / 'tools/gitch/gitch').read_text()
match = re.search(r"LOGO_S=\(\n(.*?)\n\)", cli, re.S)
assert match, 'The original CLI eye logo is missing'
rows = re.findall(r"^  '(.*)'$", match.group(1), re.M)
assert len(rows) == 3, 'The small CLI eye logo must contain three rows'
(target / 'eyes.txt').write_text('\n'.join(rows))
PY
TASK_APP="$TASK_TMP/TerminalLayoutFixture.app"
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources"
cat > "$TASK_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.gitrochi.terminal-voice-layout-fixture</string>
<key>CFBundleExecutable</key><string>TerminalLayout</string>
<key>CFBundleName</key><string>Gitrochi Voice Layout Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>ko</string></array>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
PLIST
cp -R "$ROOT/Resources/Localizations/ko.lproj" "$TASK_APP/Contents/Resources/"
swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos15.0" \
    -module-cache-path "${GITROCHI_TERMINAL_LAYOUT_MODULE_CACHE:-$TASK_TMP/module-cache}" \
    "$TASK_TMP/TerminalPanelLayout.swift" "$TASK_TMP/TerminalInput.swift" "$TASK_TMP/TerminalVoiceAction.swift" "$TASK_TMP/TerminalSpeechVocabulary.swift" \
    "$TASK_TMP/TerminalCleanupPolicy.swift" "$TASK_TMP/TerminalTextCleanup.swift" "$TASK_TMP/StudioStyle.swift" "$TASK_TMP/HostedList.swift" "$TASK_TMP/NoticeBlock.swift" "$TASK_TMP/PageControls.swift" "$TASK_TMP/SharedSheet.swift" "$TASK_TMP/TerminalChrome.swift" "$TASK_TMP/DesignIcon.swift" "$TASK_TMP/DesignSymbols.swift" \
    "$TASK_TMP/TerminalVoiceReview.swift" "$TASK_TMP/TerminalDictationComposer.swift" "$TASK_TMP/TerminalLayout.swift" \
    -o "$TASK_APP/Contents/MacOS/TerminalLayout"
for TASK_LANGUAGE in en ko; do
    "$TASK_APP/Contents/MacOS/TerminalLayout" "$TASK_OUTPUT" "$ROOT/Resources/AppIcon.icns" "$TASK_TMP/eyes.txt" "$TASK_LANGUAGE" -AppleLanguages "($TASK_LANGUAGE)"
done
