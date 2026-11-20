# shellcheck shell=bash
# Native account settings run only inside the harness's isolated HOME.
onboard_add() { run gitch add --id "${1:-dave}" --email "${2:-dave@example.com}" --host github.com --no-folder --no-setup --json --yes; }
onboard_q() { printf '%s' "$OUT" | jq -r "$1"; }
onboard_validate() {
  assert_json "$OUT"
  printf '%s' "$OUT" | jq -e '.schemaVersion == 1 and (.account | type == "object") and (.ssh | type == "object")' >/dev/null || fail 'account result contract'
  if [ -n "${GITCH_JSONSCHEMA_PYTHON:-}" ]; then
    printf '%s' "$OUT" > "$T/account-result.json"
    gitch schema account > "$T/account-schema.json"
    "$GITCH_JSONSCHEMA_PYTHON" "$ROOT/tests/validate_schema.py" "$T/account-schema.json" "$T/account-result.json" || fail 'account JSON Schema'
  fi
}

test_onboarding_add_and_inspect_preserve_existing_accounts_and_identity() {
  mk_config
  git config --global user.name 'Existing Person'
  git config --global user.email existing@example.com
  printf 'keep Claude rules\n' > "$HOME/.claude/CLAUDE.md"
  printf 'keep Codex rules\n' > "$HOME/.codex/AGENTS.md"
  cp "$HOME/.gitconfig" "$T/global-before-add"
  cp "$HOME/.claude/CLAUDE.md" "$T/claude-before-add"
  cp "$HOME/.codex/AGENTS.md" "$T/codex-before-add"
  mk_repo "$T/locked"; git -C "$T/locked" config gitch.account alice
  cp "$HOME/.ssh/config" "$T/ssh-before"
  onboard_add; assert_ok; onboard_validate
  assert_eq "$(onboard_q '.account.id')" dave
  assert_eq "$(onboard_q '.ssh.keyExists')" false
  assert_eq "$(onboard_q '.ssh.authenticated')" null
  assert_eq "$(onboard_q '.account.folder')" null
  [ ! -e "$HOME/.ssh/id_ed25519_dave" ] || fail 'add generated a key without user consent'
  cmp -s "$HOME/.ssh/config" "$T/ssh-before" || fail 'add changed SSH configuration'
  assert_eq "$(git config --global user.name)" 'Existing Person'
  assert_eq "$(git config --global user.email)" existing@example.com
  cmp -s "$HOME/.gitconfig" "$T/global-before-add" || fail 'account registration changed global Git config'
  cmp -s "$HOME/.claude/CLAUDE.md" "$T/claude-before-add" || fail 'account registration changed Claude rules'
  cmp -s "$HOME/.codex/AGENTS.md" "$T/codex-before-add" || fail 'account registration changed Codex rules'
  [ ! -d "$HOME/.claude/skills/gitch" ] || fail 'account registration installed Claude skill'
  [ ! -d "$HOME/.codex/skills/gitch" ] || fail 'account registration installed Codex skill'
  assert_eq "$(git -C "$T/locked" config gitch.account)" alice
  assert_eq "$(git config -f "$HOME/.config/gitch/config" account.alice.email)" alice@example.com
  find "$HOME/.local/state/gitch/backups" -type f | grep . >/dev/null || fail 'account config backup missing'
  cp "$HOME/.config/gitch/config" "$T/config-before-inspect"
  run gitch setup dave --inspect --json; assert_ok; onboard_validate
  assert_eq "$(onboard_q '.publicKey')" ''
  assert_eq "$(onboard_q '.registrationURL')" https://github.com/settings/ssh/new
  cmp -s "$HOME/.config/gitch/config" "$T/config-before-inspect" || fail 'inspect wrote account config'
  cmp -s "$HOME/.ssh/config" "$T/ssh-before" || fail 'inspect wrote SSH config'
}

test_onboarding_confirmation_and_validation_have_no_side_effects() {
  run gitch add --id dave --email dave@example.com --host github.com --no-setup --json
  assert_rc 2; assert_json "$OUT"
  [ ! -e "$HOME/.config/gitch/config" ] || fail 'cancelled add created account config'
  local bad
  for bad in 'bad;touch' 'bad$(touch SHOULD_NOT_EXIST)' '-option'; do
    run gitch add --id "$bad" --email dave@example.com --host github.com --json --yes
    assert_rc 1; assert_json "$OUT"
  done
  for bad in 'https://github.com' 'github.com:22' 'github.com;touch' '-github.com' 'github..com'; do
    run gitch add --id dave --email dave@example.com --host "$bad" --json --yes
    assert_rc 1; assert_json "$OUT"
  done
  for bad in 0 65536 999999 bad; do
    run gitch add --id dave --email dave@example.com --host github.com --port "$bad" --json --yes
    assert_rc 1; assert_json "$OUT"
  done
  [ ! -e "$HOME/.config/gitch/config" ] || fail 'invalid input changed configuration'
  [ ! -e SHOULD_NOT_EXIST ] || fail 'input was evaluated as shell text'
  onboard_add; assert_ok
  run gitch setup dave --generate --json; assert_rc 2; assert_json "$OUT"
  [ ! -e "$HOME/.ssh/id_ed25519_dave" ] || fail 'cancelled key generation changed files'
}

test_onboarding_rejects_duplicate_folder_aliases_and_concurrent_add() {
  mk_config
  cp "$HOME/.config/gitch/config" "$T/config-before"
  onboard_add alice; assert_rc 1; assert_json "$OUT"
  run gitch add --id dave --email dave@example.com --host github.com --folder "$HOME/Develop/alice/../alice" --no-setup --json --yes
  assert_rc 1; assert_json "$OUT"
  cmp -s "$HOME/.config/gitch/config" "$T/config-before" || fail 'duplicate overwrote configuration'
  mkdir "$HOME/.config/gitch/config.gitch-account.lock"
  onboard_add; assert_rc 1; assert_json "$OUT"
  cmp -s "$HOME/.config/gitch/config" "$T/config-before" || fail 'concurrent add overwrote config'
  [ -d "$HOME/.config/gitch/config.gitch-account.lock" ] || fail 'removed another operation lock'
}

test_onboarding_generates_once_preserves_keys_and_alias_and_no_secrets() {
  onboard_add; assert_ok
  run gitch setup dave --generate --json --yes; assert_ok; onboard_validate
  assert_eq "$(onboard_q '.keyExists')" true
  assert_eq "$(onboard_q '.keyProtection')" none
  assert_eq "$(onboard_q '.created')" true
  case "$(onboard_q '.publicKey')" in 'ssh-ed25519 '*) ;; *) fail 'public key missing' ;; esac
  assert_no_out 'PRIVATE KEY'
  cp "$HOME/.ssh/id_ed25519_dave" "$T/key-before"
  cp "$HOME/.ssh/config" "$T/ssh-before"
  if mac_only; then
    assert_eq "$(stat -c %a "$HOME/.ssh/id_ed25519_dave" 2>/dev/null || stat -f %Lp "$HOME/.ssh/id_ed25519_dave")" 600
  fi
  run gitch setup dave --generate --json --yes; assert_ok; onboard_validate
  assert_eq "$(onboard_q '.created')" false
  cmp -s "$HOME/.ssh/id_ed25519_dave" "$T/key-before" || fail 'overwrote existing private key'
  cmp -s "$HOME/.ssh/config" "$T/ssh-before" || fail 'overwrote existing SSH alias'
  assert_no_out 'PRIVATE KEY'
}

test_onboarding_public_key_conflict_is_preserved() {
  onboard_add; assert_ok
  echo 'existing public content' > "$HOME/.ssh/id_ed25519_dave.pub"
  run gitch setup dave --generate --json --yes; assert_rc 1; assert_json "$OUT"
  [ ! -e "$HOME/.ssh/id_ed25519_dave" ] || fail 'partial private key generated over public conflict'
  assert_eq "$(cat "$HOME/.ssh/id_ed25519_dave.pub")" 'existing public content'
}

test_onboarding_ssh_check_preserves_strict_host_policy_and_returns_result() {
  onboard_add; assert_ok
  cat > "$T/check-ssh" <<'SSH'
#!/bin/bash
printf '%s\n' "$@" > "$SSH_CHECK_ARGS"
printf '%s\n' "$SSH_CHECK_MESSAGE"
exit "$SSH_CHECK_RC"
SSH
  chmod +x "$T/check-ssh"
  export GITCH_SSH="$T/check-ssh" SSH_CHECK_ARGS="$T/ssh-args" SSH_CHECK_MESSAGE='Hi dave! You have successfully authenticated.' SSH_CHECK_RC=1
  run gitch setup dave --check --json; assert_ok; onboard_validate
  assert_eq "$(onboard_q '.authenticated')" true
  grep -Fx 'StrictHostKeyChecking=accept-new' "$T/ssh-args" >/dev/null || fail 'host key checks weakened'
  grep -Fx 'BatchMode=yes' "$T/ssh-args" >/dev/null || fail 'SSH could prompt for secrets'
  export SSH_CHECK_MESSAGE='Welcome to GitLab, @daveevil!' SSH_CHECK_RC=0
  run gitch setup dave --check --json; assert_rc 1; onboard_validate
  assert_eq "$(onboard_q '.authenticated')" false 'different SSH login accepted'
  export SSH_CHECK_MESSAGE='REMOTE HOST IDENTIFICATION HAS CHANGED!' SSH_CHECK_RC=255
  run gitch setup dave --check --json; assert_rc 1; onboard_validate
  assert_eq "$(onboard_q '.authenticated')" false
  assert_out 'REMOTE HOST IDENTIFICATION HAS CHANGED'
  [ ! -e "$HOME/.ssh/known_hosts" ] || fail 'changed host key was accepted'
}

test_onboarding_company_host_and_via_use_existing_binding() {
  mk_config
  run gitch add --id employee --email employee@example.com --host gitlab.example.com --port 2222 --via carol --no-folder --no-setup --json --yes
  assert_ok; onboard_validate
  assert_eq "$(onboard_q '.account.via')" carol
  assert_eq "$(onboard_q '.alias')" gitlab-carol
  assert_eq "$(onboard_q '.port')" 2222
  run gitch setup employee --generate --json --yes; assert_rc 1; assert_json "$OUT"
  [ ! -e "$HOME/.ssh/id_ed25519_employee" ] || fail 'via account generated a second key'
}

test_onboarding_inspection_never_returns_private_material_as_public_key() {
  mk_config
  printf '%s\n' 'invalid-not-a-public-ssh-key' 'PRIVATE_SECRET_MUST_NOT_ESCAPE' > "$HOME/.ssh/id_ed25519_alice.pub"
  run gitch setup alice --inspect --json; assert_ok; onboard_validate
  assert_eq "$(onboard_q '.publicKey')" ''
  assert_no_out PRIVATE_SECRET_MUST_NOT_ESCAPE
}

test_onboarding_existing_key_can_configure_missing_alias_without_replacement() {
  onboard_add; assert_ok
  ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519_dave" -N "" -q
  cp "$HOME/.ssh/id_ed25519_dave" "$T/existing-key"
  run gitch setup dave --inspect --json; assert_ok; onboard_validate
  assert_eq "$(onboard_q '.keyExists')" true
  assert_eq "$(onboard_q '.aliasConfigured')" false
  assert_eq "$(onboard_q '.ssh.aliasConfigured')" false
  run gitch setup dave --generate --json --yes; assert_ok; onboard_validate
  assert_eq "$(onboard_q '.created')" false
  assert_eq "$(onboard_q '.keyProtection')" existing
  assert_eq "$(onboard_q '.aliasConfigured')" true
  assert_eq "$(onboard_q '.ssh.aliasConfigured')" true
  cmp -s "$HOME/.ssh/id_ed25519_dave" "$T/existing-key" || fail 'existing private key replaced during alias setup'
}

test_onboarding_key_check_has_wall_deadline() {
  onboard_add; assert_ok
  cat > "$T/slow-ssh" <<'SSH'
#!/bin/bash
exec sleep 30
SSH
  chmod +x "$T/slow-ssh"
  local started
  started=$(date +%s)
  GITCH_SSH="$T/slow-ssh" run gitch setup dave --check --json
  assert_rc 1; onboard_validate
  [ "$(( $(date +%s) - started ))" -lt 20 ] || fail 'SSH check exceeded wall deadline'
  assert_eq "$(onboard_q '.authenticated')" false
  assert_out '시간이 초과'
}

test_onboarding_generate_does_not_overwrite_concurrent_ssh_config() {
  onboard_add; assert_ok
  mkdir "$HOME/.ssh/.gitch-config.lock"
  run gitch setup dave --generate --json --yes; assert_rc 1; assert_json "$OUT"
  [ ! -e "$HOME/.ssh/id_ed25519_dave" ] || fail 'concurrent config generated partial key'
  [ -d "$HOME/.ssh/.gitch-config.lock" ] || fail 'removed another SSH config lock'
}

test_onboarding_config_write_failure_rolls_back_entire_account() {
  mk_config
  cp "$HOME/.config/gitch/config" "$T/config-before"
  export ONBOARD_REAL_GIT
  ONBOARD_REAL_GIT=$(command -v git)
  cat > "$T/fakebin/git" <<'GIT'
#!/bin/bash
case " $* " in *' account.dave.host '*) exit 7 ;; esac
exec "$ONBOARD_REAL_GIT" "$@"
GIT
  chmod +x "$T/fakebin/git"
  onboard_add; assert_rc 1; assert_json "$OUT"
  cmp -s "$HOME/.config/gitch/config" "$T/config-before" || fail 'partial account config survived failure'
  [ ! -e "$HOME/.config/gitch/config.gitch-account.lock" ] || fail 'account transaction lock not released'
}

test_onboarding_parallel_adds_do_not_reassign_same_folder() {
  mk_config
  local one two rc_one rc_two winner
  gitch add --id one --email one@example.com --host github.com --folder "$T/shared-account" --no-setup --json --yes > "$T/one.out" 2> "$T/one.err" &
  one=$!
  gitch add --id two --email two@example.com --host github.com --folder "$T/shared-account" --no-setup --json --yes > "$T/two.out" 2> "$T/two.err" &
  two=$!
  wait "$one"; rc_one=$?
  wait "$two"; rc_two=$?
  [ "$((rc_one + rc_two))" -eq 1 ] || fail "parallel account adds: $rc_one / $rc_two"
  if [ "$rc_one" -eq 0 ]; then winner=one; OUT=$(cat "$T/one.out"); else winner=two; OUT=$(cat "$T/two.out"); fi
  onboard_validate
  assert_eq "$(git config -f "$HOME/.config/gitch/config" "folder.$T/shared-account.account")" "$winner"
  assert_eq "$(git config -f "$HOME/.config/gitch/config" --get-regexp '^account\.(one|two)\.email$' | wc -l | tr -d ' ')" 1
}
