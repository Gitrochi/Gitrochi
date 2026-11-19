# shellcheck shell=bash disable=SC2088  # 화면 표시용 ~ 문자열
# 전역 검사 훅: 작성자 / 비밀값 / 큰 파일 / AI 표기 / push 검사 / 보조 훅

hook_repo() {   # alice 잠금 저장소 + 원격 → cd
  mk_config; install_quiet
  mk_remote_seeded github-alice alice/hk alice@example.com
  gitch clone alice alice/hk "$HOME/Develop/alice/hk" >/dev/null 2>&1 || fail "clone 실패"
  cd "$HOME/Develop/alice/hk" || fail cd
}

test_hook_warns_once_when_gitch_is_missing() {
  hook_repo
  rm "$HOME/bin/gitch"   # 앱을 지웠거나 디스크 이미지를 꺼낸 것처럼
  echo a > a; git add a
  run git commit -q -m a; assert_ok "gitch 가 없어도 커밋은 된다"
  assert_out "[gitch] ~/bin/gitch 를 찾을 수 없어 검사를 건너뜁니다"
  [ "$(printf '%s\n' "$OUT" | grep -c '검사를 건너뜁니다')" -eq 1 ] || fail "커밋 한 번에 알림은 한 줄\n$OUT"
  run git push -q origin HEAD; assert_ok "gitch 가 없어도 push 는 된다"
  [ "$(printf '%s\n' "$OUT" | grep -c '검사를 건너뜁니다')" -eq 1 ] || fail "push 한 번에 알림은 한 줄\n$OUT"
}

test_hook_rewrites_old_dispatcher() {
  hook_repo
  local d="$HOME/.local/share/gitch/hook"
  [ -f "$d" ] || fail "훅 연결 스크립트가 없음"
  # 예전 gitch 가 쓴 연결 스크립트 (gitch 가 없으면 말없이 넘어감)
  printf '#!/bin/sh\ng="%s"\n[ -x "$g" ] || exit 0\nexec "$g" _hook "$@"\n' "$HOME/bin/gitch" > "$d"
  echo a > a; git add a
  run git commit -q -m a; assert_ok
  grep -q '검사를 건너뜁니다' "$d" || fail "훅이 돈 뒤에는 새 연결 스크립트여야 함\n$(cat "$d")"
  [ -x "$d" ] || fail "새 연결 스크립트에 실행 권한이 없음"
}

test_hook_blocks_wrong_identity() {
  hook_repo
  git config user.email bob@example.com
  echo a > a; git add a
  run git commit -q -m a; assert_fail; assert_out "이 저장소는 alice 계정 전용입니다"; assert_out "gitch use alice"
  git config user.email alice@example.com
  run env GIT_AUTHOR_EMAIL=bob@example.com git commit -q -m a; assert_fail "환경변수로 작성자를 바꿔도 막혀야 함"
  run git commit -q -m a --author="Bob <bob@example.com>"; assert_fail "--author 로 바꿔도 막혀야 함"
  run git commit -q -m a; assert_ok
}

test_hook_blocks_secrets() {
  hook_repo
  printf 'API=1\n' > .env; git add .env
  run git commit -q -m env; assert_fail; assert_out ".env 파일"
  git rm -q --cached .env
  printf 'API=example\n' > .env.example; git add .env.example
  run git commit -q -m example; assert_ok ".env.example 은 통과"
  printf 'token = "ghp_%s"\n' "abcdefghijklmnopqrstuvwxyz0123456789" > conf.py; git add conf.py
  run git commit -q -m tok; assert_fail; assert_out "GitHub 토큰"; assert_no_out "abcdefghijklmnopqrstuvwxyz0123456789" "비밀값 원문을 출력하면 안 됨"
  printf 'token = "glpat-%s"\n' "AbCdEfGhIjKlMnOpQrSt12" > conf.py; git add conf.py
  run git commit -q -m tok; assert_fail; assert_out "GitLab 토큰"; assert_out "conf.py:1"
  # 개인키 머리줄은 나눠 적는다(이 파일이 Gitrochi 저장소의 비밀값 검사에 걸리지 않게 — 만든 파일 내용은 같다)
  printf '%s%s\n' '-----BEGIN OPENSSH PRIVATE' ' KEY-----' > key.txt; git add key.txt; git reset -q conf.py
  run git commit -q -m key; assert_fail; assert_out "개인키"
  printf '%s%s  # gitch:allow\n' '-----BEGIN OPENSSH PRIVATE' ' KEY-----' > key.txt; git add key.txt
  run git commit -q -m key-allowed; assert_ok "gitch:allow 줄은 통과"
}

test_hook_lockfiles_and_false_positives() {
  hook_repo
  printf '"integrity": "sha512-xsk-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"\n' > package-lock.json
  printf 'desk-ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890 notask-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n' > notes.txt
  git add package-lock.json notes.txt
  run git commit -q -m ok; assert_ok "잠금 파일/단어 중간의 sk- 는 통과"
  printf 'key = "sk-ant-%s"\n' "api03-ABCDEFGHIJKLMNOPQRSTUVWX" > ai.py; git add ai.py
  run git commit -q -m ai; assert_fail; assert_out "Anthropic 키"
  run env GITCH_SKIP=secrets git commit -q -m ai; assert_ok "사람이 GITCH_SKIP 으로 넘길 수 있음"
}

test_hook_blocks_big_files() {
  hook_repo
  gitch config set gitch.maxFileMB 1 --yes >/dev/null
  gitch config set gitch.warnFileMB 0 --yes >/dev/null
  dd if=/dev/zero of=big.bin bs=1048576 count=2 2>/dev/null; git add big.bin
  run git commit -q -m big; assert_fail; assert_out "1MB 이상 파일"; assert_out "big.bin"
  git rm -q --cached big.bin
  dd if=/dev/zero of=small.bin bs=1024 count=10 2>/dev/null; git add small.bin
  run git commit -q -m small; assert_ok
}

test_hook_strips_ai_trailer_by_policy() {
  hook_repo
  gitch config set account.alice.aiTrailer strip --yes >/dev/null
  echo a > a; git add a
  run git commit -q -m "feat: a" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" -m "Reviewed-by: Human <h@x>"; assert_ok
  assert_out "AI 표기 줄을 뺐습니다"
  git log -1 --format=%B | grep -qi claude && fail "AI 표기가 남아 있음"
  git log -1 --format=%B | grep -q "Reviewed-by: Human" || fail "다른 트레일러는 남아야 함"
  run gitch ai --print; assert_out "alice 계정 저장소의 커밋 메시지에는 AI 표기"
}

test_hook_unmanaged_repo_passes() {
  mk_config; install_quiet
  mk_repo "$T/local" "$T/somewhere.git"
  cd "$T/local" && git config user.name me && git config user.email me@other.example
  echo a > a; git add a
  run git commit -q -m a; assert_ok "관리 밖(로컬 경로 원격) 저장소는 통과"
}

test_hook_blocks_unassigned_managed_repo() {
  mk_config; install_quiet
  mk_repo "$T/foreign" "https://github.com/stranger/x.git"
  cd "$T/foreign" && git config user.name a && git config user.email alice@example.com
  echo a > a; git add a
  run git commit -q -m a; assert_fail; assert_out "어느 계정으로 커밋할지 정해지지 않았습니다"
}

test_push_blocks_force_but_gitch_force_works() {
  hook_repo
  echo a > a; gitch cp -a -m a >/dev/null 2>&1 || fail "첫 push 실패"
  git commit -q --amend -m "a rewritten"
  run git push -q -f origin main; assert_fail; assert_out "강제 push"
  run gitch p --force; assert_rc 2 "확인 필요"
  run gitch p --force --yes; assert_ok
  assert_eq "$(git -C "$FAKE_REMOTES/github-alice/alice/hk.git" log -1 --format=%s main)" "a rewritten"
}

test_push_blocks_wrong_alias_and_raw_url() {
  hook_repo
  echo a > a; gitch c -a -m a >/dev/null
  mk_remote github-bob alice/hk
  git config remote.origin.url git@github-bob:alice/hk.git
  run git push -q origin main; assert_fail; assert_out "alice 계정 전용"
  mk_remote github.com stranger/hk   # 별칭 없는 github.com 으로도 접속은 되는 상황 (기본 키)
  git config remote.origin.url git@github.com:stranger/hk.git
  run git push -q origin main; assert_fail; assert_out "별칭 없는 주소"
}

test_push_blocks_other_account_commits_allows_colleague() {
  hook_repo
  echo a > a; git add a
  GITCH_SKIP=identity git -c user.email=bob@example.com -c user.name=bob commit -q -m "by bob"
  run git push -q origin main; assert_fail; assert_out "작성자가 alice"
  run gitch fix --yes; assert_ok
  assert_eq "$(git log -1 --format=%ae)" "alice@example.com"
  echo c > c; git add c
  git commit -q -m "colleague patch" --author="Colleague <colleague@corp.example>" 2>/dev/null || \
    GITCH_SKIP=identity git commit -q -m "colleague patch" --author="Colleague <colleague@corp.example>"
  run git push -q origin main; assert_ok "동료 작성 + 내 커밋터는 통과"
}

test_push_protected_and_delete_default() {
  hook_repo
  echo a > a; gitch cp -a -m a >/dev/null 2>&1
  gitch protect main >/dev/null
  echo b > b; gitch c -a -m b >/dev/null
  run git push -q origin main; assert_fail; assert_out "보호된 브랜치"
  gitch protect --rm main >/dev/null
  run git push -q origin :main; assert_fail; assert_out "기본/보호 브랜치 삭제"
  git push -q origin main:tmp 2>/dev/null
  run git push -q origin :tmp; assert_ok "다른 브랜치 삭제는 통과"
}

test_push_allow_remote_policy() {
  mk_config
  git config -f "$HOME/.config/gitch/config" --add folder.~/Develop/corp.allowRemote "gitlab.example.com/*"
  install_quiet
  mk_remote_seeded gitlab-carol grp/app carol@corp.example
  gitch clone carol grp/app "$HOME/Develop/corp/app" >/dev/null 2>&1 || fail clone
  cd "$HOME/Develop/corp/app" && echo a > a && gitch c -a -m a >/dev/null
  run gitch p; assert_ok "허용된 곳은 통과"
  mk_remote github-alice alice/leak
  git remote add leak git@github-alice:alice/leak.git
  run git push -q leak main; assert_fail; assert_out "push 할 수 없습니다"
}

test_fallback_hooks_when_no_config_hooks() {
  hook_repo
  git config user.email bob@example.com
  echo a > a; git add a
  run git commit -q -m a; assert_fail
  [ "$(printf '%s\n' "$OUT" | grep -c '이 저장소는 alice 계정 전용')" -eq 1 ] || fail "전역 훅 + 보조 훅이 중복 검사함\n$OUT"
  # 전역 훅을 모르는 git 흉내: 전역 훅 설정을 지우면 저장소 보조 훅이 검사
  for ev in pre-commit commit-msg pre-push post-commit; do git config --global --remove-section "hook.gitch-$ev"; done
  run git commit -q -m a; assert_fail "보조 훅이 막아야 함"; assert_out "이 저장소는 alice 계정 전용"
}

test_post_commit_log_and_report() {
  hook_repo
  echo a > a; gitch c -a -m "logged" >/dev/null
  [ -f "$HOME/.local/state/gitch/actions.jsonl" ] || fail "기록 파일 없음"
  run gitch report --json; assert_ok; assert_json "$OUT"
  assert_eq "$(printf '%s' "$OUT" | jq -r '[.[] | select(.event == "commit" and .subject == "logged")] | length')" "1"
  run gitch report; assert_ok; assert_out "logged"; assert_out "script"
}

test_hook_config_error_fails_open() {
  hook_repo
  printf '[account "broken"]\n\thost = github.com\n' >> "$HOME/.config/gitch/config"
  echo a > a; git add a
  run git commit -q -m a; assert_ok "설정이 깨지면 커밋은 막지 않고 경고"
  assert_out "설정 파일에 문제가 있어 검사를 건너뜁니다"
}

test_hook_uses_gitleaks_when_installed() {
  hook_repo
  cat > "$T/fakebin/gitleaks" <<'G'
#!/bin/sh
# 가짜 gitleaks: 스테이지에 LEAKME 가 있으면 발견(종료코드 = --exit-code 값)
code=1; prev=""
for a in "$@"; do [ "$prev" = "--exit-code" ] && code=$a; prev=$a; done
if git diff --cached | grep -q LEAKME; then
  printf 'Finding:     LEAKME\nRuleID:      fake-rule\nFile:        x.txt\nLine:        1\n'
  exit "$code"
fi
exit 0
G
  chmod +x "$T/fakebin/gitleaks"
  echo "nothing here" > x.txt; git add x.txt
  run git commit -q -m ok; assert_ok "gitleaks 가 아무것도 못 찾으면 통과"
  echo "LEAKME" > x.txt; git add x.txt
  run git commit -q -m leak; assert_fail; assert_out "gitleaks RuleID:"; assert_out "fake-rule"
}
