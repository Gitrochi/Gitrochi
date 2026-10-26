#!/usr/bin/env bash
set -euo pipefail

# gitch-flow(흐름 엔진) 빌드 — 앱 빌드(macos/build.sh · Windows 작업)와 릴리스가 같은 방법으로 부른다.
#   tools/gitch-flow/build.sh <출력 파일> [대상 triple…]
#   대상을 주지 않으면 이 컴퓨터용(cargo 기본). 둘 이상이면 macOS 유니버설로 lipo 한다.
#   cargo 가 없으면 종료 코드 3 — 부르는 쪽이 엔진 없이 계속할지 정한다(개발 빌드는 계속, 배포본은 멈춤).

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?사용법: build.sh <출력 파일> [대상 triple…]}"
shift
TARGETS=("$@")

if ! command -v cargo >/dev/null 2>&1; then
    echo "⚠️  cargo 가 없어 흐름 엔진(gitch-flow)을 빌드하지 못했습니다(https://rustup.rs)." >&2
    exit 3
fi

exe=""
case "${OSTYPE:-}" in msys*|cygwin*|win32*) exe=".exe" ;; esac

BINS=()
if [[ ${#TARGETS[@]} -eq 0 ]]; then
    echo "▶ gitch-flow (이 컴퓨터)…"
    cargo build --release --locked --manifest-path "$ROOT/Cargo.toml"
    BINS+=("$ROOT/target/release/gitch-flow$exe")
else
    for t in "${TARGETS[@]}"; do
        echo "▶ gitch-flow ($t)…"
        cargo build --release --locked --manifest-path "$ROOT/Cargo.toml" --target "$t"
        suffix=""
        case "$t" in *windows*) suffix=".exe" ;; esac
        BINS+=("$ROOT/target/$t/release/gitch-flow$suffix")
    done
fi

mkdir -p "$(dirname "$OUT")"
if [[ ${#BINS[@]} -gt 1 ]]; then
    lipo -create "${BINS[@]}" -output "$OUT"
else
    cp "${BINS[0]}" "$OUT"
fi
chmod 755 "$OUT"
# 빌드한 엔진이 실제로 도는지(다른 아키텍처만 만든 경우는 건너뜀).
if "$OUT" version >/dev/null 2>&1; then
    echo "✅ $("$OUT" version) → $OUT"
else
    echo "✅ gitch-flow → $OUT (이 컴퓨터에서 실행 확인은 건너뜀)"
fi
