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
  run gitch help ci; assert_ok; assert_out 'logs'; assert_out 'browse'
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
  # The engine answers "help <subcommand>" with that subcommand's usage.
  run gitch help test; assert_ok; assert_out '사용법: gitch test'; assert_out 'gitch flow test [suite|tag'
  run gitch help ci; assert_ok; assert_out '사용법: gitch ci'; assert_out 'gitch flow ci browse --connection NAME'
  run gitch help flow run; assert_ok; assert_out '사용법: gitch flow'; assert_out 'gitch flow run <flow>'
}

test_help_overview_is_grouped_and_points_to_topics() {
  local name lines overview
  mk_config
  run gitch help; assert_ok; overview=$OUT
  assert_out '매일 쓰는 것'; assert_out 'PR / MR'; assert_out '계정/설정'
  assert_out '(계정: alice, bob, carol)'
  assert_out 'gitch preflight [--json] [--no-fetch]    커밋/push 전 한 번에 점검'
  assert_out '명령 하나 자세히: gitch help <명령>'
  assert_out '모든 명령 한 번에: gitch help --all'
  assert_out '종료코드: 0 정상'
  lines=$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')
  [ "$lines" -le 75 ] || fail "the overview grew to $lines lines"
  # Every command is in the overview, with its usage or at least by name; setup is no longer listed twice.
  for name in $(help_table_names); do
    [ "$name" != guard ] || continue
    printf '%s\n' "$overview" | grep -qE -- "(^  gitch | · |: )$name( |\$)" || fail "not in the overview: $name"
  done
  assert_eq "$(printf '%s\n' "$overview" | grep -c '^  gitch setup')" 1
  run gitch -h; assert_ok; assert_eq "$OUT" "$overview"
  run gitch --help; assert_ok; assert_eq "$OUT" "$overview"
}

test_help_all_prints_every_topic() {
  local name all first
  run gitch help --all; assert_ok; all=$OUT
  assert_out '━━ 매일 쓰는 것 ━━'
  for name in $(help_table_names); do
    run gitch help "$name"; assert_ok
    first=$(printf '%s\n' "$OUT" | sed -n 1p)
    case "$all" in *"$first"*) ;; *) fail "help --all has no topic for $name" ;; esac
  done
  [ "$(printf '%s\n' "$all" | grep -cE '^(예시|Examples)$')" -eq "$(help_table_names | grep -c .)" ] || fail 'help --all does not have one example block per command'
}

# ----- --help never runs the command -----

help_fixture() {   # an installed gitch and a locked repository where every command has something to do → cd
  mk_config; install_quiet
  mk_remote_seeded github-alice alice/app alice@example.com
  gitch clone alice alice/app "$HOME/Develop/alice/app" >/dev/null 2>&1 || fail 'clone'
  cd "$HOME/Develop/alice/app" || fail cd
  git branch merged-topic || fail 'branch'                      # prune would delete it
  git config --add gitswitch.protect release                    # protect would change the list
  echo one > one.txt; git add one.txt
  gitch c -m 'Local work' >/dev/null 2>&1 || fail 'commit'       # not pushed: undo, amend, fix and p would act on it
  gitch pl >/dev/null 2>&1 || fail 'pull'                        # leaves a backup for rescue
  echo two > two.txt; git add two.txt                           # staged: c and cp would commit it
  echo three > untracked.txt
  : > "$FAKE_REMOTES/.log"; : > "$FAKE_GH/log"; : > "$FAKE_WEB/log"
}
help_state() {   # everything a command could change: commits, refs, index, working tree, configuration, gitch settings, the remote, and what it called
  git rev-parse HEAD
  git log -1 --format=%B
  git for-each-ref --format='%(refname) %(objectname)'
  git status --porcelain
  git stash list
  git config --local --list | sort
  git --git-dir="$FAKE_REMOTES/github-alice/alice/app.git" for-each-ref --format='%(refname) %(objectname)'
  git config --global --list | sort
  # Files outside the repository: gitch settings and state, SSH and shell configuration, AI tool rules, anything newly made.
  find "$HOME" "$T" -path "$HOME/Develop/alice/app" -prune -o -path "$FAKE_REMOTES" -prune -o -type f -exec cksum {} + 2>/dev/null | LC_ALL=C sort -k 3
  find "$HOME/Develop" "$T" -maxdepth 2 -type d 2>/dev/null | LC_ALL=C sort
  cat "$FAKE_REMOTES/.log" "$FAKE_GH/log" "$FAKE_WEB/log" 2>/dev/null   # ssh, gh and curl calls: help uses no network
  ls "$T/opened" 2>/dev/null
}
assert_help_only() {   # $@ a gitch command line with a help flag: exit 0, a usage text, nothing changed
  run gitch "$@" < /dev/null
  [ "$RC" -eq 0 ] || fail "gitch $* exited $RC\n$OUT"
  case "$OUT" in *'사용법'*|*'Usage'*|*'gitch '*) ;; *) fail "gitch $* printed no usage\n$OUT" ;; esac
  [ "$(help_state)" = "$HELP_BEFORE" ] || fail "gitch $* changed something:\n$(diff <(printf '%s\n' "$HELP_BEFORE") <(help_state))"
}

test_help_flag_on_every_command_runs_nothing() {
  local name names
  names=$(help_dispatch_names)
  [ -n "$names" ] || fail 'could not read the dispatcher'
  help_fixture
  HELP_BEFORE=$(help_state)
  for name in $names; do
    assert_help_only "$name" --help
    assert_help_only "$name" -h
  done
  assert_eq "$(git log -1 --format=%s)" 'Local work'
  assert_eq "$(git config --get-all gitswitch.protect)" release
  assert_eq "$(git config --get gitswitch.account)" alice
  git show-ref -q --verify refs/heads/merged-topic || fail 'a branch is gone'
  git show-ref -q --verify refs/heads/--help && fail 'a branch named --help was made'
  [ ! -e ./--help ] && [ ! -e ./-h ] || fail 'a file named after the flag was made'
  return 0
}

test_help_flag_after_other_arguments_runs_nothing() {
  help_fixture
  HELP_BEFORE=$(help_state)
  # Each of these would change the repository, the settings or a remote without the help flag.
  assert_help_only amend new message --help
  assert_help_only amend -m 'New message' -h
  assert_help_only undo --help
  assert_help_only c -a --help
  assert_help_only c fix the bug -h
  assert_help_only cp -a -m 'Ship it' --help
  assert_help_only p --force --yes --help
  assert_help_only p -h --tags
  assert_help_only pl --help
  assert_help_only up -h
  assert_help_only sync --help
  assert_help_only b new-branch --help
  assert_help_only b --help
  assert_help_only protect main --help
  assert_help_only protect --rm release -h
  assert_help_only unlock --yes --help
  assert_help_only use bob --help
  assert_help_only ignore --yes --help
  assert_help_only fix --yes --help
  assert_help_only prune --yes --help
  assert_help_only rescue 1 --restore --yes --help
  assert_help_only rescue 1 --branch saved -h
  assert_help_only abort --yes --help
  assert_help_only continue --help
  assert_help_only publish other --public --yes --help
  assert_help_only pr --title 'A title' --help
  assert_help_only pr create -h
  assert_help_only ci --help
  assert_help_only clone alice alice/other --help
  assert_help_only clone --help
  assert_help_only fork alice teamb/tool -h
  assert_help_only export --help
  assert_help_only export "$T/exported.cfg" -h
  assert_help_only import "$HOME/.config/gitsw/config" --yes --help
  assert_help_only migrate --force --help
  assert_help_only config set gitsw.scanRoot /tmp --yes --help
  assert_help_only config unset gitsw.scanRoot --yes -h
  assert_help_only org add github.com/neworg alice --yes --help
  assert_help_only org rm github.com/teamb --yes -h
  assert_help_only add --id dave --email dave@example.com --no-setup --json --yes --help
  assert_help_only setup alice --generate --json --yes --help
  assert_help_only login github --start --json --yes --help
  assert_help_only sign on --yes --help
  assert_help_only ssh prune --yes --help
  assert_help_only ai --remove --help
  assert_help_only ai -h
  assert_help_only auto --help
  assert_help_only install --help
  assert_help_only uninstall --yes --help
  assert_help_only self-update --help
  assert_help_only scan --fix --help
  assert_help_only wt new side --help
  assert_help_only wt prune -h
  assert_help_only workspace create product . --help
  assert_help_only work start task --repo . --help
  assert_help_only work commit -a -h
  assert_help_only logo off --help
  assert_help_only git log --help
  assert_help_only d --stat -h
  assert_help_only o --help
  assert_help_only app --repo . --help
  assert_help_only g --out "$T/graph.html" --help
  assert_help_only g check --init -h
  assert_help_only flow run ok --yes --help
  assert_help_only flow init --yes --help
  assert_help_only test --affected --help
  assert_help_only ci status --help
  [ ! -e "$T/exported.cfg" ] && [ ! -e "$T/graph.html" ] && [ ! -e .gitch ] || fail 'a help request wrote a file'
}

test_help_flag_is_not_taken_from_values_or_after_the_separator() {
  help_fixture
  # The value of -m is a message, even when it reads like a flag.
  run gitch c -m '--help'; assert_ok
  assert_eq "$(git log -1 --format=%s)" '--help' 'c -m "--help" must commit with that message'
  echo four > four.txt; git add four.txt
  run gitch commit --message -h; assert_ok
  assert_eq "$(git log -1 --format=%s)" '-h'
  run gitch amend -m '--help'; assert_ok
  assert_eq "$(git log -1 --format=%s)" '--help'
  # After --, everything is an argument.
  echo five > five.txt; git add five.txt
  run gitch c -- --help; assert_ok
  assert_eq "$(git log -1 --format=%s)" '--help'
  run gitch audit . --since --help; assert_no_out '사용법: gitch audit' 'the value of --since was taken as a help flag'
  # A flag that only contains the word is not a help flag.
  run gitch status --helpful; assert_rc 1; assert_out '사용법: gitch status [--json] [--strict] [--ssh]'
}

test_help_flag_for_flow_commands_never_reaches_a_run() {
  local engine
  help_fixture
  mkdir -p .gitch
  printf 'version: 1\nflows:\n  ok:\n    nodes:\n      mark: "echo ran > ran.txt"\n' > .gitch/flow.yml
  unset GITCH_FLOW
  HELP_BEFORE=$(help_state)
  # Without an engine the help still answers.
  assert_help_only flow run ok --yes --help
  assert_out '흐름 엔진(gitch-flow)을 찾지 못해'
  assert_help_only test -h
  assert_help_only ci status --help
  engine=$(help_flow_bin) || { echo 'skipped: build gitch-flow first (cd tools/gitch-flow && cargo build)'; return 0; }
  export GITCH_FLOW="$engine" GITCH_FLOW_NO_KEYSTORE=1
  assert_help_only flow run ok --yes --help
  assert_out '사용법: gitch flow'; assert_out 'gitch flow run <flow>'
  assert_help_only flow --help
  assert_out 'gitch flow — '
  assert_help_only flow trust --yes -h
  assert_help_only test ok --help
  assert_out 'gitch flow test [suite|tag'
  assert_help_only ci status --help
  assert_out 'gitch flow ci status'
  [ ! -e ran.txt ] || fail 'a help request ran the flow'
  [ ! -d "$(git rev-parse --git-common-dir)/gitch" ] || fail 'a help request recorded a run'
}

# ----- unknown commands -----

test_help_unknown_command_suggests_close_names() {
  local out err lines
  mk_config
  gitch pusj > "$T/stdout" 2> "$T/stderr"; RC=$?
  out=$(cat "$T/stdout"); err=$(cat "$T/stderr")
  assert_eq "$RC" 1 'unknown command exit code'
  assert_eq "$out" '' 'the unknown-command hint belongs on stderr'
  assert_eq "$err" "알 수 없는 명령: pusj
비슷한 명령: push
명령 목록: gitch help"
  run gitch comit -m x; assert_rc 1; assert_out '비슷한 명령: commit'
  run gitch stauts; assert_rc 1; assert_out '비슷한 명령: status'
  run gitch chekc; assert_rc 1; assert_out '비슷한 명령: check'          # swapped letters
  run gitch pul; assert_rc 1; assert_out '비슷한 명령: pl, pull'         # a prefix and a one-letter slip
  run gitch PREFLIGTH; assert_rc 1; assert_out '비슷한 명령: preflight'
  run gitch work-space; assert_rc 1; assert_out '비슷한 명령: workspace'
  # Nothing close: no guess, only the pointer. Never the whole help.
  run gitch zzzzzz; assert_rc 1; assert_out '알 수 없는 명령: zzzzzz'; assert_no_out '비슷한 명령'; assert_out '명령 목록: gitch help'
  lines=$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')
  assert_eq "$lines" 2 'an unknown command prints the error and one pointer'
  run gitch x; assert_rc 1; assert_no_out '비슷한 명령'                  # one letter is too little to guess from
  run gitch gard; assert_rc 1; assert_no_out 'guard'                    # internal commands are not suggested
}

test_help_unknown_topic_suggests_close_names() {
  run gitch help pusj; assert_rc 1
  assert_out '알 수 없는 도움말 주제: pusj'; assert_out '비슷한 명령: push'; assert_out '명령 목록: gitch help'
  assert_no_out '매일 쓰는 것'
  run gitch help comit; assert_rc 1; assert_out '비슷한 명령: commit'
  run gitch help zzzzzz; assert_rc 1; assert_no_out '비슷한 명령'
  # Options that are not topics still show the overview, as before.
  run gitch help --json; assert_ok; assert_out '매일 쓰는 것'
}

test_help_unknown_command_keeps_the_machine_error() {
  local rc
  gitch pusj --json > "$T/stdout" 2> "$T/stderr"; rc=$?
  assert_eq "$rc" 1
  [ ! -s "$T/stdout" ] || fail 'the unknown command wrote to stdout'
  assert_eq "$(cat "$T/stderr")" '{"schemaVersion":1,"error":{"code":"GITCH_ERROR","message":"알 수 없는 명령: pusj","exitCode":1}}'
}

# ----- completion -----

test_help_completion_ci_and_flow_subcommands() {
  run gitch _complete -- ci ''; assert_ok; assert_eq "$OUT" $'browse\nlogs\nreport\nstatus'
  run gitch _complete -- ci st; assert_ok; assert_eq "$OUT" status
  run gitch _complete -- ci status ''; assert_ok; assert_eq "$OUT" '' 'ci subcommands are completed once'
  run gitch _complete -- ci status --c; assert_ok; assert_eq "$OUT" --connection
  run gitch _complete -- ci --; assert_ok; assert_out --json; assert_out --ref
  run gitch _complete -- flow ''; assert_ok; assert_out test; assert_out ci; assert_out design; assert_out init; assert_out trust
  run gitch _complete -- flow de; assert_ok; assert_eq "$OUT" design
  run gitch _complete -- flow design ''; assert_ok; assert_eq "$OUT" $'inspect\nrender\nsource'
  run gitch _complete -- flow ci ''; assert_ok; assert_eq "$OUT" $'browse\nlogs\nreport\nstatus'
}
