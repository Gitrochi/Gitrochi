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
for relative in ['Sources/Core/TerminalInput.swift', 'Sources/Core/TerminalVoiceAction.swift', 'Sources/Core/TerminalSpeechVocabulary.swift', 'Sources/Core/TerminalCleanupPolicy.swift', 'Sources/Services/TerminalTextCleanup.swift', 'Sources/Views/Shared/DesignIcon.swift', 'Sources/Views/Shared/DesignSymbols.swift', 'Sources/Views/TerminalChrome.swift', 'Tools/fixtures/TerminalLayout.swift']:
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
chrome.write_text(text.replace(needle, needle + '.background(TerminalLayoutProbe(identifier: "folder-copy"))'))

def instrument(text, needle, suffix):
    assert text.count(needle) == 1, 'Terminal voice probe changed: ' + needle
    return text.replace(needle, needle + '.background(TerminalLayoutProbe(identifier: "' + suffix + '"))')

text = (root / 'Sources/Views/TerminalDictationComposer.swift').read_text()
needle = '@ViewState private var destination = TerminalVoiceDestination.terminal'
assert text.count(needle) == 1, 'The initial voice destination changed'
text = text.replace(needle, '@ViewState private var destination = terminalLayoutInitialDestination')
for needle, suffix in [('.keyboardShortcut(.cancelAction)', 'composer-cancel'), ('.accessibilityLabel("Dictated text")', 'composer-editor'), ('.disabled(dictation.state != .listening)', 'composer-stop')]:
    text = instrument(text, needle, suffix)
for name, suffix in [('submit', 'composer-insert'), ('cleanup', 'composer-cleanup'), ('destination', 'composer-destination'), ('recovery', 'composer-recovery'), ('insertion-preview', 'composer-insertion-preview')]:
    text = instrument(text, '.accessibilityIdentifier("terminal-dictation-' + name + '")', suffix)
start = text.index('Button("Restore original")')
needle = '}.buttonStyle(.borderless).font(.caption)'
at = text.index(needle, start)
text = text[:at] + text[at:].replace(needle, needle + '.background(TerminalLayoutProbe(identifier: "composer-restore"))', 1)
assert text.count('TerminalBrand(compact: true)') == 1, 'The composer brand changed'
text = text.replace('TerminalBrand(compact: true)', 'TerminalBrand(compact: true, image: terminalLayoutIcon)')
assert text.count('NSWorkspace.shared.open(url)') == 1, 'The Settings recovery action changed'
text = text.replace('NSWorkspace.shared.open(url)', 'terminalLayoutOpenSettings(url)')
(target / 'TerminalDictationComposer.swift').write_text(text)
text = (root / 'Sources/Views/TerminalVoiceReview.swift').read_text()
needle = 'DisclosureGroup("Recognition hints")'
assert text.count(needle) == 1, 'The word-hint disclosure changed'
text = text.replace(needle, 'DisclosureGroup("Recognition hints", isExpanded: .constant(terminalLayoutShowVocabulary))')
for name, suffix in [('comparison', 'composer-comparison'), ('vocabulary', 'composer-vocabulary'), ('confirm-send', 'composer-confirm-send'), ('confirmation', 'composer-confirmation')]:
    text = instrument(text, '.accessibilityIdentifier("terminal-dictation-' + name + '")', suffix)
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
    "$TASK_TMP/TerminalInput.swift" "$TASK_TMP/TerminalVoiceAction.swift" "$TASK_TMP/TerminalSpeechVocabulary.swift" \
    "$TASK_TMP/TerminalCleanupPolicy.swift" "$TASK_TMP/TerminalTextCleanup.swift" "$TASK_TMP/TerminalChrome.swift" "$TASK_TMP/DesignIcon.swift" "$TASK_TMP/DesignSymbols.swift" \
    "$TASK_TMP/TerminalVoiceReview.swift" "$TASK_TMP/TerminalDictationComposer.swift" "$TASK_TMP/TerminalLayout.swift" \
    -o "$TASK_APP/Contents/MacOS/TerminalLayout"
for TASK_LANGUAGE in en ko; do
    "$TASK_APP/Contents/MacOS/TerminalLayout" "$TASK_OUTPUT" "$ROOT/Resources/AppIcon.icns" "$TASK_TMP/eyes.txt" "$TASK_LANGUAGE" -AppleLanguages "($TASK_LANGUAGE)"
done
