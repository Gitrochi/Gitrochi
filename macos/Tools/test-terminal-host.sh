#!/usr/bin/env bash
# The macOS client of the terminal host (Services/TerminalHost.swift) against a real gitrochi-terminal-host:
# frames, the tab meta shared with Windows, and a session that outlives its connection and replays its output.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
TASK_TMP="$(mktemp -d)"
HOST_PID=""
cleanup() {
    [[ -n "$HOST_PID" ]] && kill "$HOST_PID" 2>/dev/null || true
    rm -rf "$TASK_TMP"
}
trap cleanup EXIT

cargo build --locked --quiet --manifest-path "$REPO/crates/Cargo.toml" --bin gitrochi-terminal-host
swiftc -parse-as-library -swift-version 5 -module-cache-path "$TASK_TMP/module-cache" \
    "$ROOT/Sources/Services/TerminalHost.swift" \
    "$ROOT/Tools/fixtures/TerminalHostTests.swift" \
    -o "$TASK_TMP/TerminalHostTests"

STATE="$TASK_TMP/state"
"$REPO/crates/target/debug/gitrochi-terminal-host" --state-dir "$STATE" --idle-exit 2 &
HOST_PID=$!
for _ in $(seq 1 100); do [[ -f "$STATE/terminal-host.json" ]] && break; sleep 0.05; done

"$TASK_TMP/TerminalHostTests" "$STATE"

# with nothing running and nobody connected, the host ends by itself and removes its endpoint file
for _ in $(seq 1 100); do kill -0 "$HOST_PID" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$HOST_PID" 2>/dev/null; then echo "the idle host did not end" >&2; exit 1; fi
HOST_PID=""
[[ ! -f "$STATE/terminal-host.json" ]] || { echo "the endpoint file was left behind" >&2; exit 1; }
