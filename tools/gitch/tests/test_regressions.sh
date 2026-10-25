# shellcheck shell=bash
# 경로 경계와 내용 변경이 없는 머지의 회귀 검사. 임시 HOME/저장소만 사용한다.

test_check_json_preserves_literal_filenames() {
  mac_only || return 0   # Windows 파일명에는 탭·줄바꿈·따옴표를 쓸 수 없다.
  setup_alice_repo
  local old=$'old\n\001.txt' renamed=$'renamed\t".txt' modified=$'modified\r.txt' fresh=$'new\n\t\001.txt'
  printf 'old\n' > "$old"
  printf 'base\n' > "$modified"
  git add -- "$old" "$modified"
  gitch c -m paths >/dev/null || fail commit
  mv "$old" "$renamed"
  git add -A -- "$old" "$renamed"
  printf 'changed\n' >> "$modified"
  printf 'fresh\n' > "$fresh"
  run gitch ck --json --no-fetch; assert_ok; assert_json "$OUT"
  printf '%s' "$OUT" | jq -e --arg p "$renamed" '.staged == [{status:"이름변경",path:$p}]' >/dev/null || fail "이름 변경 경로가 달라짐: $OUT"
  printf '%s' "$OUT" | jq -e --arg p "$modified" '.unstaged == [{status:"수정",path:$p}]' >/dev/null || fail "수정 경로가 달라짐: $OUT"
  printf '%s' "$OUT" | jq -e --arg p "$fresh" '.untracked == [$p]' >/dev/null || fail "새 파일 경로가 달라짐: $OUT"
  run gitch ck --no-fetch; assert_ok; assert_out 'CHANGES=3 STAGED=1 UNSTAGED=1 UNTRACKED=1'
}

test_commit_finishes_merge_with_unchanged_tree() {
  setup_alice_repo
  gitch b topic >/dev/null || fail branch
  git commit -q --allow-empty -m topic || fail topic
  gitch b main >/dev/null || fail main
  git commit -q --allow-empty -m main || fail main
  git merge --no-ff --no-commit topic >/dev/null 2>&1 || fail merge
  printf 'leave untracked\n' > not-in-merge.txt
  run gitch c -m 'finish merge'; assert_ok
  assert_eq "$(git log -1 --format=%s)" 'finish merge'
  assert_eq "$(git log -1 --format=%P | wc -w | tr -d ' ')" 2
  [ -f .git/MERGE_HEAD ] && fail '머지가 끝나지 않음'
  assert_eq "$(git ls-files not-in-merge.txt)" '' '새 파일을 자동 스테이지하면 안 됨'
}

test_commit_empty_merge_keeps_prepared_message() {
  setup_alice_repo
  gitch b topic >/dev/null || fail branch
  git commit -q --allow-empty -m topic || fail topic
  gitch b main >/dev/null || fail main
  git commit -q --allow-empty -m main || fail main
  git merge --no-ff --no-commit topic >/dev/null 2>&1 || fail merge
  local expected; expected=$(head -1 .git/MERGE_MSG)
  run gitch c; assert_ok
  assert_eq "$(git log -1 --format=%s)" "$expected"
}

test_secret_filename_with_quoted_parent_is_blocked() {
  mac_only || return 0
  setup_alice_repo
  mkdir $'tab\tfolder'
  printf 'PASSWORD=example\n' > $'tab\tfolder/.env.production'
  git add -- $'tab\tfolder/.env.production'
  run gitch c -m 'must be blocked'; assert_fail; assert_out '[gitch]'
  assert_eq "$(git log -1 --format=%s)" init
}
