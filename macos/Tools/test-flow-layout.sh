#!/usr/bin/env bash
# Capture production flow authoring views with a real engine and an explicitly isolated Git worktree.
# Usage: macos/Tools/test-flow-layout.sh OUTPUT FIXTURE_REPOSITORY
# The repository must contain a .gitrochi-flow-layout-fixture marker with the text flow-layout-fixture.
# Only the synthetic .gitch/flow.yml and scripts/check.sh in that owned fixture are replaced; nothing runs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
TASK_OUTPUT="${1:?Provide a screenshot output folder.}"
TASK_REPO="${2:?Provide an isolated Git worktree with the flow-layout-fixture marker.}"
[[ -f "$TASK_REPO/.gitrochi-flow-layout-fixture" && "$(cat "$TASK_REPO/.gitrochi-flow-layout-fixture")" == flow-layout-fixture ]] || {
    echo 'Refusing to write outside an explicitly marked flow layout fixture.' >&2; exit 1;
}
TASK_REPO="$(cd "$TASK_REPO" && pwd -P)"
TASK_TOP="$(cd "$TASK_REPO" && gitch git rev-parse --show-toplevel)"
[[ "$TASK_TOP" == "$TASK_REPO" ]] || { echo 'The fixture must be the Git worktree root.' >&2; exit 1; }
TASK_COMMON="$(cd "$TASK_REPO" && gitch git rev-parse --git-common-dir)"
[[ "$TASK_COMMON" == /* ]] || TASK_COMMON="$TASK_REPO/$TASK_COMMON"
mkdir -p "$TASK_OUTPUT"
TASK_OUTPUT="$(cd "$TASK_OUTPUT" && pwd -P)"
ARCH="$(uname -m)"
ST="${GITROCHI_SWIFTTERM_DIR:-$ROOT/.build/swiftterm/$ARCH}"
[[ -f "$ST/libSwiftTerm.a" ]] || { echo 'Run macos/build.sh once to build SwiftTerm.' >&2; exit 1; }
TASK_ENGINE="${GITROCHI_FLOW_ENGINE:-$ROOT/build/Gitrochi.app/Contents/MacOS/gitch-flow}"
[[ -x "$TASK_ENGINE" ]] || { echo 'Run macos/build.sh once to build the current flow engine.' >&2; exit 1; }
case "$ARCH" in arm64) TASK_TARGET=aarch64-apple-darwin ;; x86_64) TASK_TARGET=x86_64-apple-darwin ;; *) exit 1 ;; esac
TASK_CORE="${GITROCHI_CORE_ARCHIVE:-$ROOT/../crates/target/$TASK_TARGET/release/libgitrochi_core.a}"
[[ -f "$TASK_CORE" ]] || { echo 'Run macos/build.sh once to build the native core.' >&2; exit 1; }
python3 - "$ROOT" "$TASK_TMP" <<'PY'
from pathlib import Path
import sys
root, target = map(Path, sys.argv[1:])
for source in (root / 'Sources').rglob('*.swift'):
    relative = source.relative_to(root / 'Sources').as_posix()
    text = source.read_text()
    if relative == 'App/App.swift':
        start = text.index('@main\nstruct GitrochiApp: App {')
        end = text.index('/// 창(탭) 하나 = 저장소 하나', start)
        text = text[:start] + text[end:]
    dest = target / 'Sources' / relative
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(text)
PY
TASK_APP="$TASK_TMP/FlowLayout.app"
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources/en.lproj"
cat > "$TASK_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.gitrochi.flow-layout-fixture</string>
<key>CFBundleExecutable</key><string>FlowLayout</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string></array>
</dict></plist>
PLIST
cp "$TASK_ENGINE" "$TASK_APP/Contents/MacOS/gitch-flow"
TASK_SOURCES=()
while IFS= read -r -d '' file; do TASK_SOURCES+=("$file"); done < <(find "$TASK_TMP/Sources" -name '*.swift' -print0)
xcrun swiftc -parse-as-library -swift-version 5 -O -target "$ARCH-apple-macos15.0" \
    -module-cache-path "$ROOT/.build/clang-cache" \
    -I "$ST" -I "$ROOT/../crates/gitrochi-core/include" -L "$ST" -lSwiftTerm \
    "${TASK_SOURCES[@]}" "$ROOT/Tools/fixtures/FlowCodeLayout.swift" "$TASK_CORE" \
    -o "$TASK_APP/Contents/MacOS/FlowLayout"
# Connection/trust metadata reads stay in an empty fixture settings folder too.
GITSW_CONFIG="$TASK_TMP/settings/config" "$TASK_APP/Contents/MacOS/FlowLayout" "$TASK_OUTPUT" "$TASK_REPO" "$TASK_COMMON" -AppleLanguages '(en)'
