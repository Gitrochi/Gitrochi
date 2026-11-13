#!/usr/bin/env bash
# Renders the production shared sheet layout off screen, in light and dark, and measures it: the header's padding and
# type sizes, the footer's order, the reason 8 pt before a disabled primary, and a size that follows the content (the
# system's sheet, which shows it on macOS, takes that size).
#   macos/Tools/test-shared-sheet-layout.sh [output folder for the screenshots]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
TASK_OUTPUT="${1:-$(mktemp -d "${TMPDIR:-/tmp}/gitrochi-shared-sheet-layout.XXXXXX")}"
mkdir -p "$TASK_OUTPUT"
python3 - "$ROOT" "$TASK_TMP" <<'PY'
from pathlib import Path
import sys
root, target = map(Path, sys.argv[1:])
for relative in ['Sources/Views/Shared/StudioStyle.swift', 'Tools/fixtures/SharedSheetLayout.swift']:
    source = root / relative
    (target / source.name).write_bytes(source.read_bytes())

def instrument(text, needle, suffix):
    assert text.count(needle) == 1, 'Shared sheet probe changed: ' + needle
    return text.replace(needle, needle + '.background(SheetLayoutProbe(identifier: "' + suffix + '"))')

text = (root / 'Sources/Views/Shared/SharedSheet.swift').read_text()
for needle, suffix in [('.accessibilityIdentifier("shared-sheet-title")', 'title'), ('.accessibilityIdentifier("shared-sheet-context")', 'context'),
                       ('.accessibilityIdentifier("shared-sheet-cancel")', 'cancel'), ('.accessibilityIdentifier(primary.identifier ?? "shared-sheet-primary")', 'primary')]:
    text = instrument(text, needle, suffix)
# the reason beside a disabled primary comes from the notice file
notice = (root / 'Sources/Views/Shared/NoticeBlock.swift').read_text()
reason = instrument(notice[notice.index('/// A disabled button says why'):], '.accessibilityHidden(true)', 'reason')
text += '\n' + reason
assert text.count('HostedList.caption') == 2, 'The sheet caption colour changed'
(target / 'SharedSheet.swift').write_text(text.replace('HostedList.caption', 'StudioStyle.Rail.icon'))
PY
swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos15.0" \
    -module-cache-path "${GITROCHI_SHARED_SHEET_LAYOUT_MODULE_CACHE:-$TASK_TMP/module-cache}" \
    "$TASK_TMP/StudioStyle.swift" "$TASK_TMP/SharedSheet.swift" "$TASK_TMP/SharedSheetLayout.swift" \
    -o "$TASK_TMP/SharedSheetLayout"
"$TASK_TMP/SharedSheetLayout" "$TASK_OUTPUT"
