# shellcheck shell=bash
# Argument handling shared by many commands: --yes and -y at any position, and no silently ignored arguments.

args_repo() {   # an installed gitch and a locked alice repository with one unpushed commit → cd
  mk_config; install_quiet
  mk_remote_seeded github-alice alice/app alice@example.com
  gitch clone alice alice/app "$HOME/Develop/alice/app" >/dev/null 2>&1 || fail 'clone'
  cd "$HOME/Develop/alice/app" || fail cd
  echo one > one.txt; git add one.txt
  gitch c -m 'Local work' >/dev/null 2>&1 || fail 'commit'
}

test_args_yes_is_accepted_short_and_at_any_position() {
  args_repo
  # unlock
  run gitch unlock; assert_rc 2 'unlock needs confirmation'
  run gitch unlock -y; assert_ok
  [ -z "$(git config --get gitswitch.account)" ] || fail 'unlock -y did not unlock'
  run gitch use alice; assert_ok
  run gitch unlock --yes; assert_ok
  run gitch use alice; assert_ok
  # ignore
  run gitch ignore -y; assert_ok
  assert_eq "$(git config --get gitswitch.ignore)" true
  run gitch ignore --off; assert_ok
  # fix: a commit by another account that was not pushed
  echo two > two.txt; git add two.txt
  GITSW_SKIP=identity git -c user.email=bob@example.com -c user.name=bob commit -q -m 'By bob'
  run gitch fix; assert_rc 2 'fix needs confirmation'
  run gitch fix -y; assert_ok
  assert_eq "$(git log -1 --format=%ae)" alice@example.com
  # prune
  git branch done-branch HEAD~2
  run gitch prune -y; assert_ok
  git show-ref -q --verify refs/heads/done-branch && fail 'prune -y kept the merged branch'
  # rescue: fix left a backup
  run gitch rescue 1 --restore; assert_rc 2 'restore needs confirmation'
  run gitch rescue -y 1 --restore; assert_ok
  assert_eq "$(git log -1 --format=%ae)" bob@example.com 'rescue -y did not restore the backup'
  # config and org: before the subcommand, after it, or at the end
  run gitch config set gitsw.maxFileMB 7; assert_rc 2
  run gitch config set gitsw.maxFileMB 7 -y; assert_ok
  assert_eq "$(gitch config get gitsw.maxFileMB)" 7
  run gitch config --yes set gitsw.maxFileMB 8; assert_ok
  assert_eq "$(gitch config get gitsw.maxFileMB)" 8
  run gitch config unset -y gitsw.maxFileMB; assert_ok
  run gitch org add github.com/neworg alice; assert_rc 2
  run gitch org -y add github.com/neworg alice; assert_ok
  run gitch org; assert_out 'github.com/neworg → alice'
  run gitch org rm github.com/neworg -y; assert_ok
  run gitch org; assert_no_out 'github.com/neworg'
  # import
  run gitch export "$T/exported.cfg"; assert_ok
  run gitch import -y "$T/exported.cfg"; assert_ok
  # sign: the mode may follow the flag
  run gitch sign on; assert_fail 'sign needs a terminal or --yes'
  run gitch sign --yes on; assert_ok
  assert_eq "$(git config --global --get gitswitch.sign)" true
  run gitch sign off -y; assert_ok
  [ -z "$(git config --global --get gitswitch.sign)" ] || fail 'sign off -y left signing on'
  # ssh prune
  printf '\nHost github-zed\n    HostName github.com\n    IdentityFile %s/.ssh/id_ed25519_zed\n' "$HOME" >> "$HOME/.ssh/config"
  run gitch ssh prune; assert_rc 2
  run gitch ssh --yes prune; assert_ok
  grep -q 'github-zed' "$HOME/.ssh/config" && fail 'ssh --yes prune kept the unused host'
  printf '\nHost github-zed\n    HostName github.com\n    IdentityFile %s/.ssh/id_ed25519_zed\n' "$HOME" >> "$HOME/.ssh/config"
  run gitch ssh prune -y; assert_ok
  grep -q 'github-zed' "$HOME/.ssh/config" && fail 'ssh prune -y kept the unused host'
  # uninstall
  run gitch uninstall; assert_rc 2
  run gitch uninstall -y; assert_ok
  git config --global --get hook.gitsw-pre-commit.command >/dev/null && fail 'uninstall -y left the global hook'
  return 0
}

test_args_yes_aborts_an_operation_in_progress() {
  args_repo
  gitch p >/dev/null 2>&1 || fail 'push'
  git clone -q "$FAKE_REMOTES/github-alice/alice/app.git" "$T/other"
  echo theirs > "$T/other/one.txt"
  git -C "$T/other" -c user.name=alice -c user.email=alice@example.com commit -q -am theirs
  GITSW_SKIP=all git -C "$T/other" push -q origin main
  echo mine > one.txt; gitch c -a -m mine >/dev/null
  run gitch pl; assert_fail; assert_out '충돌'
  run gitch abort; assert_rc 2 'abort needs confirmation'
  run gitch abort -y; assert_ok
  run gitch ck --no-fetch; assert_out 'IN_PROGRESS=none'
}

test_args_guard_still_asks_for_the_short_flag() {
  # shellcheck disable=SC2317  # expect is defined in test_guard.sh; skip when this file runs alone
  declare -F expect >/dev/null || { echo 'skipped: run with test_guard.sh'; return 0; }
  args_repo
  local r="$HOME/Develop/alice/app"
  expect none 'gitch fix' "$r"
  expect ask 'gitch fix -y' "$r"
  expect ask 'gitch prune -y' "$r"
  expect ask 'gitch prune --gone --yes' "$r"
  expect deny 'gitch sign on'
  expect deny 'gitch sign --yes on'
  expect deny 'gitch sign -y off'
  expect none 'gitch sign'
  expect ask 'gitch config --yes set gitsw.aiPush allow'
  expect ask 'gitch org -y add github.com/x alice'
  expect ask 'gitch unlock -y' "$r"
}

test_args_commands_without_arguments_refuse_extra_ones() {
  local name before
  args_repo
  before=$(git rev-parse HEAD; git for-each-ref; git status --porcelain; git config --local --list | sort; git config --global --list | sort)
  : > "$FAKE_REMOTES/.log"
  for name in pl pull up undo continue o open sync auto install self-update; do
    run gitch "$name" extra
    assert_rc 1 "gitch $name extra"
    assert_out "사용법: gitch " "gitch $name extra"; assert_out '(받지 않는 인자: extra)'
  done
  run gitch unlock extra; assert_rc 1; assert_out '사용법: gitch unlock [--yes]'
  run gitch unlock --yes extra; assert_rc 1; assert_out '(받지 않는 인자: extra)'
  run gitch abort extra --yes; assert_rc 1; assert_out '사용법: gitch abort [--yes]'
  run gitch fix --yes extra; assert_rc 1; assert_out '사용법: gitch fix [--yes]'
  run gitch uninstall --yes extra; assert_rc 1; assert_out '사용법: gitch uninstall [--yes]'
  run gitch l 3 extra; assert_rc 1; assert_out '사용법: gitch l [개수]'
  run gitch b one two; assert_rc 1; assert_out '사용법: gitch b [이름]'
  run gitch use alice extra; assert_rc 1; assert_out '사용법: gitch use [계정]'
  run gitch remove alice extra; assert_rc 1; assert_out '사용법: gitch remove <아이디>'
  run gitch export "$T/a.cfg" "$T/b.cfg"; assert_rc 1; assert_out '사용법: gitch export [파일]'
  run gitch sign on off --yes; assert_rc 1; assert_out '사용법: gitch sign [on|off] [--yes]'
  run gitch ssh prune extra --yes; assert_rc 1; assert_out '사용법: gitch ssh prune [--yes]'
  # None of them ran.
  assert_eq "$(git rev-parse HEAD; git for-each-ref; git status --porcelain; git config --local --list | sort; git config --global --list | sort)" "$before" 'a refused command changed something'
  [ ! -s "$FAKE_REMOTES/.log" ] || fail "a refused command reached the remote:\n$(cat "$FAKE_REMOTES/.log")"
  [ ! -e "$T/a.cfg" ] || fail 'export wrote a file although it was refused'
  git show-ref -q --verify refs/heads/one && fail 'b one two made a branch'
  grep -q 'account "alice"' "$HOME/.config/gitsw/config" || fail 'remove ran although it was refused'
  return 0
}

test_args_valid_invocations_still_work() {
  local rc
  args_repo
  run gitch l 1; assert_ok; assert_out 'Local work'
  run gitch log; assert_ok
  run gitch b topic; assert_ok; assert_eq "$(git branch --show-current)" topic
  run gitch branch main; assert_ok; assert_eq "$(git branch --show-current)" main
  run gitch b; assert_ok; assert_out topic
  run gitch use alice; assert_ok
  run gitch use; assert_ok
  run gitch export "$T/a.cfg"; assert_ok; [ -f "$T/a.cfg" ] || fail 'export wrote no file'
  run gitch export; assert_ok; assert_out 'account "alice"'
  run gitch pl; assert_ok
  run gitch up; assert_ok
  run gitch o; assert_ok; assert_out 'https://github.com/alice/app'
  run gitch continue; assert_ok; assert_out '진행 중인 작업이 없습니다'
  run gitch abort; assert_ok; assert_out '진행 중인 작업이 없습니다'
  run gitch auto; assert_ok
  run gitch sign; assert_ok; assert_out '커밋 서명: 꺼짐'
  run gitch undo; assert_ok
  # --json only asks for machine-readable errors; it is not an extra argument.
  gitch unlock --json > "$T/stdout" 2> "$T/stderr"; rc=$?
  assert_eq "$rc" 2 'confirmation exit code'
  assert_eq "$(jq -r '.error.code' "$T/stderr")" GITCH_CONFIRMATION_REQUIRED
  run gitch use alice --json; assert_ok
  run gitch up --format json; assert_ok
  gitch up extra --json > "$T/stdout" 2> "$T/stderr"; rc=$?
  assert_eq "$rc" 1
  assert_eq "$(jq -r '.error.code' "$T/stderr")" GITCH_ERROR
}
