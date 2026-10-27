# shellcheck shell=bash
# 충돌 예보는 실제 사용자 설정을 건드리지 않는 임시 저장소끼리 비교한다.
ov_repo() {
  mkdir -p "$1" && cd "$1" || fail "cd $1"
  git init -q . || fail 'fixture init'
  git config user.name 'Overlap fixture'
  git config user.email overlap@example.com
  OV_MAIN="$PWD"
}
ov_put() { mkdir -p "$(dirname "$1")" && cat > "$1"; }
ov_commit() { git add -A && git commit -q -m "${1:-fixture}" || fail 'fixture commit'; }
ov_worktree() {
  OV_SIDE="$1"
  local destination="$OV_SIDE"
  # MSYS does not reliably convert absolute arguments containing an apostrophe.
  [ -z "$IS_WIN" ] || destination=$(cygpath -m "$destination") || fail 'native fixture path'
  git worktree add -q -b "${2:-side}" "$destination" || fail 'fixture worktree'
  [ -d "$OV_SIDE" ] || fail 'fixture worktree directory is missing'
}
ov_json() { run gitch overlap --json "$@"; assert_ok; assert_json "$OUT"; }
ov_q() { printf '%s' "$OUT" | jq -r "$1"; }
ov_assert() { printf '%s' "$OUT" | jq -e "$1" >/dev/null || fail "$2\n$OUT"; }
ov_fingerprint() {
  python3 - "$@" <<'PY'
import hashlib, os, sys
digest = hashlib.sha256()
for root in sys.argv[1:]:
    if os.path.isfile(root):
        digest.update(root.encode('utf-8'))
        with open(root, 'rb') as handle:
            digest.update(handle.read())
        continue
    for parent, dirs, files in os.walk(root):
        dirs.sort()
        for name in sorted(files):
            path = os.path.join(parent, name)
            digest.update(path.encode('utf-8'))
            if os.path.islink(path):
                digest.update(os.readlink(path).encode('utf-8'))
            else:
                with open(path, 'rb') as handle:
                    digest.update(handle.read())
print(digest.hexdigest())
PY
}

test_overlap_single_worktree_contract() {
  ov_repo "$T/single"
  echo 'export const value=1;' | ov_put value.ts
  ov_commit
  echo 'export const value=2;' > value.ts
  ov_json
  assert_eq "$(ov_q '.schemaVersion')" 1
  assert_eq "$(ov_q '.tool')" 'gitch overlap'
  assert_eq "$(ov_q '.scope')" worktrees
  assert_eq "$(ov_q '.stats.worktrees')" 1
  assert_eq "$(ov_q '.stats.comparedPairs')" 0
  assert_eq "$(ov_q '.pairs|length')" 0
  assert_eq "$(ov_q '.incomplete')" false
  ov_assert '.worktrees[0] | (.available == true and .detached == false and (.head|length) == 40 and (.branch|type) == "string")' 'worktree metadata'
  ov_assert '(.repo|type) == "string" and (.generated|type) == "string" and (.diagnostics|type) == "array" and (.notes|type) == "array"' 'report metadata'
  run gitch overlap --fail-on-overlap --no-deps
  assert_ok
}

test_overlap_staged_unstaged_untracked_and_ignored_paths() {
  ov_repo "$T/main space ' quote"
  echo 'export const value=1;' | ov_put shared.ts
  echo ignored/ | ov_put .gitignore
  ov_commit
  ov_worktree "$T/side space ' quote"
  local unusual='space quote '\'' $literal name.ts'
  if mac_only; then unusual="${unusual}\\backslash.ts"; fi
  echo 'export const value=2;' > shared.ts
  git add shared.ts
  echo '// left untracked' | ov_put "$unusual"
  echo ignored | ov_put ignored/shared.ts
  echo '// left only' | ov_put left-only.ts
  echo 'export const value=3;' > "$OV_SIDE/shared.ts"
  printf '// right untracked\n' > "$OV_SIDE/$unusual"
  mkdir -p "$OV_SIDE/ignored"
  echo ignored > "$OV_SIDE/ignored/shared.ts"
  echo '// right only' > "$OV_SIDE/right-only.ts"
  ov_json --no-deps
  assert_eq "$(ov_q '.stats.comparedPairs')" 1
  assert_eq "$(ov_q '.stats.overlappingPairs')" 1
  assert_eq "$(ov_q '.stats.sameFiles')" 2
  printf '%s' "$OUT" | jq -e --arg unusual "$unusual" '.pairs[0].sameFiles|sort == ([$unusual,"shared.ts"]|sort)' >/dev/null || fail "filenames not preserved: $OUT"
  ov_assert '.pairs[0] | (.dependencies == [] and .sharedDependencies == [])' '--no-deps must skip hints'
  ov_assert '.worktrees as $w | .pairs[0] as $p | ($w|any(.id==$p.left)) and ($w|any(.id==$p.right)) and ($p.left != $p.right)' 'pair must refer to two known worktrees'
  run gitch overlap --json --no-deps --fail-on-overlap
  assert_rc 1
  assert_json "$OUT"
  cd "$OV_SIDE" || fail 'linked worktree cd'
  ov_json --no-deps
  assert_eq "$(ov_q '.pairs[0].sameFiles|length')" 2
}

test_overlap_includes_committed_divergent_changes() {
  ov_repo "$T/diverged"
  echo 'base' | ov_put shared.txt
  ov_commit
  local base; base=$(git rev-parse HEAD)
  ov_worktree "$T/diverged-side"
  echo left > shared.txt
  echo left > left.txt
  ov_commit 'left commit'
  cd "$OV_SIDE" || fail 'side cd'
  echo right > shared.txt
  echo right > right.txt
  ov_commit 'right commit'
  ov_json --no-deps
  assert_eq "$(ov_q '.pairs[0].base')" "$base"
  assert_eq "$(ov_q '.pairs[0].sameFiles|join(",")')" shared.txt
}

test_overlap_retains_staged_change_after_unstaged_reversal() {
  ov_repo "$T/staged-reversal"
  echo base | ov_put shared.txt
  ov_commit
  ov_worktree "$T/staged-reversal-side"
  echo staged > shared.txt
  git add shared.txt
  git show HEAD:shared.txt > shared.txt
  echo right > "$OV_SIDE/shared.txt"
  ov_json --no-deps
  assert_eq "$(ov_q '.pairs[0].sameFiles|join(",")')" shared.txt
}

test_overlap_detached_and_unborn_worktree_metadata() {
  ov_repo "$T/unborn"
  echo pending | ov_put pending.txt
  ov_json --no-deps
  assert_eq "$(ov_q '.worktrees[0].head')" null 'unborn HEAD must be null'
  assert_eq "$(ov_q '.worktrees[0].detached')" false 'unborn branch is not detached'
  assert_eq "$(ov_q '.worktrees[0].available')" true
  assert_eq "$(ov_q '.incomplete')" false
  ov_commit
  OV_SIDE="$T/detached"
  git worktree add -q --detach "$OV_SIDE" || fail 'detached fixture'
  echo main > pending.txt
  echo side > "$OV_SIDE/pending.txt"
  ov_json --no-deps
  ov_assert '.worktrees|any(.detached==true and .branch==null and .available==true and (.head|length)==40)' 'detached metadata'
  assert_eq "$(ov_q '.pairs[0].sameFiles|join(",")')" pending.txt
}

test_overlap_excludes_changes_in_each_pairs_common_ancestor() {
  ov_repo "$T/ancestor"
  echo base | ov_put inherited.txt
  ov_commit
  ov_worktree "$T/ancestor-left" left
  cd "$OV_SIDE" || fail 'left cd'
  echo inherited > inherited.txt
  ov_commit 'shared ancestor'
  git worktree add -q -b right "$T/ancestor-right" || fail 'right worktree'
  echo left > left.txt
  echo right > "$T/ancestor-right/right.txt"
  cd "$OV_MAIN" || fail 'main cd'
  ov_json --no-deps
  assert_eq "$(ov_q '.stats.worktrees')" 3
  assert_eq "$(ov_q '.stats.comparedPairs')" 3
  assert_eq "$(ov_q '.pairs|length')" 0
}

test_overlap_current_filters_pairs_from_main_and_linked_worktrees() {
  ov_repo "$T/current"
  echo base | ov_put shared.txt
  ov_commit
  local left="$T/current-left" right="$T/current-right"
  ov_worktree "$left" left
  ov_worktree "$right" right
  echo main > shared.txt
  echo left > "$left/shared.txt"
  echo right > "$right/shared.txt"
  ov_json --no-deps
  assert_eq "$(ov_q '.stats.comparedPairs')" 3
  assert_eq "$(ov_q '.pairs|length')" 3
  ov_json --no-deps --current
  assert_eq "$(ov_q '.stats.comparedPairs')" 2
  assert_eq "$(ov_q '.pairs|length')" 2
  printf '%s' "$OUT" | jq -e --arg path "$OV_MAIN" '(.worktrees[]|select(.path==$path)|.id) as $active | .pairs | all(.left==$active or .right==$active)' >/dev/null || fail '--current from main included an unrelated pair'
  cd "$left" || fail 'linked cd'
  ov_json --no-deps --current
  assert_eq "$(ov_q '.stats.comparedPairs')" 2
  assert_eq "$(ov_q '.pairs|length')" 2
  printf '%s' "$OUT" | jq -e --arg path "$left" '(.worktrees[]|select(.path==$path)|.id) as $active | .pairs | all(.left==$active or .right==$active)' >/dev/null || fail '--current from linked worktree included an unrelated pair'
}

test_overlap_reports_direct_dependency_between_changed_files() {
  ov_repo "$T/direct"
  echo 'export const service=1;' | ov_put service.ts
  echo 'import { service } from "./service"; export const consumer=service;' | ov_put consumer.ts
  ov_commit
  ov_worktree "$T/direct-side"
  echo '// left edit' >> consumer.ts
  echo 'export const service=2;' > "$OV_SIDE/service.ts"
  ov_json
  assert_eq "$(ov_q '.pairs[0].sameFiles|length')" 0
  ov_assert '.pairs[0].dependencies | any(.source=="consumer.ts" and .target=="service.ts" and (.kind|type)=="string" and (.worktree|type)=="string" and .heuristic==false)' 'direct dependency hint missing'
  assert_eq "$(ov_q '.stats.overlappingPairs')" 1
  ov_json --no-deps
  assert_eq "$(ov_q '.pairs|length')" 0
}

test_overlap_staged_import_survives_unstaged_reversal_without_mutation() {
  ov_repo "$T/staged-import"
  echo 'export const service=1;' | ov_put service.ts
  echo 'export const consumer=1;' | ov_put consumer.ts
  ov_commit
  ov_worktree "$T/staged-import-side"
  echo 'import { service } from "./service"; export const consumer=service;' > consumer.ts
  git add consumer.ts
  git show HEAD:consumer.ts > consumer.ts
  echo 'export const service=2;' > "$OV_SIDE/service.ts"
  local before; before=$(ov_fingerprint "$OV_MAIN" "$OV_SIDE" "$HOME/.gitconfig")
  ov_json
  assert_eq "$(ov_q '.incomplete')" false
  assert_eq "$(ov_q '.pairs[0].sameFiles|length')" 0
  ov_assert '.pairs[0].dependencies|any(.source=="consumer.ts" and .target=="service.ts" and (.worktree|startswith("w")) and .heuristic==false)' 'staged import hidden by restored working bytes must remain a direct dependency'
  assert_eq "$(ov_fingerprint "$OV_MAIN" "$OV_SIDE" "$HOME/.gitconfig")" "$before" 'staged graph extraction must keep original indexes and working files unchanged'
}

test_overlap_shared_local_dependency_excludes_external_packages() {
  ov_repo "$T/shared-dependency"
  echo 'export const shared=1;' | ov_put shared.ts
  echo 'import { shared } from "./shared"; import React from "react"; export const left=shared;' | ov_put left.ts
  echo 'import { shared } from "./shared"; import React from "react"; export const right=shared;' | ov_put right.ts
  ov_commit
  ov_worktree "$T/shared-dependency-side"
  echo '// left edit' >> left.ts
  echo '// right edit' >> "$OV_SIDE/right.ts"
  ov_json
  assert_eq "$(ov_q '.pairs[0].sameFiles|length')" 0
  assert_eq "$(ov_q '.pairs[0].dependencies|length')" 0
  assert_eq "$(ov_q '.pairs[0].sharedDependencies|map(.target)|join(",")')" shared.ts
  ov_assert '.pairs[0].sharedDependencies[0] | (.left + .right|sort)==["left.ts","right.ts"] and .heuristic==false' 'shared dependency source evidence'
  # A common package import alone must not turn independent files into a risk.
  ov_repo "$T/external-only"
  echo 'import React from "react"; export const left=1;' | ov_put left.ts
  echo 'import React from "react"; export const right=1;' | ov_put right.ts
  ov_commit
  ov_worktree "$T/external-only-side"
  echo '// left edit' >> left.ts
  echo '// right edit' >> "$OV_SIDE/right.ts"
  ov_json
  assert_eq "$(ov_q '.pairs|length')" 0 'external package must not be a shared dependency'
}

test_overlap_keeps_deleted_references_from_common_base() {
  ov_repo "$T/deleted-reference"
  echo 'export const right=1;' | ov_put right.ts
  echo 'import { right } from "./right"; export const left=right;' | ov_put left.ts
  ov_commit
  ov_worktree "$T/deleted-reference-side"
  echo 'export const left=2;' > left.ts
  rm "$OV_SIDE/right.ts"
  ov_json
  ov_assert '.pairs[0].dependencies | any(.source=="left.ts" and .target=="right.ts")' 'common-base reference missing after removal and deletion'
}

test_overlap_rename_delete_keeps_old_filename() {
  ov_repo "$T/rename"
  echo 'export const old=1;' | ov_put old.ts
  ov_commit
  ov_worktree "$T/rename-side"
  git mv old.ts moved.ts
  git -C "$OV_SIDE" rm -q old.ts
  ov_json --no-deps
  assert_eq "$(ov_q '.pairs[0].sameFiles|join(",")')" old.ts
}

test_overlap_stale_worktree_is_incomplete_and_never_pruned() {
  ov_repo "$T/stale"
  echo base | ov_put base.txt
  ov_commit
  ov_worktree "$T/missing-side"
  rm -rf "$OV_SIDE"
  local before; before=$(ov_fingerprint "$OV_MAIN")
  run gitch overlap --json
  assert_rc 1
  assert_json "$OUT"
  assert_eq "$(ov_q '.incomplete')" true
  ov_assert '.worktrees | any(.available == false)' 'missing worktree should remain visible'
  ov_assert '.diagnostics | any(.severity == "warning" and (.code|length)>0 and (.message|length)>0)' 'missing worktree diagnostic'
  assert_eq "$(ov_fingerprint "$OV_MAIN")" "$before" 'scan must not prune a missing worktree or mutate metadata'
}

test_overlap_unsafe_filenames_report_incomplete_without_splitting() {
  mac_only || return 0  # NTFS cannot store newline/tab names.
  ov_repo "$T/unsafe"
  echo base | ov_put safe.txt
  ov_commit
  ov_worktree "$T/unsafe-side"
  local unsafe=$'fake\nfilename.ts' unsafe_tab=$'fake\tfilename.ts'
  echo '// left' | ov_put "$unsafe"
  echo '// left' | ov_put "$unsafe_tab"
  echo '// right' > "$OV_SIDE/$unsafe"
  echo '// right' > "$OV_SIDE/$unsafe_tab"
  echo left > safe.txt
  echo right > "$OV_SIDE/safe.txt"
  run gitch overlap --json --no-deps
  assert_rc 1
  assert_json "$OUT"
  assert_eq "$(ov_q '.incomplete')" true
  ov_assert '.diagnostics|any(.code=="UNSUPPORTED_PATH" and .severity=="warning" and .count>=1)' 'unsafe paths must produce a warning'
  assert_eq "$(ov_q '.pairs[0].sameFiles|join(",")')" safe.txt 'unsafe filename fragments must not become file paths'
}

test_overlap_read_only_in_every_worktree() {
  ov_repo "$T/read-only"
  echo 'export const base=1;' | ov_put base.ts
  echo 'import { base } from "./base";' | ov_put caller.ts
  ov_commit
  ov_worktree "$T/read-only-side"
  echo '// main staged edit' >> base.ts
  git add base.ts
  echo '// main unstaged edit' >> base.ts
  echo '// side edit' >> "$OV_SIDE/caller.ts"
  echo '// side untracked' > "$OV_SIDE/new.ts"
  local before; before=$(ov_fingerprint "$OV_MAIN" "$OV_SIDE" "$HOME/.gitconfig")
  ov_json
  run gitch overlap
  assert_ok
  ov_json --no-deps
  assert_eq "$(ov_fingerprint "$OV_MAIN" "$OV_SIDE" "$HOME/.gitconfig")" "$before" 'HEAD, indexes, configs and working files must stay byte-identical'
}

test_overlap_concurrent_source_and_path_changes_are_incomplete() {
  ov_repo "$T/concurrent"
  echo 'export const service=1;' | ov_put service.ts
  echo 'import { service } from "./service";' | ov_put consumer.ts
  ov_commit
  ov_worktree "$T/concurrent-side"
  echo '// main edit' >> consumer.ts
  echo '// side edit' >> "$OV_SIDE/service.ts"
  export OV_REAL_GIT OV_MUTATION_COUNT_FILE OV_MUTATION_TARGET OV_MUTATION_KIND
  OV_REAL_GIT=$(command -v git)
  OV_MUTATION_COUNT_FILE="$T/mutation-count"
  OV_MUTATION_TARGET="$OV_MAIN/consumer.ts"
  OV_MUTATION_KIND=source
  cat > "$T/fakebin/git" <<'GIT'
#!/bin/bash
if [ "$1 $2 $3 $4" = 'worktree list --porcelain -z' ]; then
  "$OV_REAL_GIT" "$@" || exit $?
  count=0
  [ ! -f "$OV_MUTATION_COUNT_FILE" ] || read -r count < "$OV_MUTATION_COUNT_FILE"
  count=$((count + 1))
  printf '%s\n' "$count" > "$OV_MUTATION_COUNT_FILE"
  if [ "$count" -eq 2 ]; then
    if [ "$OV_MUTATION_KIND" = source ]; then
      printf '// concurrent edit\n' >> "$OV_MUTATION_TARGET"
    else
      printf 'concurrent new file\n' > "$OV_MUTATION_TARGET"
    fi
  fi
  exit 0
fi
exec "$OV_REAL_GIT" "$@"
GIT
  chmod +x "$T/fakebin/git"
  run gitch overlap --json
  assert_rc 1
  assert_json "$OUT"
  assert_eq "$(ov_q '.incomplete')" true
  ov_assert '.diagnostics|any(.code=="SNAPSHOT_CHANGED")' 'source change after graph capture must invalidate snapshot'
  rm "$OV_MUTATION_COUNT_FILE"
  OV_MUTATION_KIND=path
  OV_MUTATION_TARGET="$OV_MAIN/concurrent-new.txt"
  run gitch overlap --json --no-deps
  assert_rc 1
  assert_json "$OUT"
  assert_eq "$(ov_q '.incomplete')" true
  ov_assert '.diagnostics|any(.code=="SNAPSHOT_CHANGED")' 'new path after initial comparison must invalidate snapshot'
}

test_overlap_argument_errors_keep_stdout_clean() {
  ov_repo "$T/arguments"
  echo base | ov_put base.txt
  ov_commit
  local args rc
  for args in unknown interval-zero interval-negative interval-text interval-missing; do
    case "$args" in
      unknown) set -- --unknown ;;
      interval-zero) set -- --interval 0 ;;
      interval-negative) set -- --interval -1 ;;
      interval-text) set -- --interval nope ;;
      interval-missing) set -- --interval ;;
    esac
    gitch overlap --json "$@" > "$T/stdout" 2> "$T/stderr"; rc=$?
    [ "$rc" -ne 0 ] || fail "$args must fail"
    [ ! -s "$T/stdout" ] || fail "$args wrote invalid report to stdout: $(cat "$T/stdout")"
    [ -s "$T/stderr" ] || fail "$args missing stderr diagnostic"
  done
  cd "$T" || fail 'outside cd'
  gitch overlap --json > "$T/stdout" 2> "$T/stderr"; rc=$?
  [ "$rc" -ne 0 ] || fail 'outside a repository must fail'
  [ ! -s "$T/stdout" ] || fail 'outside a repository must leave stdout clean'
  [ -s "$T/stderr" ] || fail 'outside a repository missing stderr diagnostic'
}

ov_watch_wait_for_lines() {
  local wanted=$1 deadline=$((SECONDS + 20))
  while [ "$(wc -l < "$T/watch.stdout" | tr -d '[:space:]')" -lt "$wanted" ]; do
    if [ "$SECONDS" -ge "$deadline" ] || ! kill -0 "$OV_WATCH_PID" 2>/dev/null; then
      fail "watch stopped or timed out: $(cat "$T/watch.stderr")"
    fi
    sleep 0.1
  done
}

ov_watch_wait_for_exit() {
  local deadline=$((SECONDS + 20))
  while kill -0 "$OV_WATCH_PID" 2>/dev/null; do
    [ "$SECONDS" -lt "$deadline" ] || fail 'watch did not stop before its deadline'
    sleep 0.1
  done
  wait "$OV_WATCH_PID"
  # shellcheck disable=SC2034 # Shared with assert_rc from the test harness.
  RC=$?
  OV_WATCH_PID=""
  OUT=$(cat "$T/watch.stdout")
}

test_overlap_watch_emits_changes_as_ndjson_and_stops_on_signal() (
  local OV_WATCH_PID=""
  # Bash can launch and signal the same CLI process on Unix and Git Bash; native
  # Windows Python cannot exec an extensionless shell script or select its pipe.
  trap '[ -z "$OV_WATCH_PID" ] || { kill -KILL "$OV_WATCH_PID" 2>/dev/null; wait "$OV_WATCH_PID" 2>/dev/null; }' EXIT
  ov_repo "$T/watch"
  echo base | ov_put shared.txt
  ov_commit
  ov_worktree "$T/watch-side"
  echo left > shared.txt
  gitch overlap --json --watch --interval 1 --no-deps > "$T/watch.stdout" 2> "$T/watch.stderr" &
  OV_WATCH_PID=$!
  ov_watch_wait_for_lines 1
  head -1 "$T/watch.stdout" | jq -e '.pairs == []' >/dev/null || fail 'first watch report'
  sleep 1.3
  assert_eq "$(wc -l < "$T/watch.stdout" | tr -d '[:space:]')" 1 'unchanged watch emitted another report'
  echo right > "$OV_SIDE/shared.txt"
  ov_watch_wait_for_lines 2
  sed -n '2p' "$T/watch.stdout" | jq -e '.stats.overlappingPairs == 1 and .pairs[0].sameFiles == ["shared.txt"]' >/dev/null || fail 'changed watch report'
  kill -TERM "$OV_WATCH_PID" || fail 'cannot signal watch'
  ov_watch_wait_for_exit
  assert_rc 143 'TERM must stop watch'
  [ ! -s "$T/watch.stderr" ] || fail "watch diagnostics: $(cat "$T/watch.stderr")"
  gitch overlap --json --watch --interval 1 --no-deps --fail-on-overlap > "$T/watch.stdout" 2> "$T/watch.stderr" &
  OV_WATCH_PID=$!
  ov_watch_wait_for_exit
  assert_rc 1 'watch --fail-on-overlap must stop after its first risk'
  assert_json "$OUT"
  assert_eq "$(ov_q '.stats.overlappingPairs')" 1
)

test_overlap_watch_stops_after_emitting_an_incomplete_scan() (
  local OV_WATCH_PID=""
  trap '[ -z "$OV_WATCH_PID" ] || { kill -KILL "$OV_WATCH_PID" 2>/dev/null; wait "$OV_WATCH_PID" 2>/dev/null; }' EXIT
  ov_repo "$T/watch-incomplete"
  echo base | ov_put base.txt
  ov_commit
  ov_worktree "$T/watch-incomplete-side"
  rm -rf "$OV_SIDE"
  gitch overlap --json --watch --interval 1 --no-deps > "$T/watch.stdout" 2> "$T/watch.stderr" &
  OV_WATCH_PID=$!
  ov_watch_wait_for_exit
  assert_rc 1 'watch must emit its incomplete report and exit 1'
  assert_json "$OUT"
  assert_eq "$(ov_q '.incomplete')" true
  ov_assert '.diagnostics|any(.code=="WORKTREE_UNAVAILABLE")' 'incomplete watch diagnostic'
)
