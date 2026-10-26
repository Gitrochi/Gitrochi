# shellcheck shell=bash
# No real browser/authentication: all device-flow actions use this fake executable and isolated HOME.
login_fake() {
  export GITCH_GH="$T/fake gh's device" LOGIN_FIXTURE="$T/device" LOGIN_TEST_PYTHON
  LOGIN_TEST_PYTHON=$(command -v python3 || command -v python)
  mkdir -p "$LOGIN_FIXTURE"
  cat > "$GITCH_GH" <<'GH'
#!/bin/bash
printf '%s\n' "$*" >> "$LOGIN_FIXTURE/args"
case "$1 $2" in
  'auth login')
    [ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}${GH_HOST:-}" ] || exit 9
    "$LOGIN_TEST_PYTHON" -c 'import os,shlex,subprocess; subprocess.run(shlex.split(os.environ["GH_BROWSER"])+["https://github.com/login/device"],check=True)' || exit 10
    case "${LOGIN_TEST_CODE_MODE:-colon}" in
      colon) echo '! First copy your one-time code: ABCD-1234' >&2 ;;
      clipboard) echo '! One-time code (ABCD-1234) copied to clipboard' >&2 ;;
      invalid) echo '! One-time code (SECRET_TOKEN_MUST_NOT_ESCAPE) copied to clipboard' >&2 ;;
      none) ;;
    esac
    echo "$$" > "$LOGIN_FIXTURE/child-${LOGIN_TEST_USER:-dave}"
    echo "$PPID" > "$LOGIN_FIXTURE/worker-${LOGIN_TEST_USER:-dave}"
    case "${LOGIN_TEST_MODE:-hold}" in
      hold) exec sleep 30 ;;
      failure) echo 'SECRET_TOKEN_MUST_NOT_ESCAPE' >&2; exit 7 ;;
      success|mismatch|noreply) echo "✓ Logged in as ${LOGIN_TEST_USER:-dave}" >&2; exit 0 ;;
    esac ;;
  'auth token')
    user=""
    while [ $# -gt 0 ]; do [ "$1" != --user ] || { shift; user=$1; }; shift; done
    [ "$user" = "${LOGIN_TEST_USER:-dave}" ] || exit 11
    printf 'SECRET_TOKEN_%s\n' "$user" ;;
  'api --hostname')
    case "$*" in
      *' user --jq '*)
        [ "${GH_TOKEN:-}" = "SECRET_TOKEN_${LOGIN_TEST_USER:-dave}" ] || exit 12
        if [ "${LOGIN_TEST_MODE:-}" = mismatch ]; then echo another; else echo "${LOGIN_TEST_USER:-dave}"; fi
        echo 12345 ;;
      *' user/emails --jq '*)
        case "$*" in *'select(.primary == true and .verified == true)'*) ;; *) exit 13 ;; esac
        [ "${LOGIN_TEST_MODE:-}" != noreply ] || exit 1
        printf '%s@example.com\n' "${LOGIN_TEST_USER:-dave}" ;;
      *) exit 14 ;;
    esac ;;
  *) exit 15 ;;
esac
GH
  chmod +x "$GITCH_GH"
}
login_start() {
  run gitch login github --start --json --yes "$@"
  assert_ok; assert_json "$OUT"
  LOGIN_TEST_SESSION=$(printf '%s' "$OUT" | jq -r .session)
  LOGIN_TEST_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/gitsw/logins/$LOGIN_TEST_SESSION"
  [ -d "$LOGIN_TEST_DIR" ] || fail 'session was not created'
  assert_eq "$(printf '%s' "$OUT" | jq -r .state)" pending
}
login_poll() {
  local wanted=$1 attempts=0
  while [ "$attempts" -lt 30 ]; do
    run gitch login github --status "$LOGIN_TEST_SESSION" --json
    assert_ok; assert_json "$OUT"
    [ "$(printf '%s' "$OUT" | jq -r .state)" != "$wanted" ] || return 0
    attempts=$((attempts + 1)); sleep 0.2
  done
  fail "device flow did not reach $wanted: $OUT"
}
login_cancel_wait() {
  run gitch login github --cancel "$LOGIN_TEST_SESSION" --json; assert_ok
  local attempts=0
  while [ "$attempts" -lt 30 ] && [ ! -f "$LOGIN_TEST_DIR/result.json" ]; do attempts=$((attempts + 1)); sleep 0.2; done
  [ -f "$LOGIN_TEST_DIR/result.json" ] || fail 'worker did not finish after cancellation'
}
login_validate() {
  assert_json "$OUT"
  printf '%s' "$OUT" | jq -e '.schemaVersion == 1 and .tool == "gitch login" and .verificationURL == "https://github.com/login/device"' >/dev/null || fail 'login contract'
  assert_no_out SECRET_TOKEN
  if [ -n "${GITCH_JSONSCHEMA_PYTHON:-}" ]; then
    printf '%s' "$OUT" > "$T/login-result.json"; gitch schema login > "$T/login-schema.json"
    "$GITCH_JSONSCHEMA_PYTHON" "$ROOT/tests/validate_schema.py" "$T/login-schema.json" "$T/login-result.json" || fail 'login JSON Schema'
  fi
}

test_login_confirmation_missing_helper_and_bad_session_have_no_side_effects() {
  GITCH_GH="$T/no-gh" run gitch login github --start --json
  assert_rc 2; assert_json "$OUT"
  GITCH_GH="$T/no-gh" run gitch login github --start --json --yes
  assert_rc 1; assert_json "$OUT"; assert_out GITHUB_CLI_MISSING; assert_out https://cli.github.com/
  [ ! -e "$HOME/.local/state/gitsw/logins" ] || fail 'cancel/missing helper created session'
  local bad
  for bad in '../outside' '/tmp/session' 'github-1234567890/../other' 'github-$(touch PWNED)' '--option'; do
    run gitch login github --status "$bad" --json; assert_rc 1; assert_json "$OUT"; assert_out LOGIN_SESSION_INVALID
  done
  [ ! -e PWNED ] || fail 'session evaluated shell text'
}

test_login_start_returns_immediately_and_pending_code_is_narrow() {
  login_fake
  local started
  started=$(date +%s)
  login_start
  [ "$(( $(date +%s) - started ))" -lt 5 ] || fail 'start inherited worker output pipe'
  local attempts=0
  while [ "$attempts" -lt 20 ] && ! grep -q 'one-time code' "$LOGIN_TEST_DIR/auth.log"; do attempts=$((attempts+1)); sleep 0.1; done
  run gitch login github --status "$LOGIN_TEST_SESSION" --json; assert_ok; login_validate
  assert_eq "$(printf '%s' "$OUT" | jq -r .deviceCode)" ABCD-1234
  assert_eq "$(printf '%s' "$OUT" | jq -r .phase)" approval
  if mac_only; then assert_eq "$(stat -f %Lp "$LOGIN_TEST_DIR")" 700; fi
  [ ! -e "$T/opened" ] || fail 'CLI opened browser without app'
  printf 'SECRET_TOKEN: ZXCV-9876\n' > "$LOGIN_TEST_DIR/auth.log"
  run gitch login github --status "$LOGIN_TEST_SESSION" --json; assert_ok
  assert_eq "$(printf '%s' "$OUT" | jq -r .deviceCode)" null
  login_cancel_wait
}

test_login_clipboard_code_reaches_browser_approval_without_changing_gh_config() {
  login_fake; export LOGIN_TEST_CODE_MODE=clipboard
  mkdir -p "$HOME/.config/gh"
  printf 'clipboard: enabled\n' > "$HOME/.config/gh/config.yml"
  cp "$HOME/.config/gh/config.yml" "$T/original-gh-config"
  login_start
  local attempts=0
  while [ "$attempts" -lt 30 ]; do
    run gitch login github --status "$LOGIN_TEST_SESSION" --json; assert_ok; login_validate
    [ "$(printf '%s' "$OUT" | jq -r .deviceCode)" != ABCD-1234 ] || break
    attempts=$((attempts + 1)); sleep 0.1
  done
  assert_eq "$(printf '%s' "$OUT" | jq -r .deviceCode)" ABCD-1234
  assert_eq "$(printf '%s' "$OUT" | jq -r .phase)" approval
  cmp "$T/original-gh-config" "$HOME/.config/gh/config.yml" || fail 'changed user clipboard preferences'
  printf '%s\n' "$(( $(date +%s) - 61 ))" > "$LOGIN_TEST_DIR/auth-started"
  sleep 1.2
  run gitch login github --status "$LOGIN_TEST_SESSION" --json; assert_ok; login_validate
  assert_eq "$(printf '%s' "$OUT" | jq -r .state)" pending
  assert_eq "$(printf '%s' "$OUT" | jq -r .phase)" approval
  [ ! -e "$T/opened" ] || fail 'CLI opened browser without app'
  login_cancel_wait
}

test_login_invalid_clipboard_code_is_never_returned() {
  login_fake; export LOGIN_TEST_CODE_MODE=invalid
  login_start
  local attempts=0
  while [ "$attempts" -lt 30 ] && [ ! -f "$LOGIN_FIXTURE/child-dave" ]; do attempts=$((attempts + 1)); sleep 0.1; done
  run gitch login github --status "$LOGIN_TEST_SESSION" --json; assert_ok; login_validate
  assert_eq "$(printf '%s' "$OUT" | jq -r .deviceCode)" null
  assert_eq "$(printf '%s' "$OUT" | jq -r .phase)" preparing
  login_cancel_wait
}

test_login_code_preparation_deadline_stops_only_the_owned_auth_process() {
  login_fake; export LOGIN_TEST_CODE_MODE=none
  login_start
  local attempts=0 child
  while [ "$attempts" -lt 30 ] && [ ! -f "$LOGIN_FIXTURE/child-dave" ]; do attempts=$((attempts + 1)); sleep 0.1; done
  child=$(cat "$LOGIN_FIXTURE/child-dave")
  run gitch login github --status "$LOGIN_TEST_SESSION" --json; assert_ok; login_validate
  assert_eq "$(printf '%s' "$OUT" | jq -r .phase)" preparing
  printf '%s\n' "$(( $(date +%s) - 61 ))" > "$LOGIN_TEST_DIR/auth-started"
  login_poll failed; login_validate
  assert_out '네트워크 연결'
  assert_eq "$(printf '%s' "$OUT" | jq -r '.phase // "absent"')" absent
  ! kill -0 "$child" 2>/dev/null || fail 'code preparation timeout left auth child running'
}

test_login_success_resolves_named_identity_and_verified_email() {
  login_fake; export LOGIN_TEST_MODE=success LOGIN_TEST_USER=dave GH_TOKEN=AMBIENT_WRONG_ACCOUNT GITHUB_TOKEN=AMBIENT_WRONG_ACCOUNT GH_HOST=other.example.com
  login_start; login_poll complete; login_validate
  assert_eq "$(printf '%s' "$OUT" | jq -r .login)" dave
  assert_eq "$(printf '%s' "$OUT" | jq -r .email)" dave@example.com
  assert_eq "$(printf '%s' "$OUT" | jq -r .deviceCode)" null
  run gitch login github --cancel "$LOGIN_TEST_SESSION" --json; assert_ok
  assert_eq "$(printf '%s' "$OUT" | jq -r .state)" complete 'completed session changed after cancellation'
  grep -F -- '--skip-ssh-key --scopes read:user,user:email,repo,read:org,workflow,admin:public_key' "$LOGIN_FIXTURE/args" >/dev/null || fail 'OAuth scopes/SSH skip missing'
  ! grep -F -- ',project' "$LOGIN_FIXTURE/args" >/dev/null || fail 'standard login requested project permission'
  grep -F -- 'auth token --hostname github.com --user dave' "$LOGIN_FIXTURE/args" >/dev/null || fail 'selected active account instead of named account'
  [ ! -e "$LOGIN_TEST_DIR/token.tmp" ] || fail 'persisted token'
  [ ! -e "$HOME/.ssh/id_ed25519_dave" ] || fail 'OAuth login generated SSH key'
  [ ! -e "$HOME/.config/gitsw/config" ] || fail 'OAuth login registered account before confirmation'
}

test_login_projects_access_is_opt_in_and_keeps_the_selected_identity() {
  login_fake; export LOGIN_TEST_MODE=success LOGIN_TEST_USER=dave
  login_start --capability projects --expected-login DAVE
  login_poll complete; login_validate
  assert_eq "$(printf '%s' "$OUT" | jq -r .login)" dave
  grep -F -- '--scopes read:user,user:email,repo,read:org,workflow,admin:public_key,project' "$LOGIN_FIXTURE/args" >/dev/null || fail 'project scope was not requested'
  grep -F -- 'auth token --hostname github.com --user dave' "$LOGIN_FIXTURE/args" >/dev/null || fail 'project access imported an active credential'
}

test_login_projects_access_rejects_a_different_browser_account_before_import() {
  login_fake; export LOGIN_TEST_MODE=success LOGIN_TEST_USER=other
  login_start --capability projects --expected-login dave
  login_poll failed; login_validate
  assert_out '선택한 GitHub 계정'
  assert_eq "$(printf '%s' "$OUT" | jq -r .login)" null
  ! grep -F -- 'auth token' "$LOGIN_FIXTURE/args" >/dev/null || fail 'wrong account credential was imported'
}

test_login_permission_options_are_allowlisted_and_need_an_explicit_selected_account() {
  login_fake
  run gitch login github --start --json --yes --capability projects; assert_rc 1; assert_out LOGIN_ARGUMENT
  run gitch login github --start --json --yes --capability arbitrary --expected-login dave; assert_rc 1; assert_out LOGIN_ARGUMENT
  run gitch login github --start --json --yes --capability projects --expected-login '$(touch PWNED)'; assert_rc 1; assert_out LOGIN_ARGUMENT
  run gitch login github --start --json --yes --expected-login ''; assert_rc 1; assert_out LOGIN_ARGUMENT
  run gitch login github --start --json --yes --expected-login dave --expected-login other; assert_rc 1; assert_out LOGIN_ARGUMENT
  run gitch login github --status github-1234567890 --json --capability projects --expected-login dave; assert_rc 1; assert_out LOGIN_ARGUMENT
  [ ! -e "$LOGIN_FIXTURE/args" ] || fail 'invalid permission arguments started authentication'
  [ ! -e PWNED ] || fail 'expected account executed shell text'
  [ ! -e "$HOME/.local/state/gitsw/logins" ] || fail 'invalid permission arguments created a session'
}

test_login_session_paths_preserve_spaces_quotes_and_dollars() {
  export XDG_STATE_HOME="$T/device state's \$literal"
  login_fake; export LOGIN_TEST_MODE=success
  login_start; login_poll complete; login_validate
  assert_eq "$(printf '%s' "$OUT" | jq -r .login)" dave
}

test_login_failure_and_identity_mismatch_never_expose_log_or_token() {
  login_fake; export LOGIN_TEST_MODE=failure
  login_start; login_poll failed; login_validate
  assert_eq "$(printf '%s' "$OUT" | jq -r .login)" null
  export LOGIN_TEST_MODE=mismatch
  login_start; login_poll failed; login_validate
  assert_eq "$(printf '%s' "$OUT" | jq -r .email)" null
}

test_login_no_verified_email_uses_github_noreply() {
  login_fake; export LOGIN_TEST_MODE=noreply
  login_start; login_poll complete; login_validate
  assert_eq "$(printf '%s' "$OUT" | jq -r .email)" 12345+dave@users.noreply.github.com
}

test_login_cancel_stops_only_its_own_child() {
  login_fake
  login_start
  local first=$LOGIN_TEST_SESSION first_dir=$LOGIN_TEST_DIR first_pid="" second_pid="" attempts=0
  while [ "$attempts" -lt 20 ] && [ ! -f "$LOGIN_FIXTURE/child-dave" ]; do attempts=$((attempts+1)); sleep 0.1; done
  export LOGIN_TEST_USER=other
  login_start
  while [ "$attempts" -lt 20 ] && [ ! -f "$LOGIN_FIXTURE/child-dave" ]; do attempts=$((attempts+1)); sleep 0.1; done
  first_pid=$(cat "$LOGIN_FIXTURE/child-dave")
  [ ! -f "$LOGIN_FIXTURE/child-other" ] || fail 'parallel login mutated shared gh configuration'
  printf '%s\n' "$(( $(date +%s) - 61 ))" > "$LOGIN_TEST_DIR/created"
  run gitch login github --status "$LOGIN_TEST_SESSION" --json; assert_ok; login_validate
  assert_eq "$(printf '%s' "$OUT" | jq -r .state)" pending
  assert_eq "$(printf '%s' "$OUT" | jq -r .phase)" queued
  assert_eq "$(printf '%s' "$OUT" | jq -r .deviceCode)" null
  run gitch login github --cancel "$first" --json; assert_ok
  assert_eq "$(printf '%s' "$OUT" | jq -r .state)" cancelled
  attempts=0
  while [ "$attempts" -lt 30 ] && [ ! -f "$first_dir/result.json" ]; do attempts=$((attempts+1)); sleep 0.2; done
  kill -0 "$first_pid" 2>/dev/null && fail 'cancelled child still running'
  attempts=0
  while [ "$attempts" -lt 30 ] && [ ! -f "$LOGIN_FIXTURE/child-other" ]; do attempts=$((attempts+1)); sleep 0.2; done
  second_pid=$(cat "$LOGIN_FIXTURE/child-other")
  kill -0 "$second_pid" 2>/dev/null || fail 'cancel killed another session'
  login_cancel_wait
}

test_login_deadline_and_symlink_session_are_safe() {
  login_fake; login_start
  printf '%s\n' "$(( $(date +%s) - 901 ))" > "$LOGIN_TEST_DIR/created"
  login_poll failed; login_validate
  assert_out '시간이 초과'
  local attempts=0
  while [ "$attempts" -lt 30 ] && [ ! -f "$LOGIN_TEST_DIR/result.json" ]; do attempts=$((attempts+1)); sleep 0.2; done
  [ -f "$LOGIN_TEST_DIR/result.json" ] || fail 'deadline did not stop worker'
  if mac_only; then
    mkdir "$T/outside-login"; ln -s "$T/outside-login" "$HOME/.local/state/gitsw/logins/github-0000000000"
    run gitch login github --cancel github-0000000000 --json; assert_rc 1; assert_json "$OUT"
    [ ! -e "$T/outside-login/cancel" ] || fail 'followed arbitrary symlink'
  fi
}

test_login_crashed_worker_lock_recovers_without_touching_other_processes() {
  login_fake; login_start
  local crashed=$LOGIN_TEST_SESSION crashed_dir=$LOGIN_TEST_DIR attempts=0 child worker
  while [ "$attempts" -lt 30 ] && [ ! -f "$LOGIN_FIXTURE/worker-dave" ]; do attempts=$((attempts+1)); sleep 0.1; done
  child=$(cat "$LOGIN_FIXTURE/child-dave"); worker=$(cat "$LOGIN_FIXTURE/worker-dave")
  kill -KILL "$worker"
  # This PID is only our fake sleep fixture, never loaded by product cancellation/recovery.
  kill "$child" 2>/dev/null || :
  printf '%s\n' "$(( $(date +%s) - 1000 ))" > "$crashed_dir/created"
  [ -d "$HOME/.local/state/gitsw/logins/active.lock/$crashed" ] || fail 'crash fixture did not leave owning-session lock'
  export LOGIN_TEST_MODE=success LOGIN_TEST_USER=other
  login_start; login_poll complete; login_validate
  assert_eq "$(printf '%s' "$OUT" | jq -r .login)" other
  run gitch login github --status "$crashed" --json; assert_ok
  assert_eq "$(printf '%s' "$OUT" | jq -r .state)" failed
}

test_login_stale_cleanup_is_bounded_to_completed_session_directories() {
  login_fake
  local base="$HOME/.local/state/gitsw/logins"
  mkdir -p "$base/github-0123456789" "$base/github-ABCDEFGHIJ" "$base/not-a-session"
  printf '%s\n' "$(( $(date +%s) - 90000 ))" > "$base/github-0123456789/created"
  printf '{}\n' > "$base/github-0123456789/result.json"
  cp "$base/github-0123456789/created" "$base/github-ABCDEFGHIJ/created"
  echo keep > "$base/not-a-session/keep"
  login_start
  [ ! -e "$base/github-0123456789" ] || fail 'completed stale session not removed'
  [ -d "$base/github-ABCDEFGHIJ" ] || fail 'removed pending session'
  [ -f "$base/not-a-session/keep" ] || fail 'cleanup escaped session namespace'
  login_cancel_wait
}
