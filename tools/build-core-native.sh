#!/usr/bin/env bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_ARCH="${1:-$(uname -m)}"
case "$TASK_ARCH" in
  arm64|aarch64) TASK_TARGET=aarch64-apple-darwin ;;
  x86_64) TASK_TARGET=x86_64-apple-darwin ;;
  *) echo "Unsupported macOS architecture: $TASK_ARCH" >&2; exit 1 ;;
esac
TASK_CARGO="${GITROCHI_CARGO:-cargo}"
TASK_HOST_ARCH="$(uname -m)"
[ "$TASK_HOST_ARCH" != arm64 ] || TASK_HOST_ARCH=aarch64
TASK_LOCAL_BIN="$TASK_ROOT/.build/rust-tools/rustup/toolchains/stable-$TASK_HOST_ARCH-apple-darwin/bin"
if [ -z "${GITROCHI_CARGO:-}" ] && [ -x "$TASK_LOCAL_BIN/cargo" ] && [ -x "$TASK_ROOT/.build/rust-tools/cargo/bin/cargo" ]; then
  TASK_CARGO="$TASK_ROOT/.build/rust-tools/cargo/bin/cargo"
  export RUSTUP_HOME="$TASK_ROOT/.build/rust-tools/rustup"
  export PATH="$TASK_ROOT/.build/rust-tools/cargo/bin:$PATH"
  export DYLD_LIBRARY_PATH="$TASK_LOCAL_BIN/../lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
fi
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-15.0}"
"$TASK_CARGO" build --manifest-path "$TASK_ROOT/crates/Cargo.toml" --locked --release --lib --bin gitch-core --bin gitrochi-index --bin gitrochi-ledger --target "$TASK_TARGET" >&2
printf '%s\n' "$TASK_ROOT/crates/target/$TASK_TARGET/release/libgitrochi_core.a"
