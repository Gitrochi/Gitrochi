#!/usr/bin/env bash
# Renders the production Flows workspace, History tab and run sheet off screen, in light and dark, on fixture data: a
# flow whose latest run failed at one step and skipped the step after it. The plan is the real engine's reading of a
# flow file in a temporary folder (nothing is trusted and nothing runs); the run is handed to the store by the fixture.
# Text recognition checks the banner, the header actions and the step details.
#   macos/Tools/test-flow-workspace-layout.sh [output folder for the screenshots]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
TASK_OUTPUT="${1:-$(mktemp -d "${TMPDIR:-/tmp}/gitrochi-flow-workspace.XXXXXX")}"
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
        # the fixture brings its own entry point
        start = text.index('@main\nstruct GitrochiApp: App {')
        end = text.index('/// 창(탭) 하나 = 저장소 하나', start)
        text = text[:start] + text[end:]
    if relative == 'Store/FlowStore.swift':
        # The fixture hands the store a recorded run without changing production access control.
        for field in ('list', 'runs', 'views', 'records'):
            before = 'private(set) var ' + field
            assert before in text, before
            text = text.replace(before, 'var ' + field)
    dest = target / 'Sources' / relative
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(text)
PY
TASK_APP="$TASK_TMP/FlowWorkspaceLayout.app"
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources/en.lproj"
cat > "$TASK_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.gitrochi.flow-workspace-fixture</string>
<key>CFBundleExecutable</key><string>FlowWorkspaceLayout</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string></array>
</dict></plist>
PLIST
cp "$TASK_ENGINE" "$TASK_APP/Contents/MacOS/gitch-flow"
TASK_SOURCES=()
while IFS= read -r -d '' file; do TASK_SOURCES+=("$file"); done < <(find "$TASK_TMP/Sources" -name '*.swift' -print0)
# unoptimized: the fixture draws a few frames, and the whole app compiles in a third of the time
xcrun swiftc -parse-as-library -swift-version 5 -Onone -target "$ARCH-apple-macos15.0" \
    -module-cache-path "$ROOT/.build/clang-cache" \
    -I "$ST" -I "$ROOT/../crates/gitrochi-core/include" -L "$ST" -lSwiftTerm \
    "${TASK_SOURCES[@]}" "$ROOT/Tools/fixtures/FlowWorkspaceLayout.swift" "$TASK_CORE" \
    -o "$TASK_APP/Contents/MacOS/FlowWorkspaceLayout"

# The flow file the engine plans. It sits in an empty repository of its own; no step of it ever runs.
mkdir -p "$TASK_TMP/repo/.gitch"
cat > "$TASK_TMP/repo/.gitch/flow.yml" <<'F'
version: 1
project: { name: demo }
flows:
  verify:
    description: Build and check this repository before sharing changes.
    nodes:
      install: { description: Install dependencies, run: "npm ci" }
      lint: { needs: [install], run: "npm run lint" }
      ui-tests: { description: Run the interface tests, needs: [install], run: "npm run test:ui" }
      package: { needs: [lint, ui-tests], run: "npm run package" }
  release:
    description: Tag and publish a build.
    nodes:
      notes: { run: "npm run notes" }
F
(cd "$TASK_TMP/repo" && git init -q)
"$TASK_APP/Contents/MacOS/FlowWorkspaceLayout" "$TASK_OUTPUT" "$TASK_TMP/repo" -AppleLanguages '(en)'
echo "Screenshots: $TASK_OUTPUT"
