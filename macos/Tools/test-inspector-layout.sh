#!/usr/bin/env bash
# 실제 SwiftUI 상세 화면에 긴 이름을 주입해 텍스트가 패널 밖으로 밀리지 않는지 확인한다.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
TASK_OUTPUT="${1:-$(mktemp -d /tmp/gitrochi-inspector-layout.XXXXXX)}"
mkdir -p "$TASK_OUTPUT"
ARCH="$(uname -m)"
ST="$ROOT/.build/swiftterm/$ARCH"
python3 - "$ROOT" "$TASK_TMP" <<'PY'
from pathlib import Path
import sys
root, target = map(Path, sys.argv[1:])
for source in (root / 'Sources').rglob('*.swift'):
    if source.relative_to(root / 'Sources').as_posix() == 'App/App.swift':
        continue
    dest = target / source.relative_to(root)
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(source.read_text().replace('UserDefaults.standard', 'inspectorFixtureDefaults'))
with (target / 'Sources/Store/RepoStore.swift').open('a') as f:
    f.write('''
let inspectorFixtureSuite = "dev.gitrochi.inspector-fixture." + UUID().uuidString
let inspectorFixtureDefaults = UserDefaults(suiteName: inspectorFixtureSuite)!
extension RepoStore {
    func fixtureRefs(_ sha: String, _ labels: [RefLabel]) { refsByCommit = [sha: labels] }
}
''')
PY
SOURCES=()
while IFS= read -r -d '' file; do SOURCES+=("$file"); done < <(find "$TASK_TMP/Sources" -name '*.swift' -print0)
TASK_CORE="$(bash "$ROOT/../tools/build-core-native.sh" "$ARCH")"
cp "$TASK_CORE" "$TASK_TMP/core.a"
swiftc -parse-as-library -swift-version 5 -target "$ARCH-apple-macos15.0" -I "$ST" -I "$ROOT/../crates/gitrochi-core/include" -L "$ST" -lSwiftTerm \
    "${SOURCES[@]}" "$ROOT/Tools/fixtures/InspectorLayout.swift" "$TASK_TMP/core.a" -o "$TASK_TMP/inspector-layout"
"$TASK_TMP/inspector-layout" "$TASK_OUTPUT"
