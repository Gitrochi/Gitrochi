# shellcheck shell=bash
# The gitch flow and gitch test front door (handed off to the gitch-flow engine), the FLOW line in preflight, the pre-push gate, guard rules.
# The engine is GITCH_FLOW_TEST_BIN or tools/gitch-flow/target/{release,debug}/gitch-flow (skipped without one).

flow_bin() {
  local b
  for b in "${GITCH_FLOW_TEST_BIN:-}" "$ROOT/../gitch-flow/target/release/gitch-flow" "$ROOT/../gitch-flow/target/debug/gitch-flow" \
           "$ROOT/../gitch-flow/target/release/gitch-flow.exe" "$ROOT/../gitch-flow/target/debug/gitch-flow.exe"; do
    [ -n "$b" ] && [ -x "$b" ] && { printf '%s' "$b"; return 0; }
  done
  return 1
}

need_flow() {   # Skips this test without an engine (and says so, so it is not counted as a pass)
  FLOW_BIN=$(flow_bin) || { echo "skipped: build gitch-flow first (cd tools/gitch-flow && cargo build)"; return 1; }
  export GITCH_FLOW="$FLOW_BIN" GITCH_FLOW_NO_KEYSTORE=1
}

flow_repo() {   # $1 folder: a repository with a flow file and a fake runner
  mk_repo "$1"
  mkdir -p "$1/.gitch" "$1/tests"
  cat > "$1/tests/r.sh" <<'R'
#!/bin/sh
if [ "${1:-pass}" = pass ]; then
  printf '<testsuite><testcase classname="m" name="a"/></testsuite>' > "$GITCH_FLOW_OUT/junit.xml"; exit 0
fi
printf '<testsuite><testcase classname="m" name="a"><failure message="nope">at src/a.test.ts:3:1</failure></testcase></testsuite>' > "$GITCH_FLOW_OUT/junit.xml"; exit 1
R
  cat > "$1/.gitch/flow.yml" <<'F'
version: 1
suites:
  unit: { use: test.junit, with: { run: "sh tests/r.sh pass", report: "${{ node.out }}/junit.xml" } }
  broken: { use: test.junit, with: { run: "sh tests/r.sh fail", report: "${{ node.out }}/junit.xml" } }
flows:
  ok: { nodes: { unit: { suite: unit } } }
  bad: { nodes: { broken: { suite: broken } } }
F
}

test_flow_missing_engine_is_a_clear_error() {
  unset GITCH_FLOW
  run gitch flow version --json
  assert_rc 1
  assert_out '"code":"GITCH_ERROR"'
  assert_out 'gitch-flow'
  run gitch version --json; assert_ok
  assert_eq "$(printf '%s' "$OUT" | jq -r .flowApi)" "1"
}

test_flow_front_door_delegates() {
  need_flow || return 0
  run gitch flow version --json; assert_ok
  assert_eq "$(printf '%s' "$OUT" | jq -r .tool)" "gitch-flow"
  flow_repo "$T/r"; cd "$T/r" || fail cd
  # Before trust, a non-interactive run stops with confirmation needed (2).
  run gitch test unit --json; assert_rc 2; assert_out "TRUST-01"
  run gitch flow trust --yes; assert_ok
  run gitch test unit --json; assert_ok
  assert_eq "$(printf '%s' "$OUT" | jq -r .state)" "SUCCEEDED"
  run gitch flow run bad --summary; assert_rc 1
  assert_out "FLOW=FAILED"; assert_out "src/a.test.ts:3"
  run gitch schema flow-run; assert_ok; assert_json "$OUT"
  run gitch ci; [ "$RC" -ne 127 ] || fail "gitch ci lost its existing behaviour"
}

test_flow_preflight_line_and_pre_push_gate() {
  need_flow || return 0
  mk_config; install_quiet
  mk_remote_seeded github-alice alice/f alice@example.com
  gitch clone alice alice/f "$HOME/Develop/alice/f" >/dev/null 2>&1 || fail clone
  cd "$HOME/Develop/alice/f" || fail cd
  flow_repo "$PWD"
  git add -A && gitch c -m "Add flow" >/dev/null 2>&1 || fail commit
  run gitch flow trust --yes; assert_ok
  run gitch preflight; assert_no_out "FLOW="
  # Let the engine write its native settings paths and repository ID on every platform.
  run gitch flow gate on --flow ok --json; assert_ok
  assert_eq "$(printf '%s' "$OUT" | jq -r .gate)" "ON"
  run gitch preflight; assert_out "FLOW=WARN"
  run gitch preflight --json; assert_eq "$(printf '%s' "$OUT" | jq -r .flow)" "WARN"
  # When the gate runs the flow and it passes, the push goes through.
  run gitch p; assert_ok
  run gitch preflight; assert_out "FLOW=OK"
  # A failing flow blocks the push.
  run gitch flow gate on --flow bad --json; assert_ok
  echo y > y.txt && git add y.txt && gitch c -m "Add y" >/dev/null 2>&1 || fail commit2
  run gitch p; [ "$RC" -ne 0 ] || fail "a failing flow did not block the push"
  assert_out "FLOW=STOP"
}

test_flow_guard_rules() {
  mk_config
  expect deny 'gitch flow trust'
  expect deny 'gitch flow trust --yes'
  expect none 'gitch flow trust --show'
  expect deny 'gitch flow hold release prod'
  expect none 'gitch flow hold list'
  expect deny 'gitch flow gate on --flow pre-push'
  expect deny 'gitch flow gate off'
  expect none 'gitch flow gate status'
  expect ask 'gitch flow connect add jenkins --name ci --url https://ci.example.com'
  expect none 'gitch flow connect list'
  expect ask 'gitch flow run deploy --yes'
  expect ask 'gitch test --yes'
  expect none 'gitch test --affected --summary'
  expect none 'gitch flow plan pre-push --affected'
  expect deny 'GITCH_FLOW=/tmp/fake gitch flow run ok'
  expect deny 'HOME=/tmp/x gitch flow run ok'
  expect deny 'CI=true gitch flow run ok --ci'
  expect ask 'gitch ci trigger --workflow x'
  expect none 'gitch ci status'
  expect ask 'gitch flow export github --force'
}

test_flow_completion() {
  run gitch _complete -- ""; assert_ok; assert_out "flow"; assert_out "test"
  run gitch _complete -- flow ""; assert_ok; assert_out "init"; assert_out "trust"; assert_out "gate"
  run gitch _complete -- flow export ""; assert_ok; assert_out "jenkins"
}
