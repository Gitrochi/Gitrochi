#!/usr/bin/env bash
# Checks that the repository window's content stays below the macOS title bar.
# --fullscreen 은 화면 전환을 수반하므로 명시적으로 요청할 때만 실행한다.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'if [[ -z "${GITROCHI_WINDOW_LAYOUT_KEEP_SOURCES:-}" ]]; then rm -rf "$TASK_TMP"; else echo "Fixture sources retained: $TASK_TMP" >&2; fi' EXIT
TASK_OUTPUT=""
TASK_FULLSCREEN=0
TASK_INSPECT=0
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --fullscreen) TASK_FULLSCREEN=1; shift ;;
        --inspect) TASK_INSPECT=1; shift ;;
        --output)
            [[ "$#" -ge 2 ]] || { echo "--output requires a directory" >&2; exit 2; }
            TASK_OUTPUT="$2"; shift 2 ;;
        *)
            if [[ -n "$TASK_OUTPUT" ]]; then
                echo "Usage: $0 [output-directory | --output directory] [--fullscreen] [--inspect]" >&2
                exit 2
            fi
            TASK_OUTPUT="$1"; shift ;;
    esac
done
if [[ -n "$TASK_OUTPUT" ]]; then mkdir -p "$TASK_OUTPUT"; fi
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
for source in (root / 'Sources').rglob('*.swift'):
    relative = source.relative_to(root / 'Sources').as_posix()
    text = source.read_text().replace('UserDefaults.standard', 'windowFixtureDefaults')
    text = text.replace('defaults: UserDefaults = .standard', 'defaults: UserDefaults = windowFixtureDefaults')
    if relative == 'App/App.swift':
        start = text.index('@main\nstruct GitrochiApp: App {')
        end = text.index('/// 창(탭) 하나 = 저장소 하나', start)
        text = text[:start] + text[end:]
    elif relative == 'Views/Sidebar/NavigationSidebar.swift':
        needle = '.background(Color(nsColor: .windowBackgroundColor))'
        assert text.count(needle) == 1, 'Sidebar measurement attachment changed'
        text = text.replace(needle, needle + '\n        .background(WindowContentProbe(identifier: "sidebar"))')
    elif relative == 'Views/RepoView.swift':
        needle = '                    WorkspaceDestinationContent()\n'
        assert text.count(needle) == 1, 'Workspace content measurement attachment changed'
        text = text.replace(needle, needle + '                        .background(WindowContentProbe(identifier: "workspace-header"))\n')
    elif relative == 'Services/Accounts.swift':
        needle = 'private let credentials = CredentialCache { await Keychain.read($0) }'
        assert text.count(needle) == 1, 'Isolated credential reader attachment changed'
        text = text.replace(needle, 'private let credentials = CredentialCache { _ in CredentialReadResult(value: nil, status: -25300) }')
        # 실제 툴바를 렌더링해도 사용자 인증 도우미를 설치하지 않는다.
        text = text.replace('        Askpass.install()', '        // 렌더링 검사에서는 인증 도우미를 설치하지 않는다.')
    elif relative == 'Services/LocalProjects.swift':
        needle = 'static let shared = LocalProjectStore()'
        assert text.count(needle) == 1, 'Isolated local project storage attachment changed'
        text = text.replace(needle, 'static let shared = LocalProjectStore(storage: LocalProjectFileStorage(url: windowFixtureLocalStorageURL))')
    elif relative == 'Services/Tools.swift':
        # 도구 가용성에 따른 레이아웃은 유지하고 실행 파일 탐색과 버전 조회만 생략한다.
        start = text.index('    private init() {', text.index('final class ToolStore'))
        end = text.index('\n    func detect(', start)
        text = text[:start] + '''    private init() {
        states[.git] = State(path: "/usr/bin/git", source: .auto, version: "fixture")
    }
''' + text[end:]
    dest = target / 'Sources' / relative
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(text)
PY
SOURCES=()
while IFS= read -r -d '' file; do SOURCES+=("$file"); done < <(find "$TASK_TMP/Sources" -name '*.swift' -print0)
TASK_CORE="$(CARGO_NET_OFFLINE=true bash "$ROOT/../tools/build-core-native.sh" "$ARCH")"
cp "$TASK_CORE" "$TASK_TMP/core.a"
cp "$ROOT/Tools/fixtures/WindowContentLayout.swift" "$TASK_TMP/WindowContentLayout.swift"
TASK_APP="${TASK_OUTPUT:-$TASK_TMP}/WindowContentLayoutFixture.app"
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources"
cat > "$TASK_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.gitrochi.window-content-fixture</string>
<key>CFBundleExecutable</key><string>WindowContentLayout</string>
<key>CFBundleName</key><string>Gitrochi Window Layout Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
PLIST
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then cp "$ROOT/Resources/AppIcon.icns" "$TASK_APP/Contents/Resources/"; fi
xcrun swiftc -parse-as-library -swift-version 5 -whole-module-optimization -Onone -target "$ARCH-apple-macos15.0" \
    -I "$ST" -I "$ROOT/../crates/gitrochi-core/include" -L "$ST" -lSwiftTerm \
    "${SOURCES[@]}" "$TASK_TMP/WindowContentLayout.swift" "$TASK_TMP/core.a" \
    -o "$TASK_APP/Contents/MacOS/WindowContentLayout"
TASK_ARGS=()
if [[ -n "$TASK_OUTPUT" ]]; then TASK_ARGS+=("$TASK_OUTPUT"); fi
if [[ "$TASK_FULLSCREEN" == 1 ]]; then TASK_ARGS+=(--fullscreen); fi
if [[ "$TASK_INSPECT" == 1 ]]; then TASK_ARGS+=(--inspect); fi
if [[ "${#TASK_ARGS[@]}" -gt 0 ]]; then
    "$TASK_APP/Contents/MacOS/WindowContentLayout" "${TASK_ARGS[@]}"
else
    "$TASK_APP/Contents/MacOS/WindowContentLayout"
fi
