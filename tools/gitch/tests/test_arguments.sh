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
