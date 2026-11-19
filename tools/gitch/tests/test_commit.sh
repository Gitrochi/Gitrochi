# shellcheck shell=bash
# gitch c / p / cp / pl / undo / amend

setup_alice_repo() {   # 원격 + clone 된 alice 저장소 → cd
  mk_config; install_quiet
  mk_remote_seeded github-alice alice/app alice@example.com
  gitch clone alice alice/app "$HOME/Develop/alice/app" >/dev/null 2>&1 || fail "clone 실패"
  cd "$HOME/Develop/alice/app" || fail cd
}

test_commit_dash_m_message() {
  setup_alice_repo
  echo b > b.txt
  run gitch c -a -m "feat: add b"; assert_ok
  assert_eq "$(git log -1 --format=%s)" "feat: add b" "-m 이 메시지에 섞이면 안 됨"
  echo c > c.txt
  run gitch c -am "fix: c"; assert_ok
  assert_eq "$(git log -1 --format=%s)" "fix: c"
}

test_commit_paragraphs_and_trailer() {
  setup_alice_repo
  echo b > b.txt; git add b.txt
  run gitch c -m "제목" -m "본문 줄" --trailer "Co-Authored-By: Bot <bot@example.com>"; assert_ok
  assert_eq "$(git log -1 --format=%s)" "제목"
  assert_eq "$(git log -1 --format=%b | grep -c '본문 줄')" "1"
  assert_eq "$(git log -1 --format='%(trailers:key=Co-Authored-By,valueonly)' | head -1)" "Bot <bot@example.com>"
}

test_commit_requires_explicit_staging_when_noninteractive() {
  setup_alice_repo
  echo b > b.txt; printf 'SECRET=1\n' > .env
  run gitch c -m "x"; assert_rc 4
  assert_out "스테이지된 파일이 없습니다"
  assert_eq "$(git rev-list --count HEAD)" "1" "커밋되면 안 됨"
  git add b.txt
  run gitch c -m "only b"; assert_ok
  assert_eq "$(git show --name-only --format= HEAD)" "b.txt"
}

test_commit_legacy_words_and_errors() {
  setup_alice_repo
  echo b > b.txt
  run gitch c -a fix the bug; assert_ok
  assert_eq "$(git log -1 --format=%s)" "fix the bug"
  run gitch c --no-verify -m x; assert_fail; assert_out "--no-verify"
  run gitch c -m a extra; assert_fail; assert_out "-m 으로만"
  run gitch c -m "nothing"; assert_ok; assert_out "커밋할 변경사항이 없습니다"
}

test_push_pull_cp() {
  setup_alice_repo
  echo b > b.txt
  run gitch cp -a -m "b"; assert_ok; assert_out "push main → origin"
  assert_eq "$(git -C "$FAKE_REMOTES/github-alice/alice/app.git" log -1 --format=%s main)" "b"
  run gitch p; assert_ok; assert_out "이미 최신"
  local log="$HOME/.local/state/gitch/actions.jsonl" here; here=$(git rev-parse --show-toplevel)   # 기록은 git 이 준 경로(Windows 는 C:/…)
  [ "$(jq -r --arg r "$here" 'select(.event == "push" and .repo == $r) | .event' "$log" | grep -c .)" -eq 1 ] || fail "push 한 번이 한 번만 기록돼야 함\n$(cat "$log")"
  git push -q origin main:other 2>/dev/null
  [ "$(jq -r --arg r "$here" 'select(.event == "push" and .repo == $r) | .event' "$log" | grep -c .)" -eq 2 ] || fail "git 으로 직접 한 push 도 기록돼야 함\n$(cat "$log")"
  # 다른 곳에서 원격에 커밋 → pl
  git clone -q "$FAKE_REMOTES/github-alice/alice/app.git" "$T/other"
  git -C "$T/other" -c user.name=alice -c user.email=alice@example.com commit -q --allow-empty -m "remote change"
  GITCH_SKIP=all git -C "$T/other" push -q origin main
  run gitch pl; assert_ok; assert_out "최신으로"
  assert_eq "$(git log -1 --format=%s)" "remote change"
  run gitch rescue; assert_ok; assert_out "pull"
}

test_push_rejects_unknown_args() {
  setup_alice_repo
  run gitch p --mirror; assert_fail; assert_out "알 수 없는 옵션"
  run gitch p --no-verify; assert_fail
}

test_undo_amend_and_rescue() {
  setup_alice_repo
  echo b > b.txt; gitch c -a -m "b" >/dev/null
  run gitch amend -m "b2"; assert_ok
  assert_eq "$(git log -1 --format=%s)" "b2"
  local before; before=$(git rev-parse HEAD)
  run gitch undo; assert_ok
  assert_eq "$(git log -1 --format=%s)" "init"
  run gitch rescue; assert_ok; assert_out "undo"
  run gitch rescue 1 --restore; assert_rc 2
  run gitch rescue 1 --restore --yes; assert_ok
  assert_eq "$(git rev-parse HEAD)" "$before" "되돌리기 실패"
  run gitch rescue 2 --branch saved; assert_ok
  git show-ref -q --verify refs/heads/saved || fail "브랜치로 꺼내기 실패"
  # push 된 커밋은 undo 막힘
  gitch p >/dev/null 2>&1
  run gitch undo; assert_fail; assert_out "이미 push"
}

test_conflict_continue_and_abort() {
  setup_alice_repo
  echo base > f.txt; gitch cp -a -m base >/dev/null 2>&1
  git clone -q "$FAKE_REMOTES/github-alice/alice/app.git" "$T/other"
  echo theirs > "$T/other/f.txt"
  git -C "$T/other" -c user.name=alice -c user.email=alice@example.com commit -q -am theirs
  GITCH_SKIP=all git -C "$T/other" push -q origin main
  echo mine > f.txt; gitch c -a -m mine >/dev/null
  run gitch pl; assert_fail; assert_out "충돌"
  run gitch ck; assert_out "IN_PROGRESS=rebase"; assert_out "CONFLICTS=1"
  run gitch preflight; assert_rc 1; assert_out "PREFLIGHT=STOP"
  run gitch continue; assert_fail; assert_out "충돌이 남은"
  run gitch abort --yes; assert_ok
  run gitch ck; assert_out "IN_PROGRESS=none"
  run gitch pl; assert_fail
  echo resolved > f.txt; git add f.txt
  run gitch continue; assert_ok
  run gitch ck; assert_out "IN_PROGRESS=none"
}

test_up_rebases_unpushed_and_merges_pushed() {
  setup_alice_repo
  git clone -q "$FAKE_REMOTES/github-alice/alice/app.git" "$T/other"
  gitch b feat >/dev/null; echo f > f.txt; gitch c -a -m feat >/dev/null
  git -C "$T/other" -c user.name=alice -c user.email=alice@example.com commit -q --allow-empty -m "main moved"
  GITCH_SKIP=all git -C "$T/other" push -q origin main
  run gitch up; assert_ok; assert_out "위로 옮겼습니다"
  assert_eq "$(git log --format=%s -2 | tail -1)" "main moved"
  gitch p >/dev/null 2>&1
  git -C "$T/other" pull -q origin main 2>/dev/null
  git -C "$T/other" -c user.name=alice -c user.email=alice@example.com commit -q --allow-empty -m "main again"
  GITCH_SKIP=all git -C "$T/other" push -q origin main
  run gitch up; assert_ok; assert_out "merge"
}

test_prune_and_wt() {
  setup_alice_repo
  gitch b done-branch >/dev/null; gitch b main >/dev/null
  run gitch prune; assert_ok; assert_out "done-branch"; assert_out "지우려면"
  run gitch prune --yes; assert_ok
  git show-ref -q --verify refs/heads/done-branch && fail "브랜치가 남아 있음"
  run gitch wt new feature/x; assert_ok
  [ -d "$HOME/Develop/alice/app.worktrees/feature-x" ] || fail "워크트리 없음: $OUT"
  cd "$HOME/Develop/alice/app.worktrees/feature-x" && run gitch preflight --no-fetch; assert_ok
  assert_out "PUSH_ACCOUNT=alice"
}
