# shellcheck shell=bash
# use / clone / 잠금 / 워크트리

test_use_rewrites_remote_and_locks() {
  mk_config; install_quiet
  mk_repo "$HOME/Develop/alice/r" "https://github.com/alice/r.git"
  cd "$HOME/Develop/alice/r" || fail cd
  run gitch use; assert_ok; assert_out "계정 자동 선택: alice"
  assert_eq "$(git config remote.origin.url)" "git@github-alice:alice/r.git"
  assert_eq "$(git config user.email)" "alice@example.com"
  assert_eq "$(git config gitswitch.account)" "alice"
  grep -q "_hook --fallback" .git/hooks/pre-commit || fail "보조 훅 없음"
  run gitch status; assert_out "PUSH_ACCOUNT=alice"; assert_out "WARNINGS=0"
}

test_use_keeps_existing_hook_as_local() {
  mk_config; install_quiet
  mk_repo "$HOME/Develop/alice/h" "git@github-alice:alice/h.git"
  printf '#!/bin/sh\necho mine >> "%s/mine.log"\n' "$T" > "$HOME/Develop/alice/h/.git/hooks/pre-commit"
  chmod +x "$HOME/Develop/alice/h/.git/hooks/pre-commit"
  cd "$HOME/Develop/alice/h" && gitch use alice >/dev/null
  [ -x .git/hooks/pre-commit.local ] || fail "기존 훅이 .local 로 옮겨지지 않음"
  echo a > a; git add a; run git commit -q -m one; assert_ok
  [ -f "$T/mine.log" ] || fail "기존 훅이 이어서 실행되지 않음"
}

test_use_in_worktree_installs_hooks_in_common_dir() {
  mk_config
  mk_repo "$HOME/Develop/alice/w" "git@github-alice:alice/w.git"
  cd "$HOME/Develop/alice/w" && git config user.email alice@example.com && git config user.name alice && seed_commit .
  git worktree add -q "$T/wt" -b feat
  cd "$T/wt" && run gitch use alice; assert_ok
  grep -q "_hook --fallback" "$HOME/Develop/alice/w/.git/hooks/pre-commit" || fail "공용 훅 폴더에 설치되지 않음 (워크트리 버그)"
  [ ! -e "$HOME/Develop/alice/w/.git/worktrees/wt/hooks/pre-commit" ] || fail "git 이 안 읽는 곳에 설치됨"
}

test_use_refuses_wrong_host_and_outside_repo() {
  mk_config
  mk_repo "$T/g" "git@github.com:alice/g.git"
  cd "$T/g" && run gitch use carol; assert_fail; assert_out "carol 계정에는 github.com 서버가 없습니다"
  cd "$T" && run gitch use alice; assert_fail; assert_out "저장소 안에서 실행하세요"
}

test_clone_org_rule_into_account_folder() {
  mk_config; install_quiet
  mk_remote_seeded github-bob teamb/proj
  cd "$HOME" && run gitch clone teamb/proj; assert_ok
  assert_out "계정 자동 선택: bob"
  [ -d "$HOME/Develop/bob/proj/.git" ] || fail "bob 기본 폴더에 받지 않음: $OUT"
  assert_eq "$(git -C "$HOME/Develop/bob/proj" config gitswitch.account)" "bob"
  assert_eq "$(git -C "$HOME/Develop/bob/proj" config remote.origin.url)" "git@github-bob:teamb/proj.git"
}

test_clone_inside_repo_goes_to_account_folder() {
  mk_config; install_quiet
  mk_remote_seeded github-alice alice/lib
  mk_repo "$T/outer"
  cd "$T/outer" && run gitch clone alice lib; assert_ok
  assert_out "다른 저장소 안이라"
  [ -d "$HOME/Develop/alice/lib/.git" ] || fail "중첩 clone 방지 실패"
  [ ! -e "$T/outer/lib" ] || fail "다른 저장소 안에 받음"
}

test_clone_gitlab_url_picks_single_account() {
  mk_config; install_quiet
  mk_remote_seeded gitlab-carol grp/sub/app
  cd "$HOME/Develop/corp" && run gitch clone https://gitlab.example.com/grp/sub/app.git; assert_ok
  assert_eq "$(git -C "$HOME/Develop/corp/app" config remote.origin.url)" "git@gitlab-carol:grp/sub/app.git"
  assert_eq "$(git -C "$HOME/Develop/corp/app" config user.email)" "carol@corp.example"
}

test_clone_browser_page_address_uses_its_repository() {
  mk_config; install_quiet
  mk_remote_seeded github-alice alice/app
  mk_remote_seeded gitlab-carol grp/sub/tool
  local u
  # Addresses copied from a repository's web pages, not only its clone address
  for u in https://github.com/alice/app/tree/main https://github.com/alice/app/pull/3 \
    https://github.com/alice/app/blob/main/src/a.ts 'https://github.com/alice/app?tab=readme-ov-file' https://github.com/alice/app#readme; do
    cd "$HOME/Develop/alice" && rm -rf app
    run gitch clone "$u"; assert_ok "clone $u"
    assert_eq "$(git -C "$HOME/Develop/alice/app" config remote.origin.url)" "git@github-alice:alice/app.git" "$u"
  done
  for u in https://gitlab.example.com/grp/sub/tool/-/tree/main https://gitlab.example.com/grp/sub/tool/-/merge_requests/4; do
    cd "$HOME/Develop/corp" && rm -rf tool
    run gitch clone "$u"; assert_ok "clone $u"
    assert_eq "$(git -C "$HOME/Develop/corp/tool" config remote.origin.url)" "git@gitlab-carol:grp/sub/tool.git" "$u"
  done
}

test_plain_git_clone_gets_identity_from_rules() {
  mk_config; install_quiet
  mk_remote_seeded github-bob teamb/plain
  # insteadOf 가 조직 주소를 bob 별칭으로 바꾸고, includeIf 가 작성자를 bob 으로
  run git clone -q https://github.com/teamb/plain "$T/plain"; assert_ok
  assert_eq "$(git -C "$T/plain" remote get-url origin)" "git@github-bob:teamb/plain"
  assert_eq "$(cd "$T/plain" && git var GIT_AUTHOR_IDENT | sed -E 's/.*<([^>]*)>.*/\1/')" "bob@example.com"
}

test_useconfigonly_blocks_unknown_repo() {
  mk_config; install_quiet
  mk_repo "$T/stray"
  cd "$T/stray" && echo x > x && git add x
  run git commit -q -m x; assert_fail "규칙 밖 저장소 커밋은 막혀야 함"
}

test_ignore_and_protect() {
  mk_config; install_quiet
  mk_repo "$HOME/Develop/alice/ig" "git@github-alice:alice/ig.git"
  cd "$HOME/Develop/alice/ig" && gitch use alice >/dev/null
  run gitch ignore; assert_rc 2 "확인 필요"
  run gitch ignore --yes; assert_ok
  git config user.email nobody@x
  echo a > a; git add a; run git commit -q -m a; assert_ok "관리 제외면 검사 안 함"
  run gitch ignore --off; assert_ok
  run gitch protect main; assert_ok
  run gitch protect; assert_out "main"
  run gitch protect --rm main; assert_ok
  run gitch protect; assert_out "보호 브랜치가 없습니다"
}
