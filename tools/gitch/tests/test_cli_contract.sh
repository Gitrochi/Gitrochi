# shellcheck shell=bash
# 공개 JSON은 필드 형식과 오류 채널을 지키고, 자동완성은 입력을 실행하지 않아야 한다.

contract_repo() {
  mk_config
  mk_repo "$HOME/Develop/alice/Project with space"
  cd "$HOME/Develop/alice/Project with space" || fail cd
  git config user.name alice && git config user.email alice@example.com
  printf 'import { b } from "./b";\n' > a.ts
  printf 'export const b = 1;\n' > b.ts
  git add a.ts b.ts && git commit -q -m initial || fail 'contract fixture commit'
}
contract_validate() {   # $1 schema name, OUT payload
  printf '%s' "$OUT" > "$T/payload.json"
  gitch schema "$1" > "$T/schema.json" || fail 'schema command'
  assert_json "$OUT"
  if [ -n "${GITCH_JSONSCHEMA_PYTHON:-}" ]; then
    "$GITCH_JSONSCHEMA_PYTHON" "$ROOT/tests/validate_schema.py" "$T/schema.json" "$T/payload.json" || fail "formal schema validation: $1"
  fi
}

test_cli_contract_schema_embedded_matches_standalone() {
  run gitch schema; assert_ok; assert_json "$OUT"
  assert_eq "$(printf '%s' "$OUT" | jq -S .)" "$(jq -S . "$ROOT/schema/gitch-v1.schema.json")"
  assert_eq "$(printf '%s' "$OUT" | jq -r '."$schema"')" https://json-schema.org/draft/2020-12/schema
  assert_eq "$(printf '%s' "$OUT" | jq '."$defs".public.oneOf | length')" 20
  run gitch schema graph; assert_ok; assert_json "$OUT"
  assert_eq "$(printf '%s' "$OUT" | jq -r '."$ref"')" '#/$defs/graph'
  run gitch schema unknown --json; assert_rc 1; assert_json "$OUT"
}

test_cli_contract_staged_review_and_stamp() {
  contract_repo
  printf 'export const b = 2;\n' > b.ts
  git add b.ts
  run gitch graph review --json; assert_ok
  contract_validate review
  contract_validate public
  assert_eq "$(printf '%s' "$OUT" | jq -r .scope)" staged
  assert_eq "$(printf '%s' "$OUT" | jq -r '.direct[0].path')" a.ts
  run gitch graph review --stamp --json; assert_ok
  contract_validate review
  contract_validate public
  run gitch graph review --scope worktree --json; assert_rc 1
}

test_cli_contract_catalog_separates_analysis_depth() {
  run gitch g languages --json; assert_ok
  contract_validate languages
  assert_eq "$(printf '%s' "$OUT" | jq '.languages | length')" 73
  printf '%s' "$OUT" | jq -e '.languages | all(.fileDetection and (.preciseBackend | index("SCIP") != null))' >/dev/null || fail 'SCIP catalog'
  printf '%s' "$OUT" | jq -e '.languages[] | select(.id == "swift") | .heuristic and (.preciseBackend | index("SwiftIndex") != null)' >/dev/null || fail 'Swift catalog'
  printf '%s' "$OUT" | jq -e '.languages | all(select(.id != "swift") | .preciseBackend | index("SwiftIndex") == null)' >/dev/null || fail 'Swift index leaked to other language'
  printf '%s' "$OUT" | jq -e '.languages[] | select(.id == "java") | .staticImports and .heuristic and (.manifests | index("pom.xml") != null)' >/dev/null || fail 'Java catalog'
  printf '%s' "$OUT" | jq -e '.languages[] | select(.id == "csharp") | (.staticImports | not) and (.manifests | index("*.csproj") != null)' >/dev/null || fail 'C# file detection overstated as imports'
}

test_cli_contract_objects_and_legacy_array() {
  contract_repo
  local kind
  for kind in status ck preflight list doctor scan audit; do
    case "$kind" in
      ck|preflight) run gitch "$kind" --json --no-fetch ;;
      doctor) run gitch doctor --json --no-net ;;
      *) run gitch "$kind" --json ;;
    esac
    contract_validate "$kind"
    assert_eq "$(printf '%s' "$OUT" | jq .schemaVersion)" 1 "schemaVersion: $kind"
  done
  for kind in files modules changes tree; do
    OUT=$(gitch g "$kind" --json --min 1 2> "$T/graph-messages"); RC=$?; assert_eq "$RC" 0 "graph $kind exit"
    contract_validate graph
    printf '%s' "$OUT" | jq -e '.schemaVersion == 1 and (.nodes | type == "array") and (.edges | type == "array")' >/dev/null || fail "graph $kind"
  done
  printf '[files]\nno-cycles\n' > "$T/graph.rules"
  run gitch g check --rules "$T/graph.rules" --json; assert_ok
  contract_validate rules
  run gitch version --json; assert_ok; contract_validate version
  assert_eq "$(printf '%s' "$OUT" | jq -r .version)" "$(sed -n 's/^GITSW_VERSION="\([^"]*\)".*/\1/p' "$GITSW_SRC" | head -1)"
  run gitch report --json; assert_ok; contract_validate report
  assert_eq "$(printf '%s' "$OUT" | jq -r type)" array 'report array compatibility'
}

test_cli_contract_errors_have_stderr_json_and_no_stdout() {
  contract_repo
  local rc
  gitch g --unknown --json > "$T/stdout" 2> "$T/stderr"; rc=$?
  assert_eq "$rc" 1
  [ ! -s "$T/stdout" ] || fail 'fatal error polluted stdout'
  OUT=$(cat "$T/stderr"); contract_validate error
  assert_eq "$(printf '%s' "$OUT" | jq -r '.error.code')" GITCH_ERROR
  gitch unknown-command --format json > "$T/stdout" 2> "$T/stderr"; rc=$?
  assert_eq "$rc" 1
  [ ! -s "$T/stdout" ] || fail 'unknown command polluted stdout with help'
  OUT=$(cat "$T/stderr"); contract_validate error
  gitch unlock --json > "$T/stdout" 2> "$T/stderr"; rc=$?
  assert_eq "$rc" 2 'confirmation exit code preserved'
  [ ! -s "$T/stdout" ] || fail 'confirmation polluted stdout'
  OUT=$(cat "$T/stderr"); contract_validate error
  assert_eq "$(printf '%s' "$OUT" | jq -r '.error.code')" GITCH_CONFIRMATION_REQUIRED
  if [ -n "${GITCH_JSONSCHEMA_PYTHON:-}" ]; then
    printf '%s' "$OUT" | jq 'del(.error.exitCode)' > "$T/payload.json"
    if "$GITCH_JSONSCHEMA_PYTHON" "$ROOT/tests/validate_schema.py" "$T/schema.json" "$T/payload.json" >/dev/null 2>&1; then fail 'schema accepted error without exitCode'; fi
  fi
}

test_cli_contract_index_watch_and_saved_view() {
  contract_repo
  run gitch g index --language ts --json; assert_ok; contract_validate index
  assert_eq "$(printf '%s' "$OUT" | jq -r .executable)" scip-typescript
  OUT='{"schemaVersion":1,"tool":"gitch graph view","repo":"sample","relation":"files","filters":{"lang":"all","heur":true},"display":{"files":{"unit":"file","depth":1,"style":"dot","layout":"force","colorBy":"family","sizeBy":"auto"}},"hidden":[],"query":"src","selected":null,"camera":{"x":0,"y":0,"k":1},"theme":"dark","positions":[["a.ts",1,2,null,null]]}'
  contract_validate view
  if [ -n "${GITCH_JSONSCHEMA_PYTHON:-}" ]; then
    printf '%s' "$OUT" | jq '.camera.k = 0' > "$T/payload.json"
    if "$GITCH_JSONSCHEMA_PYTHON" "$ROOT/tests/validate_schema.py" "$T/schema.json" "$T/payload.json" >/dev/null 2>&1; then fail 'schema accepted zero saved-view zoom'; fi
  fi
  OUT=$(gitch g watch --out "$T/live.html" --interval 1 --detach --json --no-open 2> "$T/watch-messages"); RC=$?
  [ "$RC" -eq 0 ] || fail "watch JSON exit $RC\n$(cat "$T/watch-messages")\n$OUT"
  assert_eq "$RC" 0 'watch JSON exit'
  CONTRACT_WATCH_PID=$(printf '%s' "$OUT" | jq -r .pid)
  trap '[ -z "${CONTRACT_WATCH_PID:-}" ] || kill "$CONTRACT_WATCH_PID" 2>/dev/null; cd /; rm -rf "$T"' EXIT
  contract_validate watch
  local state_url
  state_url=$(printf '%s' "$OUT" | jq -r .stateUrl)
  OUT=$(python3 -c 'import sys,urllib.request; print(urllib.request.urlopen(sys.argv[1], timeout=5).read().decode())' "$state_url") || fail 'watch state endpoint'
  contract_validate watch
  kill "$CONTRACT_WATCH_PID" 2>/dev/null || true
  CONTRACT_WATCH_PID=""
}

test_cli_contract_watch_reports_helper_startup_error() {
  contract_repo
  local bundle="$T/failing watcher"
  mkdir -p "$bundle"
  cp "$GITSW_SRC" "$bundle/gitch"
  cat > "$bundle/gitch-graph-watch" <<'PY'
#!/usr/bin/env python3
import json
import sys
print(json.dumps({"schemaVersion": 1, "error": "watch-unavailable", "message": "fixture watcher startup failed"}))
sys.exit(3)
PY
  OUT=$(bash "$bundle/gitch" g watch --out "$T/failure.html" --detach --json --no-open 2> "$T/watch-error"); RC=$?
  assert_eq "$RC" 1 'watch helper failure must preserve public CLI exit code'
  assert_eq "$OUT" '' 'watch helper failure must keep stdout empty'
  grep -F 'fixture watcher startup failed' "$T/watch-error" >/dev/null || fail 'watch startup diagnostic was swallowed'
  tail -1 "$T/watch-error" | jq -e '.schemaVersion == 1 and .error.code == "GITCH_ERROR" and .error.exitCode == 1' >/dev/null || fail 'watch startup machine error contract'
}

test_cli_completion_candidates_are_dynamic_and_preserve_words() {
  contract_repo
  git branch feature/completion
  mkdir -p "$HOME/Develop/alice/Project with \$(touch SHOULD_NOT_EXIST)/.git"
  run gitch _complete -- com; assert_ok; assert_out completion
  run gitch _complete -- use a; assert_ok; assert_eq "$OUT" alice
  run gitch _complete -- b feature/; assert_ok; assert_eq "$OUT" feature/completion
  run gitch _complete -- g diff feature/; assert_ok; assert_eq "$OUT" feature/completion
  run gitch _complete -- g --lang ts,py; assert_ok; assert_eq "$OUT" ts,python
  run gitch _complete -- g --lang=py; assert_ok; assert_eq "$OUT" --lang=python
  run gitch _complete -- g --format j; assert_ok; assert_eq "$OUT" json
  run gitch _complete -- g wat; assert_ok; assert_eq "$OUT" watch
  run gitch _complete -- g watch --det; assert_ok; assert_eq "$OUT" --detach
  run gitch _complete -- g --pre; assert_ok; assert_eq "$OUT" --precise
  run gitch _complete -- app --view aff; assert_ok; assert_eq "$OUT" affected
  run gitch _complete -- g --scip; assert_ok; assert_eq "$OUT" '' 'nonexistent graph flag'
  run gitch _complete --empty-current -- g; assert_ok; assert_out precise; assert_out languages
  run gitch _complete -- g 'Project with '; assert_ok; assert_out 'Project with space'; assert_out 'Project with $(touch SHOULD_NOT_EXIST)'
  [ ! -e SHOULD_NOT_EXIST ] || fail 'completion evaluated repository name'
  gitch completion bash > "$T/completion.bash"
  run bash -n "$T/completion.bash"; assert_ok
  run bash -c 'source "$1"; COMP_WORDS=(gitch g "Project with "); COMP_CWORD=2; _gitch_completion; printf "<%s>\n" "${COMPREPLY[@]}"' _ "$T/completion.bash"
  assert_ok; assert_out '<Project with space>'; assert_out '<Project with $(touch SHOULD_NOT_EXIST)>'
  if command -v zsh >/dev/null 2>&1; then
    gitch completion zsh > "$T/completion.zsh"
    run zsh -n "$T/completion.zsh"; assert_ok
    run zsh -c 'compdef() { :; }; compadd() { local key=$2; print -rl -- "${(@P)key}"; }; source "$1"; words=(gitch g "Project with "); CURRENT=3; _gitch_completion' _ "$T/completion.zsh"
    assert_ok; assert_out 'Project with space'; assert_out 'Project with $(touch SHOULD_NOT_EXIST)'
  fi
  run gitch completion fish; assert_ok; assert_out 'command gitch _complete -- $words "$current"'
  if command -v fish >/dev/null 2>&1; then
    gitch completion fish > "$T/completion.fish"
    run fish -n "$T/completion.fish"; assert_ok
    run fish -c 'source "$argv[1]"; complete --do-complete "gitch g Project"' "$T/completion.fish"
    assert_ok; assert_out 'Project with space'; assert_out 'Project with $(touch SHOULD_NOT_EXIST)'
    [ ! -e SHOULD_NOT_EXIST ] || fail 'fish completion evaluated repository name'
  fi
  run gitch completion powershell; assert_ok; assert_out 'Register-ArgumentCompleter -Native'; assert_out 'candidate.Replace'
}

test_cli_completion_powershell_runtime() {
  local pwsh_bin="${GITCH_TEST_PWSH:-}" hostile_name branch
  [ -n "$pwsh_bin" ] || pwsh_bin=$(command -v pwsh 2>/dev/null)
  [ -n "$pwsh_bin" ] || return 0
  contract_repo
  [ -z "$IS_WIN" ] || install_quiet   # PowerShell needs the temporary gitch.cmd shim on Windows.
  if [ -n "$IS_WIN" ]; then
    printf -v hostile_name '%s%s' "Project with 'single' " '$(touch SHOULD_NOT_EXIST)'
  else
    printf -v hostile_name '%s%s' "Project with \"quote\" and 'single' " '$(touch SHOULD_NOT_EXIST)'
  fi
  printf -v branch '%s%s' 'feature/$literal-quote' "'name"
  mkdir -p "$HOME/Develop/alice/$hostile_name/.git" || fail 'PowerShell hostile repository fixture'
  git branch "$branch"
  gitch completion powershell > "$T/completion.ps1"
  run "$pwsh_bin" -NoLogo -NoProfile -NonInteractive -File "$ROOT/tests/completion_powershell.ps1" -CompletionScript "$T/completion.ps1"
  assert_ok; assert_json "$OUT"
  printf '%s' "$OUT" | jq -e --arg expected "$hostile_name" '.repoArguments | index($expected) != null' >/dev/null || fail 'PowerShell quoted repository round trip'
  printf '%s' "$OUT" | jq -e --arg expected "$branch" '.branchArguments | index($expected) != null' >/dev/null || fail 'PowerShell quoted branch round trip'
  printf '%s' "$OUT" | jq -e '.repoArguments | index("Project with space") != null' >/dev/null || fail 'PowerShell spaces'
  printf '%s' "$OUT" | jq -e '.quotedArguments | index("Project with space") != null' >/dev/null || fail 'PowerShell typed quoted prefix'
  assert_eq "$(printf '%s' "$OUT" | jq -r '.precise[0]')" --precise
  assert_eq "$(printf '%s' "$OUT" | jq -r '.watch[0]')" --detach
  assert_eq "$(printf '%s' "$OUT" | jq -r '.completedLanguageLine')" 'gitch g --lang ts,python'
  assert_eq "$(printf '%s' "$OUT" | jq -r '.nativeLanguageArguments[0]')" 'ts,python'
  assert_eq "$(printf '%s' "$OUT" | jq -r '.accounts[0]')" alice
  printf '%s' "$OUT" | jq -e '.subcommands | index("precise") != null' >/dev/null || fail 'PowerShell empty current word'
  [ ! -e SHOULD_NOT_EXIST ] || fail 'PowerShell completion executed repository text'
}
