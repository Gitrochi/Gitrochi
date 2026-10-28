#!/usr/bin/env bash
set -euo pipefail

# Gitrochi 맥 앱 빌드 (swiftc, 비샌드박스)
#   macos/build.sh           → macos/build/Gitrochi.app (이 맥의 아키텍처, 개발 인증서가 있으면 그걸로 서명)
#   macos/build.sh install   → 빌드 후 /Applications 로 설치
#   macos/build.sh release   → macos/dist/ 에 배포용 zip·dmg·sha256 (Apple Silicon + Intel 유니버설, ad-hoc 서명, 공개키가 있으면 zip 업데이트 서명)

BIN="Gitrochi"
ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
BUILD="${GITROCHI_BUILD_DIR:-$ROOT/build}"
OBJECTS="${GITROCHI_OBJECT_DIR:-$ROOT/.build/swiftc}"
BUNDLE="$BUILD/$BIN.app"
CONTENTS="$BUNDLE/Contents"
MODE="${1:-}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
bash "$REPO/tools/check-versions.sh"

if [[ "$MODE" == "release" ]]; then ARCHS=(arm64 x86_64); else ARCHS=("$(uname -m)"); fi

# 업데이트 서명(Ed25519): 앱에 공개키가 들어 있으면 그 앱은 <zip>.sig 가 맞아야만 설치하므로, 비밀키가 없으면 빌드 전에 멈춘다.
# 비밀키는 GITROCHI_UPDATE_KEY(Actions 비밀 값) 또는 로그인 키체인(Tools/updatekey.sh new)
if [[ "$MODE" == "release" ]]; then
    PUBKEY="$(/usr/libexec/PlistBuddy -c 'Print GitrochiUpdatePublicKey' "$ROOT/Resources/Info.plist" 2>/dev/null || true)"
    if [[ -n "$PUBKEY" ]]; then
        SECRET="${GITROCHI_UPDATE_KEY:-$(security find-generic-password -s "Gitrochi update signing key" -w 2>/dev/null || true)}"
        if [[ -z "$SECRET" ]]; then
            echo "❌ 업데이트 서명 비밀키가 없습니다(GITROCHI_UPDATE_KEY 또는 키체인). 서명 없는 zip 은 앱이 설치하지 않습니다." >&2
            exit 1
        fi
    fi
fi

[ -f "$ROOT/Resources/AppIcon.icns" ] || "$ROOT/Tools/makeicon.sh"

# SwiftPM 없이 swiftc 로 바로 빌드한다(일부 Command Line Tools 에서 SwiftPM·SwiftUI 매크로가 깨져 있음).
ST_SRC="$ROOT/Vendor/SwiftTerm/Sources"
SWIFT_FLAGS=(-O -parse-as-library -swift-version 5)

build_arch() {
    local arch="$1"
    local target="$arch-apple-macos15.0"
    local st="$ROOT/.build/swiftterm/$arch"
    local obj="$OBJECTS/$arch"
    # 터미널 에뮬레이터 SwiftTerm(MIT, Vendor/SwiftTerm)은 정적 라이브러리로 따로 빌드해 두고, 소스가 바뀔 때만 다시 만든다.
    if [[ ! -f "$st/libSwiftTerm.a" || -n "$(find "$ST_SRC" -name '*.swift' -newer "$st/libSwiftTerm.a" -print -quit)" ]]; then
        echo "▶ SwiftTerm ($arch, 처음 한 번 1분쯤)…"
        mkdir -p "$st"
        find "$ST_SRC" -name '*.swift' -print0 | xargs -0 swiftc "${SWIFT_FLAGS[@]}" -target "$target" \
            -module-name SwiftTerm -emit-module -emit-module-path "$st/SwiftTerm.swiftmodule" \
            -emit-library -static -o "$st/libSwiftTerm.a"
    fi
    local core
    core="$(bash "$REPO/tools/build-core-native.sh" "$arch")"
    echo "▶ swiftc ($arch)…"
    mkdir -p "$obj"
    # 다른 검사에서 공통 코어를 다시 빌드해도 현재 링크 입력은 바뀌지 않게 고정한다.
    local core_link
    core_link="$(mktemp -d "$obj/core-link.XXXXXX")"
    cp "$core" "$core_link/libgitrochi_core.a"
    # 편집 중인 소스가 컴파일 도중 바뀌어도 이 빌드는 시작 시점의 사본으로 끝낸다.
    cp -R "$ROOT/Sources" "$core_link/Sources"
    local sources=()
    while IFS= read -r -d '' f; do sources+=("$f"); done < <(find "$core_link/Sources" -name '*.swift' -print0 | sort -z)
    if ! swiftc "${SWIFT_FLAGS[@]}" -target "$target" -I "$st" -I "$REPO/crates/gitrochi-core/include" -L "$st" -lSwiftTerm \
        -module-name "$BIN" "${sources[@]}" "$core_link/libgitrochi_core.a" -o "$obj/$BIN"; then
        rm -rf "$core_link"
        return 1
    fi
    rm -rf "$core_link"
}

BINS=()
CORE_BINS=()
INDEX_BINS=()
for arch in "${ARCHS[@]}"; do
    build_arch "$arch"
    BINS+=("$OBJECTS/$arch/$BIN")
    case "$arch" in arm64) core_target=aarch64-apple-darwin ;; *) core_target=x86_64-apple-darwin ;; esac
    CORE_BINS+=("$REPO/crates/target/$core_target/release/gitch-core")
    INDEX_BINS+=("$REPO/crates/target/$core_target/release/gitrochi-index")
done

rm -rf "$BUILD"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
lipo -create "${BINS[@]}" -output "$CONTENTS/MacOS/$BIN"
lipo -create "${CORE_BINS[@]}" -output "$CONTENTS/MacOS/gitch-core"
ln -s ../MacOS/gitch-core "$CONTENTS/Resources/gitch-core"
# gitrochi-index: the repository index CLI for gitch, the Python tools and the Go monitor (the app itself links the library).
lipo -create "${INDEX_BINS[@]}" -output "$CONTENTS/MacOS/gitrochi-index"
ln -s ../MacOS/gitrochi-index "$CONTENTS/Resources/gitrochi-index"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
# 화면 번역(한국어 글자가 키, <언어>.lproj/Localizable.strings)
cp -R "$ROOT/Resources/Localizations/"*.lproj "$CONTENTS/Resources/"
# gitch: 여러 Git 계정을 섞이지 않게 쓰는 셸 도구(설정 > CLI 에서 ~/bin/gitch 로 설치)
cp "$REPO/tools/gitch/gitch" "$CONTENTS/Resources/gitch"
chmod 755 "$CONTENTS/Resources/gitch"
# SCIP 읽기는 선택 기능이다. Python 3 표준 라이브러리만 사용하며 런타임이 없으면 CLI가 안내하고 일반 분석을 유지한다.
cp "$REPO/tools/gitch/gitch-scip-index" "$CONTENTS/Resources/gitch-scip-index"
chmod 755 "$CONTENTS/Resources/gitch-scip-index"
cp "$REPO/tools/gitch/gitch-graph-watch" "$CONTENTS/Resources/gitch-graph-watch"
cp "$REPO/tools/gitrochi-mcp/server.mjs" "$CONTENTS/Resources/gitrochi-mcp.mjs"
chmod 755 "$CONTENTS/Resources/gitch-graph-watch"
# gitch graph files 가 Swift 파일 사이 참조를 Xcode 인덱스에서 읽는 도우미 — gitch 가 자기 옆에서 찾으므로 Resources 에는 링크를 둔다.
# 실행 파일은 Apple 의 번들 배치대로 Contents/MacOS 에: Resources 의 Mach-O 는 데이터로 봉인돼 앱과 함께 중첩 코드로 검사받지 않는다
"$REPO/tools/gitch-swift-index/build.sh" "$CONTENTS/MacOS/gitch-swift-index" "${ARCHS[@]}"
ln -s ../MacOS/gitch-swift-index "$CONTENTS/Resources/gitch-swift-index"
# gitch-flow: the flow engine (Rust, tools/gitch-flow), used by gitch flow, gitch test and the app's Flows screen; gitch looks for it next to itself.
# Without cargo a development build goes without the engine (the Flows tab shows a hint); a release always includes it (universal: both targets needed).
FLOW_TARGETS=()
if [[ "$MODE" == "release" ]]; then
    for arch in "${ARCHS[@]}"; do
        case "$arch" in arm64) FLOW_TARGETS+=(aarch64-apple-darwin) ;; x86_64) FLOW_TARGETS+=(x86_64-apple-darwin) ;; esac
    done
fi
flow_status=0
"$REPO/tools/gitch-flow/build.sh" "$CONTENTS/MacOS/gitch-flow" ${FLOW_TARGETS[@]+"${FLOW_TARGETS[@]}"} || flow_status=$?
if [[ $flow_status -eq 0 ]]; then
    ln -s ../MacOS/gitch-flow "$CONTENTS/Resources/gitch-flow"
elif [[ $flow_status -eq 3 && "$MODE" != "release" ]]; then
    echo "⚠️  Building without the flow engine (install cargo to include it)."
else
    echo "❌ Could not build the flow engine (gitch-flow)." >&2
    exit 1
fi
cp "$REPO/LICENSE" "$CONTENTS/Resources/LICENSE.txt"
cp "$REPO/THIRD_PARTY_NOTICES.md" "$CONTENTS/Resources/THIRD_PARTY_NOTICES.md"
cp "$REPO/tools/gitch-flow/THIRD_PARTY_NOTICES.txt" "$CONTENTS/Resources/gitch-flow-THIRD-PARTY-NOTICES.txt"
cp "$ROOT/Vendor/SwiftTerm/LICENSE" "$CONTENTS/Resources/SwiftTerm-LICENSE.txt"

# 서명: 고정 인증서(Apple Development 등)가 있으면 그걸로 서명한다.
# ad-hoc(-)은 빌드마다 서명이 바뀌어 macOS 키체인이 매번 '다른 앱'으로 보고 접근 허용을 다시 묻는다.
# 다른 인증서를 쓰려면 GITROCHI_SIGN_IDENTITY="인증서 이름" ./build.sh
# 배포본(release)은 개인 개발 인증서를 넣지 않고 ad-hoc 으로 서명한다(Developer ID 가 있으면 환경 변수로 지정).
if [[ "$MODE" == "release" ]]; then
    IDENTITY="${GITROCHI_SIGN_IDENTITY:-}"
else
    IDENTITY="${GITROCHI_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
fi
sign() {
    if [[ -n "$IDENTITY" ]]; then
        codesign --force --sign "$IDENTITY" "$1"
    else
        codesign --force --sign - "$1"
    fi
}
echo "▶ 서명: ${IDENTITY:-ad-hoc}"
# 안에 든 실행 파일을 먼저(번들 서명은 그 서명까지 묶는다)
sign "$CONTENTS/MacOS/gitch-core"
sign "$CONTENTS/MacOS/gitrochi-index"
sign "$CONTENTS/MacOS/gitch-swift-index"
[[ -f "$CONTENTS/MacOS/gitch-flow" ]] && sign "$CONTENTS/MacOS/gitch-flow"
sign "$BUNDLE"
echo "✅ 빌드 완료: $BUNDLE ($(lipo -archs "$CONTENTS/MacOS/$BIN"))"

case "$MODE" in
install)
    DEST="/Applications/$BIN.app"
    rm -rf "$DEST"
    cp -R "$BUNDLE" "$DEST"
    sign "$DEST"
    echo "✅ 설치 완료: $DEST"
    echo "   실행:  open \"$DEST\""
    ;;
release)
    DIST="$ROOT/dist"
    NAME="$BIN-$VERSION-macOS"
    mkdir -p "$DIST"
    rm -f "$DIST/$NAME".*
    ditto -c -k --keepParent "$BUNDLE" "$DIST/$NAME.zip"
    "$ROOT/Tools/makedmg.sh" "$BUNDLE" "$BIN $VERSION" "$DIST/$NAME.dmg"
    (cd "$DIST" && shasum -a 256 "$NAME.zip" "$NAME.dmg" > "$NAME.sha256")
    if [[ -n "$PUBKEY" ]]; then
        mkdir -p "$ROOT/.build"
        swiftc -O "$ROOT/Tools/updatesign.swift" -o "$ROOT/.build/updatesign"
        GITROCHI_UPDATE_KEY="$SECRET" "$ROOT/.build/updatesign" sign "$DIST/$NAME.zip"
        "$ROOT/.build/updatesign" verify "$DIST/$NAME.zip" "$PUBKEY" || { rm -f "$DIST/$NAME".*; echo "❌ 비밀키가 Info.plist 의 공개키와 짝이 아닙니다." >&2; exit 1; }
        echo "▶ 업데이트 서명: $NAME.zip.sig"
    else
        echo "⚠️  Info.plist 에 GitrochiUpdatePublicKey 가 없어 업데이트 서명을 건너뜁니다(앱은 SHA-256 만 확인)."
    fi
    echo "✅ 배포 파일:"
    ls -lh "$DIST/$NAME".*
    ;;
*)
    echo "   실행:  open \"$BUNDLE\""
    echo "   설치:  $0 install"
    ;;
esac
