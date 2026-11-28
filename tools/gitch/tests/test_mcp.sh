# shellcheck shell=bash disable=SC2034   # OUT and RC are read by lib.sh's asserts
# gitch mcp: the Model Context Protocol server AI clients start (JSON-RPC over stdin/stdout, one message per line)

MCPT_INIT='{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"claude-code","version":"test"},"capabilities":{}}}'

mcpt_session() {   # each argument is one message line → OUT the server's stdout, RC its exit code, $T/mcp-stderr its stderr
  OUT=$(printf '%s\n' "$@" | gitch mcp 2> "$T/mcp-stderr"); RC=$?
}
mcpt_response() {   # $1 id → that response from OUT (exactly one, or the test fails)
  local r
  r=$(printf '%s\n' "$OUT" | jq -c --argjson id "$1" 'select(.id == $id)') || fail "server output is not JSON lines\n$OUT"
  [ "$(printf '%s\n' "$r" | grep -c .)" = 1 ] || fail "expected one response with id $1\n--- output:\n$OUT"
  printf '%s' "$r"
}
mcpt_call() {   # $1 id $2 tool [$3 arguments JSON] → one tools/call line
  local a=${3:-'{}'}
  jq -cn --argjson id "$1" --arg n "$2" --argjson a "$a" '{jsonrpc: "2.0", id: $id, method: "tools/call", params: {name: $n, arguments: $a}}'
}
mcpt_text() { mcpt_response "$1" | jq -r '.result.content[0].text'; }   # $1 id → the tool's text
mcpt_error_flag() { mcpt_response "$1" | jq -r '.result.isError'; }   # $1 id → true | false
mcpt_alice_repo() {   # a locked alice clone with one commit → cd (the server starts here)
  mk_config; install_quiet
  mk_remote_seeded github-alice alice/app alice@example.com
  gitch clone alice alice/app "$HOME/Develop/alice/app" >/dev/null 2>&1 || fail "clone failed"
  cd "$HOME/Develop/alice/app" || fail cd
}

test_mcp_initialize_and_tool_list() {
  mcpt_alice_repo
  mcpt_session "$MCPT_INIT" '{"jsonrpc":"2.0","method":"notifications/initialized"}' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
    '{"jsonrpc":"2.0","id":2,"method":"ping"}'
  assert_ok
  assert_eq "$(printf '%s\n' "$OUT" | grep -c .)" 3 'one answer per request and none for the notification'
  assert_eq "$(mcpt_response 0 | jq -r '.result.protocolVersion')" 2025-06-18 'the version the client asked for'
  assert_eq "$(mcpt_response 0 | jq -r '.result.serverInfo.name')" gitch
  assert_eq "$(mcpt_response 0 | jq -r '.result.capabilities.tools.listChanged')" false
  case "$(mcpt_response 0 | jq -r '.result.instructions')" in *'[gitch] refusal'*) ;; *) fail 'instructions do not explain refusals' ;; esac
  assert_eq "$(mcpt_response 1 | jq -r '[.result.tools[].name] | sort | join(" ")')" 'branch ci commit continue pr_create pr_status preflight pull push rescue_list status test'
  # Every tool declares an object schema with the repository argument, a description and its hints.
  assert_eq "$(mcpt_response 1 | jq '[.result.tools[] | select(.inputSchema.type != "object" or .inputSchema.properties.repository.type != "string" or (.description | length) < 20 or .annotations.readOnlyHint == null)] | length')" 0
  assert_eq "$(mcpt_response 2 | jq -c '.result')" '{}'
  # An unknown version gets the newest one the server speaks.
  mcpt_session '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"1999-01-01","clientInfo":{"name":"x"}}}'
  assert_eq "$(mcpt_response 0 | jq -r '.result.protocolVersion')" 2025-11-25
}

test_mcp_protocol_errors() {
  mcpt_alice_repo
  mcpt_session "$MCPT_INIT" 'not json' '[1,2]' '{"jsonrpc":"2.0","id":"a","method":"nope"}' \
    "$(mcpt_call 3 missing)" '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"status","arguments":[1]}}' \
    '{"jsonrpc":"2.0","method":"nope/notification"}' '   ' '{"jsonrpc":"2.0","id":5,"method":"ping"}'
  assert_ok
  assert_eq "$(printf '%s\n' "$OUT" | jq -c 'select(.id == null) | .error.code' | tr '\n' ' ')" '-32700 -32600 ' 'parse error, then invalid request'
  assert_eq "$(mcpt_response '"a"' | jq -r '.error.code')" -32601
  assert_eq "$(mcpt_response 3 | jq -r '.error.code')" -32602
  assert_eq "$(mcpt_response 4 | jq -r '.error.code')" -32602
  assert_eq "$(mcpt_response 5 | jq -c '.result')" '{}' 'the server keeps answering after errors'
  assert_eq "$(printf '%s\n' "$OUT" | grep -c .)" 7 'nothing for a notification or a blank line'
  run gitch mcp extra; assert_fail 'gitch mcp takes no arguments'
}

test_mcp_read_tools_return_gitch_json() {
  mcpt_alice_repo
  echo b > b.txt
  mcpt_session "$MCPT_INIT" "$(mcpt_call 1 status '{"fetch":false}')" "$(mcpt_call 2 preflight '{"fetch":false}')" \
    "$(mcpt_call 3 rescue_list)" '{"jsonrpc":"2.0","id":4,"method":"ping"}'
  assert_ok
  assert_eq "$(mcpt_error_flag 1)" false
  assert_eq "$(mcpt_response 1 | jq -r '.result.structuredContent.changes.account')" alice
  assert_eq "$(mcpt_response 1 | jq -r '.result.structuredContent.changes.untracked[0]')" b.txt
  assert_eq "$(mcpt_response 1 | jq -r '.result.structuredContent.account.lockedAccount')" alice
  assert_eq "$(mcpt_text 1 | jq -r '.changes.branch')" main 'the text carries the same JSON'
  assert_eq "$(mcpt_response 2 | jq -r '.result.structuredContent.result')" OK
  assert_eq "$(mcpt_error_flag 2)" false
  assert_eq "$(mcpt_error_flag 3)" false
  assert_eq "$(mcpt_response 4 | jq -c '.result')" '{}'
  [ ! -s "$T/mcp-stderr" ] || fail "the server wrote to stderr:\n$(cat "$T/mcp-stderr")"
}

test_mcp_preflight_stop_is_a_result_not_a_failure() {
  mcpt_alice_repo
  git config gitch.account bob   # locked to another account than the folder's: gitch answers STOP
  mcpt_session "$MCPT_INIT" "$(mcpt_call 1 preflight '{"fetch":false}')"
  assert_eq "$(mcpt_response 1 | jq -r '.result.structuredContent.result')" STOP
  assert_eq "$(mcpt_error_flag 1)" false
}

test_mcp_repository_argument() {
  mcpt_alice_repo
  mkdir -p "$T/plain" sub
  mcpt_session "$MCPT_INIT" "$(mcpt_call 1 status "$(jq -cn --arg r "$T/missing" '{repository: $r, fetch: false}')")" \
    "$(mcpt_call 2 status "$(jq -cn --arg r "$T/plain" '{repository: $r, fetch: false}')")" \
    "$(mcpt_call 3 status '{"repository":"sub","fetch":false}')" \
    "$(mcpt_call 4 status "$(jq -cn --arg r "$HOME/Develop/alice/app" '{repository: $r, fetch: false}')")"
  assert_eq "$(mcpt_error_flag 1)" true; case "$(mcpt_text 1)" in 'No such folder'*) ;; *) fail "$(mcpt_text 1)" ;; esac
  assert_eq "$(mcpt_error_flag 2)" true; case "$(mcpt_text 2)" in 'Not inside a Git work tree'*) ;; *) fail "$(mcpt_text 2)" ;; esac
  assert_eq "$(mcpt_error_flag 3)" false 'a folder relative to the start folder'
  assert_eq "$(mcpt_response 4 | jq -r '.result.structuredContent.changes.repo')" app
  # The start folder is the project folder Claude Code names, not where the process happens to run.
  cd "$T" || fail cd
  OUT=$(printf '%s\n' "$MCPT_INIT" "$(mcpt_call 1 status '{"fetch":false}')" | CLAUDE_PROJECT_DIR="$HOME/Develop/alice/app" gitch mcp 2>/dev/null)
  assert_eq "$(mcpt_response 1 | jq -r '.result.structuredContent.changes.account')" alice
}

test_mcp_commit_stages_the_given_files_under_the_lock() {
  mcpt_alice_repo
  echo a > a.txt; echo b > b.txt; mkdir -p 'dir with space'; echo c > 'dir with space/*.txt'; echo d > 'dir with space/other.txt'
  mcpt_session "$MCPT_INIT" \
    "$(mcpt_call 1 commit '{"title":"feat: add a","body":"- why a","files":["a.txt"]}')" \
    "$(mcpt_call 2 commit '{"title":"nothing staged"}')" \
    "$(mcpt_call 3 commit '{"title":"feat: literal path","files":["dir with space/*.txt"]}')" \
    "$(mcpt_call 4 commit '{"title":"x","files":["a.txt"],"all":true}')" \
    "$(mcpt_call 5 commit '{"title":"x","files":"a.txt"}')" \
    "$(mcpt_call 6 commit '{"body":"no title"}')" \
    "$(mcpt_call 7 commit '{"title":"chore: the rest","all":true}')"
  assert_ok
  assert_eq "$(mcpt_error_flag 1)" false "$(mcpt_text 1)"
  assert_eq "$(mcpt_error_flag 2)" true 'gitch stops when nothing is staged'
  case "$(mcpt_text 2)" in *'git add'*) ;; *) fail "no staging hint: $(mcpt_text 2)" ;; esac
  assert_eq "$(mcpt_error_flag 3)" false "$(mcpt_text 3)"
  for i in 4 5 6; do assert_eq "$(mcpt_error_flag $i)" true "call $i should fail"; done
  assert_eq "$(mcpt_error_flag 7)" false "$(mcpt_text 7)"
  assert_eq "$(git log --format=%s | tr '\n' '|')" 'chore: the rest|feat: literal path|feat: add a|init|'
  assert_eq "$(git show --name-only --format= HEAD~2)" a.txt
  assert_eq "$(git show --name-only --format= HEAD~1)" 'dir with space/*.txt' 'the path is taken literally'
  assert_eq "$(git show --name-only --format= HEAD | tr '\n' '|')" 'b.txt|dir with space/other.txt|'
  assert_eq "$(git log -1 --format=%b HEAD~2 | head -1)" '- why a'
  assert_eq "$(git log --format=%ae -3 | sort -u)" alice@example.com 'commits use the locked account'
}

test_mcp_commit_refusal_comes_back_as_an_error() {
  mcpt_alice_repo
  printf 'token = "ghp_%s"\n' "abcdefghijklmnopqrstuvwxyz0123456789" > conf.py
  mcpt_session "$MCPT_INIT" "$(mcpt_call 1 commit '{"title":"feat: conf","files":["conf.py"]}')"
  assert_eq "$(mcpt_error_flag 1)" true
  case "$(mcpt_text 1)" in *'[gitch]'*) ;; *) fail "the hook's refusal is missing:\n$(mcpt_text 1)" ;; esac
  assert_eq "$(git rev-list --count HEAD)" 1 'nothing was committed'
}

test_mcp_branch_push_pull_and_pull_request() {
  mcpt_alice_repo
  echo tok-alice > "$FAKE_GH/tokens/alice"
  echo f > f.txt
  mcpt_session "$MCPT_INIT" "$(mcpt_call 1 branch '{"name":"feature/mcp"}')" \
    "$(mcpt_call 2 commit '{"title":"feat: f","files":["f.txt"]}')" "$(mcpt_call 3 push)" "$(mcpt_call 4 pull)" \
    "$(mcpt_call 5 pr_create '{"title":"t","body":"b","draft":true}')" "$(mcpt_call 6 branch '{"name":"-x"}')" \
    "$(mcpt_call 7 branch '{"name":"bad..name"}')" "$(mcpt_call 8 pr_create '{"title":"t","base":"--web"}')" \
    "$(mcpt_call 9 push '{"dry_run":true}')"
  assert_ok
  for i in 1 2 3 4 5 9; do assert_eq "$(mcpt_error_flag $i)" false "call $i: $(mcpt_text $i)"; done
  assert_eq "$(git symbolic-ref --short HEAD)" feature/mcp
  git --git-dir "$FAKE_REMOTES/github-alice/alice/app.git" rev-parse -q --verify refs/heads/feature/mcp >/dev/null || fail 'the branch is not on origin'
  grep -q -- 'GH_TOKEN=tok-alice pr create -R alice/app --head feature/mcp --base main --title t --body b' "$FAKE_GH/log" || fail "gh call:\n$(cat "$FAKE_GH/log")"
  grep -q -- '--draft' "$FAKE_GH/log" || fail 'draft was not passed'
  case "$(mcpt_text 5)" in *'https://github.com/alice/app/pull/7'*) ;; *) fail "no URL: $(mcpt_text 5)" ;; esac
  for i in 6 7 8; do assert_eq "$(mcpt_error_flag $i)" true "call $i should fail"; done
}

test_mcp_test_tool_is_not_a_pass_without_tests() {
  mcpt_alice_repo
  mcpt_session "$MCPT_INIT" "$(mcpt_call 1 test)" "$(mcpt_call 2 test '{"suite":"--yes"}')"
  assert_eq "$(mcpt_error_flag 1)" true 'no flow file is not a pass'
  [ -n "$(mcpt_text 1)" ] || fail 'no explanation'
  assert_eq "$(mcpt_error_flag 2)" true
  case "$(mcpt_text 2)" in *'must not start with -'*) ;; *) fail "$(mcpt_text 2)" ;; esac
}
