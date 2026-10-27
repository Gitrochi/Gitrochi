# shellcheck shell=bash
# Claude Code 명령 검사 훅 (gitch guard --claude)

gd() {   # $1 명령 [$2 cwd] → deny | ask | none
  local json out
  json=$(jq -cn --arg c "$1" --arg d "${2:-$T}" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}')
  out=$(printf '%s' "$json" | gitch guard --claude 2>&1)
  if [ -z "$out" ]; then echo none; return; fi
  printf '%s' "$out" | jq -e . >/dev/null 2>&1 || { echo "BADJSON:$out"; return; }
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision'
}
ge() {   # Edit 도구 → 결정
  local json out
  json=$(jq -cn --arg p "$1" --arg d "$T" '{tool_name: "Edit", tool_input: {file_path: $p}, cwd: $d}')
  out=$(printf '%s' "$json" | gitch guard --claude 2>&1)
  if [ -z "$out" ]; then echo none; else printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision'; fi
}
expect() {   # $1 기대 $2 명령 [$3 cwd]
  local got; got=$(gd "$2" "${3:-}")
  [ "$got" = "$1" ] || fail "기대 $1, 실제 $got  ← $2"
}

test_guard_git_commit_rules() {
  mk_config
  expect none 'git status'
  expect none 'git commit -m "fix: handle --no-verify flag text"'
  expect deny 'git commit --no-verify -m x'
  expect deny 'git commit -nm x'
  expect deny 'git commit -m x -n'
  expect none 'git commit -am "x"'
  expect none 'git commit -m "-n is a word"'
  expect ask 'git commit --amend --no-edit'
  expect ask 'git commit --author="Bob <b@x>" -m x'
  expect none "git commit -m \"\$(cat <<'EOF'
feat: x

git push --force 같은 글자가 본문에 있어도 괜찮다
--no-verify
EOF
)\""
  expect deny 'git -c user.email=x@y commit -m x'
  expect deny 'git -c core.hooksPath=/dev/null commit -m x'
  expect deny 'git -c hook.gitsw-pre-commit.enabled=false commit -m x'
  expect none 'git -c color.ui=always log'
}

test_guard_push_rules() {
  mk_config
  expect ask 'git push'
  expect ask 'git push -u origin feat'
  expect deny 'git push --force'
  expect deny 'git push -f origin main'
  expect deny 'git push origin +main'
  expect deny 'git push --force-with-lease origin feat'
  expect deny 'git push -uf origin feat'
  expect ask 'git push origin :old-branch'
  expect ask 'git push --delete origin old'
  expect deny 'git push --no-verify'
  expect deny 'cd /tmp && git push --force'
  expect ask 'gitch p'
  expect ask 'gitch cp -m "x"'
  expect ask 'gitch p --force'
  expect ask 'gitch pr --title t'
  expect none 'gitch pr status'
  git config -f "$HOME/.config/gitsw/config" gitsw.aiPush allow
  expect none 'git push'
  expect none 'gitch p'
  expect ask 'gitch p --force'
  expect deny 'git push -f'
}

test_guard_env_and_config_rules() {
  mk_config
  expect deny 'GIT_AUTHOR_EMAIL=x@y git commit -m y'
  expect deny 'GITSW_SKIP=secrets git commit -m y'
  expect deny 'env GITSW_SKIP=all git push'
  expect deny 'export GIT_SSH_COMMAND="ssh -i key"'
  expect none 'GITSW_COLOR=always gitch ck'
  expect none 'GITSW_TEST_TMP=/tmp tests/run.sh'
  expect deny 'GITSW_CONFIG=/tmp/other git commit -m x'
  expect deny 'GITSW_ALLOW_FORCE=1 git push'
  expect deny 'GITSW_NOLOG_PUSH=1 git push'
  expect deny 'git config --global user.email x@y'
  expect deny 'git config user.email x@y'
  expect deny 'git config set user.name x'
  expect deny 'git config remote.origin.url git@github.com:x/y.git'
  expect none 'git config user.email'
  expect none 'git config --get user.email'
  expect none 'git config --list'
  expect none 'git config pull.rebase true'
  expect deny 'git config --global pull.rebase true'
  expect deny 'git config -f ~/.gitconfig user.email x'
  expect deny 'git config alias.pf "push --force"'
}

test_guard_destructive_local_rules() {
  mk_config
  expect ask 'git reset --hard'
  expect none 'git reset --soft HEAD~1'
  expect ask 'git clean -fd'
  expect none 'git clean -n'
  expect none 'git clean -fdn'
  expect ask 'git checkout -- src/a.ts'
  expect ask 'git checkout .'
  expect none 'git checkout main'
  expect none 'git checkout -b feat'
  echo x > "$T/file.txt"
  expect ask 'git checkout file.txt' "$T"
  expect none 'git restore --staged a.txt'
  expect ask 'git restore a.txt'
  expect ask 'git branch -D old'
  expect none 'git branch -d old'
  expect ask 'git stash drop'
  expect none 'git stash'
  expect ask 'git remote add upstream git@github.com:x/y.git'
  expect none 'git remote -v'
  expect ask 'git filter-branch --tree-filter x'
  expect ask 'git reflog expire --expire=now --all'
}

test_guard_clone_rules() {
  mk_config
  expect deny 'git clone git@github.com:alice/x.git'
  expect deny 'git clone https://github.com/teamb/x' "$T"
  expect deny 'git clone https://gitlab.example.com/grp/x.git'
  expect none 'git clone https://github.com/stranger/lib' "$T"
  expect deny 'git clone https://github.com/stranger/lib' "$HOME/Develop/alice"
  expect none 'git clone https://example.org/x.git'
  expect deny 'git clone -c user.email=x@y https://example.org/x.git'
}

test_guard_gitsw_rules() {
  mk_config; install_quiet
  mk_repo "$HOME/Develop/alice/r" "git@github-alice:alice/r.git"
  (cd "$HOME/Develop/alice/r" && gitch use alice >/dev/null)
  local r="$HOME/Develop/alice/r"
  expect none 'gitch ck' "$r"
  expect none 'gitch preflight --json' "$r"
  expect none 'gitch use alice' "$r"
  expect ask 'gitch use bob' "$r"
  expect ask "cd $r && gitch use bob"
  expect ask 'gitch unlock' "$r"
  expect deny 'gitch add'
  expect deny 'gitch setup'
  expect deny 'gitch sign on'
  expect none 'gitch sign'
  expect none 'gitch fix' "$r"
  expect ask 'gitch fix --yes' "$r"
  expect ask 'gitch undo' "$r"
  expect ask 'gitch config set gitsw.aiPush allow'
  expect none 'gitch config show'
  expect ask 'gitch org add github.com/x alice'
  expect none 'gitch org'
  expect ask 'gitch install'
  expect ask 'gitch self-update'
  expect none 'gitch ai --print'
  expect ask 'gitch scan --fix'
  expect none 'gitch scan'
}

test_guard_protected_files() {
  mk_config
  expect deny 'echo x > ~/.gitconfig'
  expect deny 'echo "Host x" >> ~/.ssh/config'
  expect none 'cat ~/.ssh/config'
  expect deny "sed -i '' 's/a/b/' ~/.ssh/config"
  expect none "sed 's/a/b/' ~/.ssh/config"
  expect deny 'cp /tmp/x ~/.ssh/config'
  expect none 'cp ~/.ssh/config /tmp/x'
  expect deny 'rm -rf ~/.config/gitsw'
  expect deny 'tee -a .git/hooks/pre-commit' "$T"
  expect deny 'rm .git/hooks/pre-push' "$T"
  expect ask 'ssh-keygen -t ed25519 -f ~/.ssh/new'
  expect none 'ssh-keygen -lf ~/.ssh/id_ed25519_alice.pub'
  expect none 'ls | grep git'
  expect none 'git log --oneline | head -5'
  [ "$(ge "$HOME/.ssh/config")" = deny ] || fail "Edit ~/.ssh/config 는 deny"
  [ "$(ge "$HOME/.claude/settings.json")" = ask ] || fail "Edit settings.json 은 ask"
  [ "$(ge "$T/src/a.ts")" = none ] || fail "일반 파일 Edit 은 통과"
}

test_guard_fast_and_robust() {
  mk_config
  local out
  out=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"npm test"}}' | gitch guard --claude); [ -z "$out" ] || fail "관계없는 명령은 출력 없음"
  out=$(printf '%s' 'not json at all git' | gitch guard --claude); [ -z "$out" ] || fail "깨진 입력은 통과(출력 없음)"
  out=$(printf '%s' '{"tool_name":"Read","tool_input":{"file_path":"/x/.git/config"}}' | gitch guard --claude); [ -z "$out" ] || fail "읽기 도구는 검사 안 함"
  printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git push -f"}}' | gitch guard --claude >/dev/null; [ $? -eq 0 ] || fail "guard 는 항상 종료코드 0"
}

test_guard_branch_push_policy() {
  mk_config; install_quiet
  mk_remote_seeded github-alice alice/pp alice@example.com
  gitch clone alice alice/pp "$HOME/Develop/alice/pp" >/dev/null 2>&1 || fail clone
  local r="$HOME/Develop/alice/pp"
  git config -f "$HOME/.config/gitsw/config" gitsw.aiPush branch
  # 기본 브랜치(main) 위에서는 확인
  expect ask 'gitch p' "$r"
  expect ask 'gitch cp -m x' "$r"
  expect ask 'git push' "$r"
  expect ask 'git push origin main' "$r"
  # 작업 브랜치는 자동
  git -C "$r" switch -q -c feat
  expect none 'gitch p' "$r"
  expect none 'gitch cp -m "x"' "$r"
  expect none 'git push' "$r"
  expect none 'git push -u origin feat' "$r"
  expect none 'git push origin HEAD' "$r"
  expect none "cd $r && git add . && gitch c -m x && gitch p"
  expect ask 'git push origin feat:main' "$r"
  expect ask 'git push origin HEAD:refs/heads/master' "$r"
  expect ask 'git push origin --tags' "$r"
  expect ask 'git push origin v1:refs/tags/v1' "$r"
  expect deny 'git push -f origin feat' "$r"
  expect ask 'gitch p --force' "$r"
  expect ask 'gitch pr --title t' "$r"
  expect none 'gitch pr status' "$r"
  # 보호 브랜치, 기본 브랜치가 develop 인 저장소
  git -C "$r" config --add gitswitch.protect release
  expect ask 'git push origin release' "$r"
  git -C "$r" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop
  expect ask 'git push origin develop' "$r"
  expect ask 'git push origin main' "$r"
  # 브랜치를 알 수 없으면 확인
  git -C "$r" checkout -q --detach
  expect ask 'gitch p' "$r"
  # allow: PR 도 자동, 강제 push 는 여전히 거부
  git config -f "$HOME/.config/gitsw/config" gitsw.aiPush allow
  expect none 'gitch pr --title t' "$r"
  expect deny 'git push --force' "$r"
}

test_branch_policy_rules_and_allow_list() {
  mk_config; install_quiet
  run gitch config set gitsw.aiPush sometimes --yes; assert_fail
  run gitch config set gitsw.aiPush branch --yes; assert_ok
  grep -q '작업 브랜치 push 는 바로 되고' "$HOME/.claude/CLAUDE.md" || fail "AI 규칙에 push 정책이 없음"
  local s="$HOME/.claude/settings.json" e
  for e in "Bash(git add:*)" "Bash(gitch c:*)" "Bash(gitch p:*)" "Bash(git push:*)" "Bash(gitch pr:*)" "Bash(gitch wt:*)"; do
    [ "$(jq --arg e "$e" '[.permissions.allow[] | select(. == $e)] | length' "$s")" = 1 ] || fail "허용 목록에 없음: $e"
  done
  [ "$(jq '[.permissions.allow[] | select(. == "Bash(gitch b)" or . == "Bash(gitch pr status:*)")] | length' "$s")" = 0 ] || fail "겹치는 예전 항목이 남음"
  run gitch doctor --no-net; assert_out "Claude push 정책: 작업 브랜치는 자동"
}

test_guard_graph_out_and_allowlist() {
  mk_config
  expect none 'gitch overlap --json'
  expect none 'gitch overlap --watch --interval 2 --fail-on-overlap'
  expect deny 'gitch overlap --json > ~/.ssh/config'
  expect none 'gitch graph files --json'
  expect none 'gitch graph --out /tmp/g.html'
  expect deny 'gitch graph --out ~/.ssh/config'
  expect deny 'gitch graph tree -o ~/.gitconfig'
  expect deny 'gitch graph --out=~/.config/gitsw/config'
  expect deny 'gitch graph diff main --out ~/.ssh/config'
  expect deny 'gitch graph check --init --rules ~/.gitconfig'
  expect none 'gitch graph check --rules ~/.gitconfig'          # 읽기만 한다
  expect none 'gitch graph check --init'
  expect none 'gitch g my-app'                                  # g 는 graph 의 짧은 이름 — 같은 검사
  expect deny 'gitch g --out ~/.ssh/config'
  expect deny 'gitch g check --init --rules ~/.gitconfig'
  install_quiet
  jq -e '.permissions.allow | index("Bash(gitch overlap:*)")' "$HOME/.claude/settings.json" >/dev/null || fail "gitch overlap 가 읽기 명령 허용 목록에 없음"
  jq -e '.permissions.allow | index("Bash(gitch graph:*)")' "$HOME/.claude/settings.json" >/dev/null || fail "gitch graph 가 읽기 명령 허용 목록에 없음"
}

test_guard_move_plan_and_module_read_contract() {
  mk_config
  expect none 'gitch move src/a.ts src/b.ts --plan --json'
  expect none 'gitch move --plan -- src/a.ts src/b.ts'
  expect none 'gitch move --help'
  expect deny 'gitch move src/a.ts src/b.ts'
  expect deny 'gitch move -- src/a.ts --plan'
  expect deny 'gitch move src/a.ts src/b.ts --plan --apply'
  expect deny 'gitch move src/a.ts src/b.ts --apply=true --plan'
  expect deny 'gitch move src/a.ts src/b.ts --plan > ~/.ssh/config'
  expect none 'gitch module audit --json'
  expect none 'gitch module audit packages/api --strict'
  expect none 'gitch module --help'
  expect deny 'gitch module remove api'
  expect deny 'gitch module apply'
  expect deny 'gitch module audit --json > ~/.gitconfig'
  install_quiet
  jq -e '.permissions.allow | index("Bash(gitch move:*)")' "$HOME/.claude/settings.json" >/dev/null || fail "move 계획 허용 목록 누락"
  jq -e '.permissions.allow | index("Bash(gitch module audit:*)")' "$HOME/.claude/settings.json" >/dev/null || fail "module audit 허용 목록 누락"
  jq -e '.permissions.allow | index("Bash(gitch module:*)") == null' "$HOME/.claude/settings.json" >/dev/null || fail "임의 module 하위 명령을 허용함"
}
