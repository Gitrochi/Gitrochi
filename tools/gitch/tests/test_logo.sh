# shellcheck shell=bash
# 로고 표시 설정은 Git 계정 설정 없이도 저장하고, 앱과 CLI가 같은 값을 읽는다.

logo_run() { run env -u GITCH_LOGO gitch "$@"; }

logo_assert_enabled() {
  assert_ok
  assert_json "$OUT"
  printf '%s' "$OUT" | jq -e --argjson enabled "$1" \
    'keys == ["enabled", "schemaVersion"] and .schemaVersion == 1 and .enabled == $enabled' >/dev/null \
    || fail "logo JSON expected enabled=$1: $OUT"
}

test_logo_default_status_without_account_setup() {
  logo_run logo --json; logo_assert_enabled true
  logo_run logo status --json; logo_assert_enabled true
  [ ! -e "$HOME/.config/gitsw/config" ] || fail 'reading default logo preference created a config file'
}

test_logo_on_off_persists_without_account_setup() {
  logo_run logo off --json; logo_assert_enabled false
  logo_run config get ui.logo; assert_ok; assert_eq "$OUT" false
  logo_run logo status --json; logo_assert_enabled false
  logo_run logo on --json; logo_assert_enabled true
  logo_run config get ui.logo; assert_ok; assert_eq "$OUT" true
  logo_run logo --json; logo_assert_enabled true
  [ ! -s "$FAKE_GH/log" ] && [ ! -s "$FAKE_REMOTES/.log" ] || fail 'logo preference triggered authentication or network work'
}

test_logo_does_not_change_existing_accounts() {
  mk_config
  logo_run logo off; assert_ok
  logo_run config get account.alice.email; assert_ok; assert_eq "$OUT" alice@example.com
  logo_run config get account.carol.host; assert_ok; assert_eq "$OUT" gitlab.example.com:2222
  logo_run config get org.github.com/teamb.account; assert_ok; assert_eq "$OUT" bob
  logo_run config check; assert_ok; assert_out '계정 3개'
  logo_run logo on; assert_ok
  logo_run list --json; assert_ok
  assert_eq "$(printf '%s' "$OUT" | jq '.accounts | length')" 3
}

test_logo_config_boolean_roundtrip_and_default_after_unset() {
  mk_config
  local pair value expected
  for pair in true:true false:false yes:true no:false on:true off:false 1:true 0:false :false; do
    value=${pair%:*}; expected=${pair#*:}
    logo_run config set ui.logo "$value" --yes; assert_ok "config boolean '$value'"
    logo_run logo --json; logo_assert_enabled "$expected"
  done
  logo_run config unset ui.logo --yes; assert_ok
  logo_run logo --json; logo_assert_enabled true
}

test_logo_config_rejects_invalid_value_and_rolls_back() {
  mk_config
  logo_run logo off --json; logo_assert_enabled false
  local before
  before=$(cat "$HOME/.config/gitsw/config")
  logo_run config set ui.logo banana --yes; assert_fail; assert_out ui.logo
  assert_eq "$(cat "$HOME/.config/gitsw/config")" "$before" 'invalid logo value changed config'
  logo_run logo --json; logo_assert_enabled false
}

test_logo_invalid_arguments_do_not_mutate_preference() {
  logo_run logo on --json; logo_assert_enabled true
  local before
  before=$(cat "$HOME/.config/gitsw/config")
  logo_run logo invalid --json; assert_rc 1; assert_json "$OUT"
  logo_run logo off extra --json; assert_rc 1; assert_json "$OUT"
  logo_run logo on off --json; assert_rc 1; assert_json "$OUT"
  logo_run logo --bad --json; assert_rc 1; assert_json "$OUT"
  assert_eq "$(cat "$HOME/.config/gitsw/config")" "$before" 'invalid logo command changed config'
  logo_run logo --json; logo_assert_enabled true
}

test_logo_environment_override_does_not_change_saved_status() {
  logo_run logo off --json; logo_assert_enabled false
  run env GITCH_LOGO=on gitch logo --json; logo_assert_enabled false
  logo_run config get ui.logo; assert_ok; assert_eq "$OUT" false
  logo_run logo on --json; logo_assert_enabled true
  run env GITCH_LOGO=off gitch logo status --json; logo_assert_enabled true
  logo_run config get ui.logo; assert_ok; assert_eq "$OUT" true
}

test_logo_schema_and_completion_are_public() {
  logo_run logo --json; logo_assert_enabled true
  printf '%s' "$OUT" > "$T/logo-payload.json"
  logo_run schema logo; assert_ok; assert_json "$OUT"
  assert_eq "$(printf '%s' "$OUT" | jq -r '."$ref"')" '#/$defs/logo'
  if [ -n "${GITCH_JSONSCHEMA_PYTHON:-}" ]; then
    printf '%s' "$OUT" > "$T/logo-schema.json"
    "$GITCH_JSONSCHEMA_PYTHON" "$ROOT/tests/validate_schema.py" "$T/logo-schema.json" "$T/logo-payload.json" || fail 'logo formal schema validation'
  fi
  logo_run _complete -- logo o; assert_ok; assert_out on; assert_out off
  logo_run _complete -- logo --j; assert_ok; assert_eq "$OUT" --json
  logo_run _complete -- schema logo; assert_ok; assert_eq "$OUT" logo
}
