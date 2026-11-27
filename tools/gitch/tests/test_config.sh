# shellcheck shell=bash
# 설정 파일 / 계정 해석 / v1 옮기기

test_config_check_and_list() {
  mk_config
  run gitch config check; assert_ok; assert_out "계정 3개"
  run gitch list --json; assert_ok; assert_json "$OUT"
  assert_eq "$(printf '%s' "$OUT" | jq -r '.accounts[].id' | tr -d '\r' | tr '\n' ' ')" "alice bob carol "
  assert_eq "$(printf '%s' "$OUT" | jq -r '.accounts[2].hosts')" "gitlab.example.com(포트 2222)"
}

test_config_errors_reported() {
  mkdir -p "$HOME/.config/gitch"
  cat > "$HOME/.config/gitch/config" <<'EOF'
[account "alice"]
	host = github.com
[account "bad name"]
	email = x@y
	host = github.com
[account "dave"]
	email = d@x
	host = github.com via nobody
[org "github.com/zzz"]
	account = ghost
[gitch]
	aiPush = sometimes
EOF
  run gitch config check; assert_fail
  assert_out "account.alice.email 이 없습니다"
  assert_out "'bad name'"
  assert_out "via nobody"
  assert_out "없는 계정 'ghost'"
  assert_out "aiPush"
  run gitch status; assert_ok "설정이 틀려도 status 는 동작"
  run gitch scan; assert_fail; assert_out "설정 파일에 문제가 있습니다"
}

test_config_set_validates_and_rolls_back() {
  mk_config
  run gitch config set account.alice.aiTrailer bogus --yes; assert_fail; assert_out "되돌렸습니다"
  run gitch config get account.alice.aiTrailer; assert_eq "$OUT" ""
  run gitch config set account.alice.aiTrailer strip --yes; assert_ok
  run gitch config get account.alice.aitrailer; assert_eq "$OUT" "strip"
  run gitch config set gitch.aiPush allow; assert_rc 2 "--yes 없으면 확인 필요(2)"
}

tty_gitch() {   # 표준입력의 답을 터미널(pty)로 넣어 gitch 를 돌린다 — gitch add 처럼 사람에게만 묻는 명령.
  # 맥의 script 는 파이프로 받은 입력 앞에 EOF(^D)를 먼저 보내 첫 질문이 빈 답을 받아서 python 의 pty 로 연다
  python3 -I -c '
import os, pty, sys
answers = sys.stdin.buffer.read()
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[1], sys.argv[1:])
os.write(fd, answers)
out = b""
while True:
    try:
        b = os.read(fd, 4096)
    except OSError:
        break
    if not b:
        break
    out += b
sys.stdout.buffer.write(out)
_, st = os.waitpid(pid, 0)
sys.exit(os.WEXITSTATUS(st) if os.WIFEXITED(st) else 1)
' gitch "$@"
}

test_add_new_account_writes_email_and_host_together() {
  mac_only || return 0                                    # Windows 의 python 에는 pty 가 없다
  command -v python3 >/dev/null 2>&1 || return 0
  # 설정 파일이 없는 처음 쓰는 사람. 예전에는 이메일만 쓴 직후 검사가 「host 가 없다」로 되돌리고 멈춰 새 계정을 만들 수 없었다
  echo dave > "$FAKE_SSH_USERS/github-dave"               # SSH 연결 확인이 바로 통과해 키 등록 단계는 건너뛴다
  printf 'dave\ndave@example.com\n\n\n\n\n\n\n' > "$T/answers"   # 아이디 · 이메일 · 서버(github.com) · 빌려 쓰기(아니오) · 기본 폴더 · SSH 키 암호(아니오)
  run tty_gitch add < "$T/answers"
  assert_ok "gitch add"; assert_no_out "되돌렸습니다"; assert_out "dave 를 계정 목록에 추가했습니다"
  assert_eq "$(git config -f "$HOME/.config/gitch/config" --get account.dave.email)" "dave@example.com"
  assert_eq "$(git config -f "$HOME/.config/gitch/config" --get account.dave.host)" "github.com"
  assert_eq "$(git config -f "$HOME/.config/gitch/config" --get 'folder.~/Develop/dave.account')" "dave"
  [ -d "$HOME/Develop/dave" ] || fail "기본 폴더를 만들지 않음"
  run gitch config check; assert_ok; assert_out "계정 1개"
  # 있는 설정에 하나 더(기본 폴더 없이)
  mk_config
  echo erin > "$FAKE_SSH_USERS/github-erin"
  printf 'erin\nerin@example.com\n\n\n-\n\n\n\n' > "$T/answers"
  run tty_gitch add < "$T/answers"
  assert_ok "두 번째 gitch add"; assert_out "erin 를 계정 목록에 추가했습니다"
  run gitch config check; assert_ok; assert_out "계정 4개"
}

test_via_binding_uses_login_alias() {
  mk_config
  git config -f "$HOME/.config/gitch/config" account.dave.email dave@corp.example
  git config -f "$HOME/.config/gitch/config" --add account.dave.host "github.com via alice"
  git config -f "$HOME/.config/gitch/config" org.github.com/daveorg.account dave
  run gitch config check; assert_ok
  run gitch list; assert_out "github.com(로그인 alice)"
  mk_remote_seeded github-alice daveorg/app
  run gitch clone https://github.com/daveorg/app "$T/app"; assert_ok
  assert_eq "$(git -C "$T/app" config user.email)" "dave@corp.example"
  assert_eq "$(git -C "$T/app" config remote.origin.url)" "git@github-alice:daveorg/app.git"
  assert_eq "$(git -C "$T/app" config gitch.alias)" "github-alice"
  cd "$T/app" && run gitch status; assert_out "PUSH_ACCOUNT=dave"; assert_out "PUSH_LOGIN=alice"
}

test_resolve_rules_order() {
  mk_config
  install_quiet
  # 조직 규칙(teamb→bob)이 폴더 기본(alice)보다 우선
  mk_repo "$HOME/Develop/alice/x" "git@github-bob:teamb/x.git"
  cd "$HOME/Develop/alice/x" && run gitch status --json; assert_json "$OUT"
  assert_eq "$(printf '%s' "$OUT" | jq -r .derivedAccount)" "bob"
  # 소유자 = 내 계정
  mk_repo "$HOME/Develop/bob/y" "https://github.com/alice/y.git"
  cd "$HOME/Develop/bob/y" && run gitch status --json
  assert_eq "$(printf '%s' "$OUT" | jq -r .derivedAccount)" "alice"
  # 회사 GitLab: 서버에 계정이 하나뿐
  mk_repo "$T/z" "https://gitlab.example.com/grp/sub/z.git"
  cd "$T/z" && run gitch status --json
  assert_eq "$(printf '%s' "$OUT" | jq -r .derivedAccount)" "carol"
  # 원격 없음 + 폴더
  mk_repo "$HOME/Develop/corp/norem"
  cd "$HOME/Develop/corp/norem" && run gitch status --json
  assert_eq "$(printf '%s' "$OUT" | jq -r .derivedAccount)" "carol"
}

test_config_server_alias_reads_another_name_as_the_server() {
  mk_config
  printf '10.0.0.7 gitlab.example.com\n10.0.0.7 code.example.org\n10.0.0.9 other.example.net\n' > "$HOME/hosts"
  export GITCH_HOSTS="$HOME/hosts"
  mk_repo "$HOME/Develop/corp/app" https://code.example.org/grp/app.git
  cd "$HOME/Develop/corp/app" || return 1
  run gitch use carol; assert_fail
  assert_out "carol 계정에는 code.example.org 서버가 없습니다"
  assert_out "gitch config add server.gitlab.example.com.alias code.example.org"
  git remote set-url origin https://other.example.net/grp/app.git
  run gitch use carol; assert_fail
  assert_no_out "server.gitlab.example.com.alias" "a different address gets no suggestion"
  git remote set-url origin https://code.example.org/grp/app.git
  run gitch config add server.gitlab.example.com.alias code.example.org --yes; assert_ok
  run gitch use carol; assert_ok
  assert_eq "$(git remote get-url origin)" "git@gitlab-carol:grp/app.git"
  run gitch config add server.nowhere.example.alias code2.example.org --yes; assert_fail; assert_out "되돌렸습니다"
  run gitch config check; assert_ok
  unset GITCH_HOSTS
}
