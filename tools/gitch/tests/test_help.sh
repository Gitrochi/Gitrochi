# shellcheck shell=bash
# gitch help: every command and alias the dispatcher accepts has a help topic, and the topics name the real options.

help_dispatch_names() {   # every command and alias in the dispatcher, read from the script so a new command is covered automatically
  awk '
    /^case "\$\{1:-\}" in$/ { on = 1; next }
    on && /^esac$/ { on = 0 }
    on && /^  [^ ]/ {
      s = $0; sub(/^  /, "", s); sub(/\).*/, "", s)
      n = split(s, a, "|")
      for (i = 1; i <= n; i++) if (a[i] ~ /^[a-z]/) print a[i]
    }' "$GITSW_SRC"
}
help_table_names() {   # the canonical names in the help table
  sed -n "/^HELP_COMMANDS='/,/'\$/p" "$GITSW_SRC" | sed "s/^HELP_COMMANDS=//" | tr -d "'" | tr ' ' '\n' | grep .
}
help_flow_bin() {   # the flow engine built in this repository, when there is one
  local b
  for b in "${GITCH_FLOW_TEST_BIN:-}" "$ROOT/../gitch-flow/target/release/gitch-flow" "$ROOT/../gitch-flow/target/debug/gitch-flow" \
           "$ROOT/../gitch-flow/target/release/gitch-flow.exe" "$ROOT/../gitch-flow/target/debug/gitch-flow.exe"; do
    [ -n "$b" ] && [ -x "$b" ] && { printf '%s' "$b"; return 0; }
  done
  return 1
}
assert_help_text() {   # OUT is one command's help: usage, what it changes, whether it uses the network, examples
  case "$OUT" in *'사용법'*|*'Usage'*|*'gitch '*) ;; *) fail "no usage line: $1\n$OUT" ;; esac
  case "$OUT" in *'변경: '*|*'Changes: '*) ;; *) fail "no effect line: $1\n$OUT" ;; esac
  case "$OUT" in *'네트워크: '*|*'Network: '*) ;; *) fail "no network line: $1\n$OUT" ;; esac
  case "$OUT" in *$'\n예시\n  gitch '*|*$'\n예시\n  git '*|*$'\n예시\n  source '*|*$'\nExamples\n  gitch '*) ;; *) fail "no example: $1\n$OUT" ;; esac
}

test_help_topic_for_every_dispatched_command() {
  local name names count=0
  names=$(help_dispatch_names)
  [ -n "$names" ] || fail 'could not read the dispatcher'
  for name in $names; do
    run gitch help "$name"; assert_ok "gitch help $name"
    assert_help_text "$name"
    count=$((count + 1))
  done
  [ "$count" -ge 70 ] || fail "only $count dispatcher names were found"
  # The table has no topic for a command that does not exist.
  for name in $(help_table_names); do
    printf '%s\n' "$names" | grep -qx -- "$name" || fail "help topic without a command: $name"
  done
}

test_help_topic_is_the_same_for_an_alias() {
  local canonical
  run gitch help p; assert_ok; canonical=$OUT
  assert_out '사용법: gitch p [--force] [--dry-run] [--tags] [--yes]'
  assert_out '별칭: push'
  assert_out '변경: 원격 저장소 (push)'
  run gitch help push; assert_ok
  assert_eq "$OUT" "$canonical" 'help push differs from help p'
  run gitch help ws; assert_ok; canonical=$OUT
  assert_out 'Usage: gitch workspace <command> [--json]'; assert_out 'Aliases: ws'
  run gitch help workspace; assert_ok
  assert_eq "$OUT" "$canonical" 'help workspace differs from help ws'
}

test_help_topics_name_options_the_old_help_left_out() {
  run gitch help p; assert_ok; assert_out '--dry-run'; assert_out '--tags'
  run gitch help ck; assert_ok; assert_out '--fetch'
  run gitch help status; assert_ok; assert_out '--ssh'
  run gitch help report; assert_ok; assert_out '--json'; assert_out '--since'
  run gitch help config; assert_ok; assert_out 'check'; assert_out 'unset-all'
  run gitch help wt; assert_ok; assert_out 'prune'
  run gitch help ai; assert_ok; assert_out '--skill'
  run gitch help pr; assert_ok; assert_out 'gitch pr [create]'; assert_out 'gitch pr list'
  run gitch help ci; assert_ok; assert_out 'trigger'; assert_out 'browse'
  run gitch help flow; assert_ok; assert_out 'design'
  run gitch help rescue; assert_ok; assert_out '--branch'; assert_out '--restore'
}

test_help_topic_keeps_a_commands_own_help() {
  run gitch help work; assert_ok; assert_out 'Usage: gitch work COMMAND [options]'; assert_out 'Aliases: w'
  run gitch help issue; assert_ok; assert_out 'gitch issue show NUMBER [--json]'
  run gitch help git; assert_ok; assert_out 'Usage: gitch git COMMAND'
  run gitch help graph; assert_ok; assert_out '사용법: gitch graph [files|modules|changes|tree]'; assert_out '별칭: g'
  run gitch help graph diff; assert_ok; assert_out '사용법: gitch graph diff'
  run gitch help module audit; assert_ok; assert_out '--strict: 직접 의존 누락 시 종료 1'
  run gitch help app; assert_ok; assert_out 'gitch app [저장소|폴더]'
  run gitch help overlap; assert_ok; assert_out '--fail-on-overlap'
  run gitch help logo; assert_ok; assert_out '사용법: gitch logo [on|off|status] [--json]'
}

test_help_flow_topics_show_the_engine_help() {
  local engine
  unset GITCH_FLOW
  run gitch help flow; assert_ok; assert_out '사용법: gitch flow'; assert_out '흐름 엔진(gitch-flow)을 찾지 못해'
  engine=$(help_flow_bin) || { echo 'skipped: build gitch-flow first (cd tools/gitch-flow && cargo build)'; return 0; }
  export GITCH_FLOW="$engine" GITCH_FLOW_NO_KEYSTORE=1
  run gitch help flow; assert_ok; assert_out '사용법: gitch flow'; assert_out 'gitch flow — '; assert_out 'validate [--json]'
  run gitch help test; assert_ok; assert_out '사용법: gitch test'; assert_out 'gitch flow — '
  run gitch help ci; assert_ok; assert_out '사용법: gitch ci'; assert_out 'gitch flow — '
}
