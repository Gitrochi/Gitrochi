#!/usr/bin/env bash
# End to end on throwaway repositories: the Rust repository index, the Python tools and the
# Go hub and monitor working together.
#   1. Rust indexes a history in which a parser and its test always change together.
#   2. Python's runtime supervisor starts the Go hub and waits for its health check.
#   3. Two members' Go monitors report work in progress: one edits the parser, one its test.
#      The hub warns about the overlap because the index knows the two files belong together.
#   4. Python's review (without AI) flags the test missing from the parser change.
# Needs cargo, Go (or the project-local toolchain) and python3 3.9+. Nothing outside a
# temporary folder is written; git runs with a private HOME and configuration.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
cleanup() {
    [ -z "${MANIFEST:-}" ] || "$PY" "$ROOT/tools/gitrochi-py/gitrochi-py" runtime down --manifest "$MANIFEST" >/dev/null 2>&1 || true
    rm -rf "$T"
}
trap cleanup EXIT
PY="${PYTHON:-python3}"
GP=("$PY" "$ROOT/tools/gitrochi-py/gitrochi-py")
fail() { echo "FAIL: $*" >&2; exit 1; }
json() { "$PY" -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {'d': d}))" "$1"; }

# Build first, with the real HOME: rustup and Go find their toolchains and caches there.
INDEX="${GITROCHI_INDEX_BIN:-$ROOT/crates/target/release/gitrochi-index}"
if [ ! -x "$INDEX" ]; then
    cargo build --locked --release --manifest-path "$ROOT/crates/Cargo.toml" --bin gitrochi-index >&2
fi
export GITROCHI_INDEX_BIN="$INDEX"
bash "$ROOT/services/hub/build.sh" >&2
HUB="$ROOT/services/hub/dist/gitrochi-hub"
[ -x "$HUB" ] || fail "the hub did not build"

mkdir -p "$T/home"
: > "$T/gitconfig"
export HOME="$T/home" GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
unset GITROCHI_INDEX GITROCHI_INDEX_DB GITROCHI_HUB_TOKEN GITROCHI_HUB_URL

member() { # member NAME FOLDER: a clone with the member's identity
    git clone -q "$T/origin.git" "$2"
    git -C "$2" config user.name "$1"
    git -C "$2" config user.email "$1@example.com"
}

echo "▶ 1. a shared history, indexed by Rust"
git init -q --bare -b main "$T/origin.git"
member alice "$T/alice"
mkdir -p "$T/alice/src" "$T/alice/tests"
for round in 1 2 3; do
    echo "def parse(): return $round" > "$T/alice/src/parser.py"
    echo "def test_parse(): assert $round" > "$T/alice/tests/test_parser.py"
    git -C "$T/alice" add -A && git -C "$T/alice" commit -qm "Parser round $round"
done
echo "# app" > "$T/alice/README.md"
git -C "$T/alice" add -A && git -C "$T/alice" commit -qm "Add a README"
git -C "$T/alice" push -q origin main
member bob "$T/bob"
synced="$("$INDEX" --repo "$T/alice" sync)"
[ "$(echo "$synced" | json 'd["newCommits"]')" = 4 ] || fail "index sync: $synced"
partner="$("$INDEX" --repo "$T/alice" impact src/parser.py | json 'd["suggestions"][0]["path"]')"
[ "$partner" = tests/test_parser.py ] || fail "impact suggested $partner"
echo "ok   4 commits; the parser's partner is $partner"

echo "▶ 2. Python's runtime supervisor starts the Go hub"
"$HUB" init --data "$T/hub" 2>/dev/null | "$PY" -c 'import json,sys; t=sys.stdin.read(); print(json.loads(t[t.index("{"):])["token"])' > "$T/admin-token"
for name in alice bob; do
    "$HUB" token create --data "$T/hub" --name "$name" 2>/dev/null |
        "$PY" -c 'import json,sys; t=sys.stdin.read(); print(json.loads(t[t.index("{"):])["token"])' > "$T/$name-token"
    chmod 600 "$T/$name-token"
done
PORT="$("$PY" -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
MANIFEST="$T/gitrochi-runtime.json"
cat > "$MANIFEST" <<EOF
{
  "version": 1,
  "stateDir": "$T/runtime",
  "services": {
    "hub": {
      "command": ["$HUB", "serve", "--data", "$T/hub", "--listen", "127.0.0.1:\${PORT}"],
      "port": $PORT,
      "health": {"http": "http://127.0.0.1:\${PORT}/healthz", "interval": 1, "timeout": 2, "retries": 3, "startPeriod": 0},
      "restart": {"policy": "on-failure", "maxRestarts": 2, "window": 60}
    }
  }
}
EOF
"${GP[@]}" runtime up --manifest "$MANIFEST" --json > "$T/up.json" || { cat "$T/up.json" >&2; fail "runtime up"; }
# The supervisor's own health check decides; it reports starting until the first one passes.
state=starting
for _ in $(seq 1 50); do
    state="$("${GP[@]}" runtime status --manifest "$MANIFEST" --json | json '[s["state"] for s in d["services"] if s["name"] == "hub"][0]')"
    [ "$state" != healthy ] || break
    sleep 0.2
done
[ "$state" = healthy ] || { "${GP[@]}" runtime logs hub --manifest "$MANIFEST" >&2 || true; fail "supervisor reports the hub as $state"; }
"$HUB" health --url "http://127.0.0.1:$PORT/healthz" >/dev/null || fail "the hub's own health command disagrees"
echo "ok   hub on 127.0.0.1:$PORT, supervised ($state)"

echo "▶ 3. two members' monitors report work in progress to the hub"
echo "def parse(): return 4" > "$T/alice/src/parser.py"
echo "def test_parse(): assert 4" > "$T/bob/tests/test_parser.py"
for name in alice bob; do
    cat > "$T/$name-monitor.json" <<EOF
{
  "repos": [{"path": "$T/$name", "key": "example.com/team/app"}],
  "hub": "http://127.0.0.1:$PORT",
  "tokenFile": "$T/$name-token",
  "client": "$name-laptop",
  "listen": "off",
  "state": "$T/$name-monitor-state.json",
  "pollInterval": "1s"
}
EOF
    "$HUB" monitor --config "$T/$name-monitor.json" --once > "$T/$name-status.json" || { cat "$T/$name-status.json" >&2; fail "$name's monitor"; }
done
# bob's monitor built bob's own index, which ties his test to alice's parser.
related="$(json 'd["repos"][0].get("related", [])' < "$T/bob-status.json" || true)"
overlaps="$("$HUB" overlaps --hub "http://127.0.0.1:$PORT" --repo example.com/team/app --token-file "$T/admin-token")"
kind="$(echo "$overlaps" | json '",".join(sorted(o["kind"] for o in (d["overlaps"] if isinstance(d, dict) else d)))')"
case "$kind" in
    *related-file*) ;;
    *) fail "expected a related-file overlap, got: $overlaps (bob's related files: $related)" ;;
esac
echo "ok   overlaps: $kind"

echo "▶ 4. Python's review flags the test missing from alice's change"
review="$(cd "$T/alice" && "${GP[@]}" review --worktree --no-ai --json --fail-on never)"
missing="$(echo "$review" | json '[f["file"] for f in d["findings"] if "tests/test_parser.py" in (f.get("message", "") + f.get("file", ""))]')"
[ "$missing" != "[]" ] || fail "review did not mention tests/test_parser.py: $review"
echo "ok   review: $(echo "$review" | json 'd["index"]["missingPartners"]')"

"${GP[@]}" runtime down --manifest "$MANIFEST" --json > /dev/null
MANIFEST=""
echo "PASS: Rust index → Python supervisor → Go hub and monitors → Python review"
