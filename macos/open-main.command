#!/usr/bin/env bash
set -euo pipefail

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
json_field() { python3 -c 'import json, sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"; }

[[ "$(uname -s)" == Darwin ]] || fail "This launcher requires macOS."
for tool in gitch python3; do
  command -v "$tool" >/dev/null 2>&1 || fail "Install $tool before running this launcher."
done

SCRIPT="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
REPO="$(cd "$(dirname "$SCRIPT")/.." && pwd)"
RUN_ROOT="$REPO/.build/main-launcher"
CHECKOUT="$RUN_ROOT/source"
BUNDLE="$RUN_ROOT/build/Gitrochi.app"
mkdir -p "$RUN_ROOT"
mkdir "$RUN_ROOT/lock" 2>/dev/null || fail "Another main launcher is running ($RUN_ROOT/lock)."
trap 'rmdir "$RUN_ROOT/lock"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
exec > >(tee "$RUN_ROOT/latest.log") 2>&1

cd "$REPO"
metadata="$(gitch status --json)"
account="$(printf '%s' "$metadata" | json_field account)"
remote="$(printf '%s' "$metadata" | json_field remote)"
[[ -n "$account" && -n "$remote" ]] || fail "This repository needs a gitch account and origin."

if [[ ! -e "$CHECKOUT" ]]; then
  printf 'Creating a separate checkout for main...\n'
  gitch clone "$account" "$remote" "$CHECKOUT"
  cd "$CHECKOUT"
  gitch b main
else
  cd "$CHECKOUT"
fi

# Refuse a reused checkout that somebody has repurposed or edited.
metadata="$(gitch status --json)"
printf '%s' "$metadata" | python3 -c '
import json, os, sys
data = json.load(sys.stdin)
if (data["path"] != os.getcwd() or data["remote"] != sys.argv[1]
        or data["account"] != sys.argv[2] or data["branch"] != "main"):
    sys.exit("Error: The launcher checkout is no longer the expected main checkout.")
' "$remote" "$account"

check_clean() {
  gitch ck --no-fetch --json | python3 -c '
import json, sys
data = json.load(sys.stdin)
if (not data["hasUpstream"] or data["ahead"] or data["inProgress"]
        or any(data[key] for key in ("staged", "unstaged", "untracked", "conflicts"))):
    sys.exit("Error: The launcher checkout has local work. Preserve it before continuing.")
if sys.argv[1] == "current" and data["behind"]:
    sys.exit("Error: The launcher checkout is behind main; refusing to open an older version.")
' "${1:-clean}"
}

check_clean
gitch preflight
printf 'Updating main...\n'
gitch ck --fetch --json | python3 -c '
import json, sys
if not json.load(sys.stdin)["fetched"]:
    sys.exit("Error: Could not fetch main; refusing to open an older version.")
'
check_clean
gitch pl
check_clean current
gitch l 1

printf 'Building main (the first build takes longer)...\n'
GITROCHI_BUILD_DIR="$RUN_ROOT/build" GITROCHI_OBJECT_DIR="$RUN_ROOT/objects" \
  bash "$CHECKOUT/macos/build.sh"

if [[ "${TERM_PROGRAM:-}" == Gitrochi ]]; then
  printf 'Build ready: %s\nOpen it from outside the Gitrochi terminal.\n' "$BUNDLE"
  exit 0
fi

# A new instance makes Launch Services use this bundle even if another build is open.
open -n "$BUNDLE"
printf 'Opened the latest main: %s\n' "$BUNDLE"
