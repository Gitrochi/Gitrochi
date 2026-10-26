#!/usr/bin/env bash
set -euo pipefail

# Builds gitch-flow (the flow engine). The app builds (macos/build.sh, the Windows job) and releases call it the same way.
#   tools/gitch-flow/build.sh <output file> [target triple…]
#   Without targets it builds for this machine (cargo's default); with two or more it makes a universal macOS binary with lipo.
#   Without cargo it exits with 3, and the caller decides whether to go on without the engine (development builds go on, releases stop).

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?usage: build.sh <output file> [target triple…]}"
shift
TARGETS=("$@")

if ! command -v cargo >/dev/null 2>&1; then
    echo "⚠️  No cargo, so the flow engine (gitch-flow) was not built (https://rustup.rs)." >&2
    exit 3
fi

exe=""
case "${OSTYPE:-}" in msys*|cygwin*|win32*) exe=".exe" ;; esac

BINS=()
if [[ ${#TARGETS[@]} -eq 0 ]]; then
    echo "▶ gitch-flow (this machine)…"
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
# Check that the built engine actually runs (skipped when only another architecture was built).
if "$OUT" version >/dev/null 2>&1; then
    echo "✅ $("$OUT" version) → $OUT"
else
    echo "✅ gitch-flow → $OUT (not run here: built for another architecture)"
fi
