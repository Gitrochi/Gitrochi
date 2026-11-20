# gitch 테스트 도우미 — 테스트마다 HOME 을 임시 폴더로 바꿔서 실제 설정을 건드리지 않는다.
# shellcheck shell=bash disable=SC2034

# Windows(Git Bash): gitch 처럼 ~/bin/gitch 는 연결 스크립트, 터미널 연동은 ~/.bashrc
case "${OSTYPE:-}" in msys*|cygwin*) IS_WIN=1 ;; *) IS_WIN="" ;; esac
mac_only() { [ -z "$IS_WIN" ]; }       # 맥·리눅스에서만 볼 것: if mac_only; then … fi
mklink_() {   # $1 대상 $2 링크 — gitch install 이 만드는 것과 같은 모양
  if [ -z "$IS_WIN" ]; then ln -sfn "$1" "$2"; return; fi
  printf '#!/bin/sh\n# gitch-link: %s\nexec "%s" "$@"\n' "$1" "$1" > "$2" && chmod +x "$2"
}
link_of() {   # $1 이 심볼릭 링크나 연결 스크립트면 가리키는 경로를 출력
  if [ -L "$1" ]; then readlink "$1"; return 0; fi
  [ -n "$IS_WIN" ] && [ -f "$1" ] && [ "$(head -1 "$1")" = "#!/bin/sh" ] || return 1
  sed -n '2s/^# gitch-link: //p' "$1" | grep .
}
is_linkish() { link_of "$1" >/dev/null; }

t_setup() {
  T=$(mktemp -d "$TMP_BASE/gitch-t.XXXXXX") || return 1
  T=$(cd "$T" && pwd -P)
  trap 'cd /; rm -rf "$T"' EXIT
  export HOME="$T/home"
  mkdir -p "$HOME/bin" "$HOME/.ssh" "$HOME/.claude" "$HOME/.codex" "$HOME/Develop"
  export GIT_CONFIG_NOSYSTEM=1
  unset GIT_CONFIG_GLOBAL XDG_CONFIG_HOME XDG_STATE_HOME XDG_DATA_HOME GITCH_CONFIG GITCH_SKIP GITCH_ALLOW_FORCE ZDOTDIR
  unset CLAUDECODE AI_AGENT CODEX_SANDBOX CODEX_SANDBOX_NETWORK_DISABLED CODEX_THREAD_ID CODEX_CI CURSOR_AGENT CURSOR_TRACE_ID GEMINI_CLI
  unset GIT_SSH GIT_SSH_COMMAND GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_EDITOR
  export GITCH_ACTOR=script GITCH_COLOR=never GITCH_FETCH_TTL=0
  export FAKE_REMOTES="$T/remotes" FAKE_SSH_USERS="$T/sshusers" FAKE_GH="$T/gh" FAKE_WEB="$T/web"
  mkdir -p "$FAKE_REMOTES" "$FAKE_SSH_USERS" "$FAKE_GH/tokens" "$FAKE_WEB" "$T/fakebin"
  make_fakes
  export PATH="$HOME/bin:$T/fakebin:$ORIG_PATH"
  # Windows: 사용자 PATH(레지스트리)는 가짜 PowerShell 로 — 실제 PATH 를 건드리지 않는다
  export GITCH_POWERSHELL="$T/fakebin/powershell"
  if [ -n "$IS_WIN" ]; then RC_FILE="$HOME/.bashrc"; else RC_FILE="$HOME/.zshrc"; fi
  mklink_ "$GITCH_SRC" "$HOME/bin/gitch"
  git config --global init.defaultBranch main
  git config --global advice.detachedHead false
  git config --global advice.skippedCherryPicks false
  cd "$T" || return 1
}

make_fakes() {
  cat > "$T/fakebin/ssh" <<'EOF'
#!/bin/bash
# 가짜 ssh: git@<별칭> → $FAKE_REMOTES/<별칭>/ 아래 로컬 bare 저장소
while [ $# -gt 0 ]; do
  case "$1" in
    -o|-p|-i|-F|-l|-E|-S|-O|-b|-c|-D|-e|-I|-J|-L|-m|-Q|-R|-W|-w|-B) shift 2 ;;
    -[46AaCfGgKkMNnqsTtVvXxYy]*) shift ;;
    --) shift; break ;;
    *) break ;;
  esac
done
host="$1"; shift
alias="${host#*@}"
if [ $# -eq 0 ]; then
  u=$(cat "$FAKE_SSH_USERS/$alias" 2>/dev/null)
  if [ -n "$u" ]; then echo "Hi $u! You've successfully authenticated, but GitHub does not provide shell access." >&2; exit 1; fi
  echo "git@$alias: Permission denied (publickey)." >&2; exit 255
fi
[ -d "$FAKE_REMOTES/$alias" ] || { echo "ssh: Could not resolve hostname $alias: nodename nor servname provided" >&2; exit 255; }
echo "$alias $*" >> "$FAKE_REMOTES/.log"
cd "$FAKE_REMOTES/$alias" || exit 255
eval "exec $*"
EOF
  cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
# 가짜 gh: 호출 기록 + 간단한 응답
echo "GH_TOKEN=${GH_TOKEN:-} $*" >> "$FAKE_GH/log"
case "$1 $2" in
  "auth token")
    u=""; while [ $# -gt 0 ]; do case "$1" in -u|--user) u="$2"; shift ;; esac; shift; done
    if [ -f "$FAKE_GH/tokens/$u" ]; then cat "$FAKE_GH/tokens/$u"; exit 0; fi
    echo "no oauth token found for github.com account $u" >&2; exit 1 ;;
  "pr create") r=""; while [ $# -gt 0 ]; do case "$1" in -R) r="$2"; shift ;; esac; shift; done; echo "https://github.com/$r/pull/7"; exit 0 ;;
  "pr view") if [ -f "$FAKE_GH/pr_view.json" ]; then cat "$FAKE_GH/pr_view.json"; exit 0; fi; echo "no pull requests found" >&2; exit 1 ;;
  "pr checks") printf 'build\tpass\t1m\thttps://example/1\n'; exit 0 ;;
  "run list") printf 'completed\tsuccess\tci\tmain\n'; exit 0 ;;
  "repo fork") exit 0 ;;
  "repo view") o=${3%%/*}; [ -d "$FAKE_REMOTES/github-$o/$3.git" ] && exit 0; echo "Could not resolve to a Repository" >&2; exit 1 ;;
  "repo create")
    r="$3"; o=${r%%/*}
    mkdir -p "$FAKE_REMOTES/github-$o/$o" && git init -q --bare "$FAKE_REMOTES/github-$o/$r.git"
    echo "https://github.com/$r"; exit 0 ;;
  "api user/emails")
    if [ -f "$FAKE_GH/emails_error" ]; then echo '{"message":"Not Found","status":"404"}'; echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
    cat "$FAKE_GH/emails" 2>/dev/null; exit 0 ;;
  "--version ") echo "gh version 9.9.9 (fake)"; exit 0 ;;
esac
exit 0
EOF
  cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
# 가짜 curl: https://<호스트>/<경로>(? 뒤는 무시) → $FAKE_WEB/<호스트>/<경로> 파일, 없으면 404 (-f 처럼 종료코드 22)
out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o|--output) out="$2"; shift ;;
    -H|--header|-A|--user-agent|-m|--max-time|--connect-timeout|--retry|-w|--write-out) shift ;;
    -*) ;;
    *) url="$1" ;;
  esac
  shift
done
echo "$url" >> "$FAKE_WEB/log"
f="$FAKE_WEB/${url#https://}"; f="${f%%\?*}"
[ -f "$f" ] || { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
if [ -n "$out" ]; then cp "$f" "$out"; else cat "$f"; fi
EOF
  printf '#!/bin/sh\necho "open $*" >> "%s/opened"\n' "$T" > "$T/fakebin/open"
  printf '#!/bin/sh\ncat > /dev/null\n' > "$T/fakebin/pbcopy"
  # Windows 의 브라우저(url.dll)·클립보드·PowerShell(사용자 PATH: $T/userpath 에 한 줄씩)
  printf '#!/bin/sh\nshift; echo "open $*" >> "%s/opened"\n' "$T" > "$T/fakebin/rundll32"
  printf '#!/bin/sh\ncat > /dev/null\n' > "$T/fakebin/clip"
  cat > "$T/fakebin/powershell" <<EOF
#!/bin/bash
f="$T/userpath"; touch "\$f"
has() { grep -qixF -- "\$GITCH_PATH_DIR" "\$f"; }
case "\$GITCH_PATH_OP" in
  has) if has; then echo yes; else echo no; fi ;;
  add) if has; then echo same; else echo "\$GITCH_PATH_DIR" >> "\$f"; echo added; fi ;;
  remove) if has; then grep -vixF -- "\$GITCH_PATH_DIR" "\$f" > "\$f.n"; mv "\$f.n" "\$f"; echo removed; fi ;;
esac
EOF
  chmod +x "$T/fakebin/"*
}

# 테스트 계정: alice(github), bob(github), carol(gitlab.example.com:2222) / 폴더 / 조직 teamb → bob
mk_config() {
  mkdir -p "$HOME/.config/gitch" "$HOME/Develop/alice" "$HOME/Develop/bob" "$HOME/Develop/corp"
  cat > "$HOME/.config/gitch/config" <<'EOF'
[gitch]
	scanRoot = ~/Develop
[account "alice"]
	email = alice@example.com
	host = github.com
[account "bob"]
	email = bob@example.com
	host = github.com
[account "carol"]
	email = carol@corp.example
	host = gitlab.example.com:2222
[folder "~/Develop/alice"]
	account = alice
[folder "~/Develop/bob"]
	account = bob
[folder "~/Develop/corp"]
	account = carol
[org "github.com/teamb"]
	account = bob
EOF
  local a
  for a in alice bob; do echo "$a" > "$FAKE_SSH_USERS/github-$a"; done
  echo carol > "$FAKE_SSH_USERS/gitlab-carol"
  for a in alice bob carol; do : > "$HOME/.ssh/id_ed25519_$a"; echo "ssh-ed25519 AAAA $a" > "$HOME/.ssh/id_ed25519_$a.pub"; done
  {
    printf 'Host github-alice\n    HostName github.com\n    IdentityFile %s/.ssh/id_ed25519_alice\n\n' "$HOME"
    printf 'Host github-bob\n    HostName github.com\n    IdentityFile %s/.ssh/id_ed25519_bob\n\n' "$HOME"
    printf 'Host gitlab-carol\n    HostName gitlab.example.com\n    Port 2222\n    IdentityFile %s/.ssh/id_ed25519_carol\n' "$HOME"
  } > "$HOME/.ssh/config"
}

resolve_path() {   # 심볼릭 링크(Windows 는 연결 스크립트도)를 끝까지 따라간 실제 경로
  local p="$1" t
  while t=$(link_of "$p"); do case "$t" in /*) p="$t" ;; *) p="$(dirname "$p")/$t" ;; esac; done

  printf '%s' "$(cd "$(dirname "$p")" && pwd -P)/$(basename "$p")"
}

install_quiet() { gitch install >/dev/null 2>&1 || { gitch install; fail "gitch install 실패"; }; }

mk_remote() {   # $1 별칭 $2 owner/repo — 빈 bare 저장소
  mkdir -p "$FAKE_REMOTES/$1/$(dirname "$2")"
  git init -q --bare "$FAKE_REMOTES/$1/$2.git"
}

mk_remote_seeded() {   # $1 별칭 $2 owner/repo $3 작성자 이메일 — 커밋 하나 있는 원격
  local tmp="$T/seed-$$-$RANDOM"
  mk_remote "$1" "$2"
  git init -q "$tmp"
  git -C "$tmp" -c user.name=seed -c user.email="${3:-seed@example.com}" commit -q --allow-empty -m "init"
  git -C "$tmp" push -q "$FAKE_REMOTES/$1/$2.git" main 2>/dev/null
  rm -rf "$tmp"
}

mk_repo() {   # $1 폴더 $2 origin 주소(선택) — 빈 저장소
  mkdir -p "$1"
  git init -q "$1"
  [ -n "$2" ] && git -C "$1" remote add origin "$2"
  return 0
}

seed_commit() {   # $1 저장소 — 커밋 하나 (훅 없이, 현재 작성자)
  echo "seed $RANDOM" >> "$1/seed.txt"
  git -C "$1" add seed.txt
  GITCH_SKIP=all git -C "$1" commit -q -m "seed"
}

run() { OUT=$("$@" 2>&1); RC=$?; }
count_dirs() { local n=0 d; for d in "$@"; do [ -d "$d" ] && n=$((n+1)); done; echo "$n"; }   # 인자 중 폴더 수 (glob 이 안 맞으면 0)

fail() { printf 'FAIL: %b\n' "$*"; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "${3:-값이 다름}: 기대 [$2] 실제 [$1]"; }
assert_rc() { [ "$RC" -eq "$1" ] || fail "${2:-종료코드} 기대 $1 실제 $RC\n--- 출력:\n$OUT"; }
assert_ok() { [ "$RC" -eq 0 ] || fail "${1:-실패} (종료코드 $RC)\n--- 출력:\n$OUT"; }
assert_fail() { [ "$RC" -ne 0 ] || fail "${1:-실패해야 하는데 성공}\n--- 출력:\n$OUT"; }
assert_out() { case "$OUT" in *"$1"*) ;; *) fail "${2:-출력에 없음}: [$1]\n--- 출력:\n$OUT" ;; esac; }
assert_no_out() { case "$OUT" in *"$1"*) fail "${2:-출력에 있으면 안 됨}: [$1]\n--- 출력:\n$OUT" ;; esac; }
assert_json() { printf '%s' "$1" | jq -e . >/dev/null 2>&1 || fail "${2:-JSON 이 아님}\n--- 내용:\n$1"; }
