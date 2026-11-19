#!/bin/bash
# gitch 테스트 실행기
#   실제 ~/.gitconfig, ~/.ssh, ~/.claude 는 건드리지 않습니다 (테스트마다 임시 HOME + 가짜 ssh/gh/curl/원격 저장소).
#   사용: tests/run.sh [-k 이름일부] [테스트파일...]
HERE=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$HERE/.." && pwd -P)
GITCH_SRC="${GITCH_SRC:-$ROOT/gitch}"
TMP_BASE="${GITCH_TEST_TMP:-${TMPDIR:-/tmp}}"
TMP_BASE=${TMP_BASE%/}
ORIG_PATH="$PATH"
export GITCH_SRC ROOT TMP_BASE ORIG_PATH

FILTER=""; SHARD="1/1"; LIST=""; files=()
while [ $# -gt 0 ]; do
  case "$1" in -k) shift; FILTER="$1" ;; --shard) shift; SHARD="${1:-}" ;; --list) LIST=1 ;; *) files+=("$1") ;; esac
  shift
done
if [[ "$SHARD" =~ ^([1-9][0-9]*)/([1-9][0-9]*)$ ]]; then
  SHARD_INDEX=${BASH_REMATCH[1]}; SHARD_COUNT=${BASH_REMATCH[2]}
else
  printf 'Invalid test shard: %s (expected N/T)\n' "$SHARD" >&2; exit 2
fi
[ "$SHARD_INDEX" -le "$SHARD_COUNT" ] && [ "$SHARD_COUNT" -le 64 ] || { printf 'Invalid test shard: %s\n' "$SHARD" >&2; exit 2; }
[ ${#files[@]} -eq 0 ] && files=("$HERE"/test_*.sh)

# shellcheck source=tests/lib.sh
. "$HERE/lib.sh"
for f in "${files[@]}"; do
  # shellcheck disable=SC1090
  . "$f"
done

# 전부 읽어 공유 fixture를 유지하고, 실행할 항목만 분배한다.
selected=(); index=0
for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
  if [ -n "$FILTER" ]; then case "$t" in *"$FILTER"*) ;; *) continue ;; esac; fi
  if [ "$((index % SHARD_COUNT + 1))" -eq "$SHARD_INDEX" ]; then selected+=("$t"); fi
  index=$((index + 1))
done
if [ -n "$LIST" ]; then [ ${#selected[@]} -eq 0 ] || printf '%s\n' "${selected[@]}"; exit 0; fi
[ ${#selected[@]} -gt 0 ] || { printf 'No tests selected for shard %s\n' "$SHARD" >&2; exit 1; }
pass=0; fail=0; failed=()
start=$(date +%s)
for t in "${selected[@]}"; do
  out=$( (t_setup && "$t") 2>&1 ); rc=$?
  if [ $rc -eq 0 ]; then
    pass=$((pass+1)); printf '  ✔ %s\n' "$t"
  else
    fail=$((fail+1)); failed+=("$t")
    printf '  ✘ %s\n' "$t"
    printf '%s\n' "$out" | tail -30 | sed 's/^/      /'
  fi
done
echo ""
echo "통과 $pass / 실패 $fail  ($(( $(date +%s) - start ))초)"
[ $fail -eq 0 ] || { printf '실패: %s\n' "${failed[*]}"; exit 1; }
