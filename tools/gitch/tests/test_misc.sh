# shellcheck shell=bash disable=SC2088  # 화면 표시용 ~ 문자열
# 상태 출력 / scan / doctor / install / AI 연동 / PR / 기타

misc_repo() {
  mk_config; install_quiet
  mk_remote_seeded github-alice alice/m alice@example.com
  gitch clone alice alice/m "$HOME/Develop/alice/m" >/dev/null 2>&1 || fail clone
  cd "$HOME/Develop/alice/m" || fail cd
}

test_json_outputs_valid_and_no_colors() {
  misc_repo
  echo x > x
  run gitch status --json; assert_ok; assert_json "$OUT"
  assert_eq "$(printf '%s' "$OUT" | jq -r .pushAccount)" "alice"
  run gitch ck --json; assert_ok; assert_json "$OUT"
  assert_eq "$(printf '%s' "$OUT" | jq -r '.untracked[0]')" "x"
  run gitch preflight --json; assert_ok; assert_json "$OUT"
  assert_eq "$(printf '%s' "$OUT" | jq -r .result)" "OK"
  run gitch scan --json; assert_json "$OUT"
  run gitch doctor --json --no-net; assert_json "$OUT"
  run gitch list --json; assert_json "$OUT"
  GITSW_COLOR=auto run gitch status
  case "$OUT" in *$'\033['*) fail "파이프 출력에 색상 코드가 있음" ;; esac
}

test_preflight_detects_problems() {
  misc_repo
  git config user.email bob@example.com
  run gitch preflight; assert_rc 1; assert_out "PREFLIGHT=STOP"; assert_out "gitch use alice"
  git config user.email alice@example.com
  git config remote.origin.url git@github-bob:alice/m.git
  run gitch preflight --no-fetch; assert_rc 1; assert_out "push 주소"
  git config remote.origin.url git@github-alice:alice/m.git
  run gitch preflight --no-fetch; assert_ok; assert_out "PREFLIGHT=OK"
  run gitch status --strict; assert_ok
}

test_status_warns_rule_mismatch() {
  mk_config; install_quiet
  mk_remote_seeded github-alice teamb/x
  gitch clone alice https://github.com/teamb/x "$HOME/Develop/alice/x" >/dev/null 2>&1 || fail clone
  cd "$HOME/Develop/alice/x" || fail cd
  # teamb 조직 규칙은 bob 인데 alice 로 잠금 → 경고
  run gitch status; assert_out "잠금(alice)과 규칙(bob"
  run gitch scan; assert_fail; assert_out "잠금과 규칙이 다름"
}

test_sync_exit_code_on_failure() {
  mk_config; install_quiet
  mk_remote_seeded github-alice orig/proj
  mk_repo "$HOME/Develop/alice/fork" "git@github-alice:alice/proj.git"
  cd "$HOME/Develop/alice/fork" && gitch use alice >/dev/null
  git remote add upstream git@github-alice:orig/proj.git
  git fetch -q upstream && git checkout -q -b main upstream/main 2>/dev/null || git reset -q --hard upstream/main
  echo mine > m; gitch c -a -m mine >/dev/null
  git clone -q "$FAKE_REMOTES/github-alice/orig/proj.git" "$T/o"
  git -C "$T/o" -c user.name=o -c user.email=o@x commit -q --allow-empty -m theirs
  GITSW_SKIP=all git -C "$T/o" push -q origin main
  run gitch sync; assert_fail "갈라졌으면 sync 는 실패 종료코드"
}

test_scan_fix_and_hooks() {
  mk_config; install_quiet
  mk_repo "$HOME/Develop/bob/u" "https://github.com/bob/u.git"
  mk_repo "$HOME/Develop/bob/n"
  run gitch scan; assert_fail; assert_out "잠금 없음 → 제안: bob"
  run gitch scan --fix; assert_ok
  assert_eq "$(git -C "$HOME/Develop/bob/u" config gitswitch.account)" "bob"
  assert_eq "$(git -C "$HOME/Develop/bob/u" config remote.origin.url)" "git@github-bob:bob/u.git"
  run gitch scan --json; assert_ok
  assert_eq "$(printf '%s' "$OUT" | jq -r .problems)" "0"
}

test_install_idempotent_and_rule_order() {
  mk_config
  install_quiet; install_quiet
  local list
  list=$(git config --global --list --name-only)
  [ "$(printf '%s\n' "$list" | grep -c '^hook\.gitsw-pre-commit\.command$')" -eq 1 ] || fail "전역 훅이 중복 등록됨"
  [ "$(printf '%s\n' "$list" | grep -c 'url.git@github-bob:teamb/.insteadof')" -eq 3 ] || fail "조직 insteadOf 개수\n$list"
  # 폴더 규칙이 먼저, 조직 규칙이 마지막
  local fl ol
  fl=$(printf '%s\n' "$list" | grep -n 'includeif.gitdir:' | head -1 | cut -d: -f1)
  ol=$(printf '%s\n' "$list" | grep -n 'includeif.hasconfig:remote.\*.url:git@github-bob:teamb/' | tail -1 | cut -d: -f1)
  [ "$fl" -lt "$ol" ] || fail "규칙 순서가 틀림 (folder $fl, org $ol)"
  [ "$(git config --global user.useConfigOnly)" = true ] || fail "useConfigOnly"
  grep -q '# >>> gitsw >>>' "$RC_FILE" || fail "zshrc 연동"
  [ "$(grep -c '# >>> gitsw >>>' "$RC_FILE")" -eq 1 ] || fail "zshrc 블록 중복"
  echo tok > "$FAKE_GH/tokens/alice"; echo tok > "$FAKE_GH/tokens/bob"
  run gitch doctor --no-net; assert_ok; assert_out "DOCTOR_PROBLEMS=0"
  rm "$FAKE_GH/tokens/bob"
  run gitch doctor --no-net; assert_fail "문제가 있으면 doctor 종료코드 1"; assert_out "gh 에 bob 로그인 안 됨"
}

test_claude_settings_merge_and_remove() {
  mk_config
  cat > "$HOME/.claude/settings.json" <<'EOF'
{"model": "x", "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "my-own-hook"}]}]}, "permissions": {"allow": ["Bash(npm test)", "Bash(gitch ck)", "Bash(gitch doctor)"]}}
EOF
  install_quiet; install_quiet
  local s="$HOME/.claude/settings.json"
  assert_eq "$(jq -r .model "$s")" "x"
  assert_eq "$(jq '[.hooks.PreToolUse[] | select(.hooks[0].command == "my-own-hook")] | length' "$s")" "1"
  assert_eq "$(jq '[.hooks.PreToolUse[] | select(.hooks[0].command | test("guard --claude"))] | length' "$s")" "2"
  assert_eq "$(jq '[.permissions.allow[] | select(. == "Bash(gitch ck:*)")] | length' "$s")" "1"
  assert_eq "$(jq '[.permissions.allow[] | select(. == "Bash(gitch ck)" or . == "Bash(gitch doctor)")] | length' "$s")" "0" "예전에 넣은 겹치는 허용 항목은 지워야 함"
  assert_eq "$(jq '[.permissions.allow[] | select(. == "Bash(npm test)")] | length' "$s")" "1"
  assert_eq "$(jq '.permissions.allow | length' "$s")" "$(jq '.permissions.allow | unique | length' "$s")" "허용 목록 중복"
  [ -f "$HOME/.claude/skills/gitch/SKILL.md" ] || fail "Claude 스킬"
  [ -f "$HOME/.codex/skills/gitch/SKILL.md" ] || fail "Codex 스킬"
  grep -q 'gitsw:begin' "$HOME/.claude/CLAUDE.md" || fail "CLAUDE.md 규칙"
  run gitch ai --remove; assert_ok
  assert_eq "$(jq '[.hooks.PreToolUse[] | select(.hooks[0].command | test("guard --claude"))] | length' "$s")" "0"
  assert_eq "$(jq -r '.permissions.allow | join(",")' "$s")" "Bash(npm test)"
  grep -q 'gitsw:begin' "$HOME/.claude/CLAUDE.md" && fail "규칙이 남아 있음"
  printf 'not json' > "$s"
  run gitch ai; assert_out "올바른 JSON 이 아니라"
  assert_eq "$(cat "$s")" "not json"
}

test_ai_rules_keep_user_content() {
  mk_config
  printf '# 내 규칙\n\n- 한국어로 답한다\n' > "$HOME/.claude/CLAUDE.md"
  install_quiet; install_quiet
  grep -q '한국어로 답한다' "$HOME/.claude/CLAUDE.md" || fail "사용자 내용이 사라짐"
  [ "$(grep -c 'gitsw:begin' "$HOME/.claude/CLAUDE.md")" -eq 1 ] || fail "블록 중복"
  grep -q '조직 github.com/teamb → bob' "$HOME/.claude/CLAUDE.md" || fail "조직 규칙 안내 없음"
}

test_audit_reports_other_account_commits() {
  mk_config; install_quiet
  mk_remote_seeded github-alice alice/au alice@example.com
  git clone -q "$FAKE_REMOTES/github-alice/alice/au.git" "$T/seed2"
  git -C "$T/seed2" -c user.name=bob -c user.email=bob@example.com commit -q --allow-empty -m "oops bob"
  GITSW_SKIP=all git -C "$T/seed2" push -q origin main
  gitch clone alice alice/au "$HOME/Develop/alice/au" >/dev/null 2>&1 || fail clone
  cd "$HOME/Develop/alice/au" && run gitch audit; assert_ok; assert_out "1개"; assert_out "oops bob"
  run gitch audit --json; assert_json "$OUT"
}

test_pr_github_uses_account_token() {
  misc_repo
  gitch b feat >/dev/null; echo f > f; gitch c -a -m feat >/dev/null
  run gitch pr --title "t" --body "b"; assert_fail; assert_out "gh 에 alice 계정 로그인이 필요"; assert_out "compare/main...feat"
  echo "tok-alice" > "$FAKE_GH/tokens/alice"
  run gitch pr --title "t" --body "b"; assert_ok; assert_out "https://github.com/alice/m/pull/7"
  grep -q "GH_TOKEN=tok-alice pr create -R alice/m --head feat --base main --title t --body b" "$FAKE_GH/log" || fail "gh 호출 내용\n$(cat "$FAKE_GH/log")"
  grep -q "auth switch" "$FAKE_GH/log" && fail "gh 전역 계정을 바꾸면 안 됨"
  gitch b main >/dev/null
  run gitch pr --title x; assert_fail; assert_out "기본 브랜치"
}

test_pr_gitlab_push_options() {
  mk_config; install_quiet
  mk_remote_seeded gitlab-carol grp/app carol@corp.example
  local bare="$FAKE_REMOTES/gitlab-carol/grp/app.git"
  git -C "$bare" config receive.advertisePushOptions true
  printf '#!/bin/sh\ni=0; while [ $i -lt "${GIT_PUSH_OPTION_COUNT:-0}" ]; do eval "echo opt=\\$GIT_PUSH_OPTION_$i"; i=$((i+1)); done >&2\necho "View merge request: https://gitlab.example.com/grp/app/-/merge_requests/3" >&2\n' > "$bare/hooks/post-receive"
  chmod +x "$bare/hooks/post-receive"
  gitch clone carol grp/app "$HOME/Develop/corp/app" >/dev/null 2>&1 || fail clone
  cd "$HOME/Develop/corp/app" && gitch b feat >/dev/null && echo f > f && gitch c -a -m feat >/dev/null
  run gitch pr --title "MR 제목" --body "줄1
줄2"; assert_ok
  assert_out "merge_requests/3"
  assert_out "opt=merge_request.title=MR 제목"
  assert_out "opt=merge_request.description=줄1 줄2"
}

test_ssh_prune_removes_only_orphans() {
  mk_config
  printf '\nHost github-zed\n    HostName github.com\n    IdentityFile %s/.ssh/id_ed25519_zed\n' "$HOME" >> "$HOME/.ssh/config"
  run gitch doctor --no-net; assert_out "쓰지 않는 SSH 설정: github-zed"
  run gitch ssh prune; assert_rc 2
  run gitch ssh prune --yes; assert_ok
  grep -q 'github-zed' "$HOME/.ssh/config" && fail "고아 설정이 남음"
  grep -q 'Host github-alice' "$HOME/.ssh/config" || fail "정상 설정이 지워짐"
  grep -q 'Host gitlab-carol' "$HOME/.ssh/config" || fail "정상 설정이 지워짐"
  ls "$HOME/.local/state/gitsw/backups"/*/.ssh_config >/dev/null 2>&1 || fail "백업 없음"
}

test_setup_updates_existing_ssh_host() {
  mk_config
  printf '    User git\n    IdentitiesOnly yes\n' >> "$HOME/.ssh/config"
  run gitch config set account.carol.host gitlab.example.com:2200 --yes; assert_ok
  run gitch setup carol; assert_ok
  assert_out "~/.ssh/config 의 gitlab-carol 을 고침"
  awk '/^Host /{h=$2} h=="gitlab-carol"' "$HOME/.ssh/config" > "$T/carol"
  grep -q '^    Port 2200$' "$T/carol" || fail "포트가 바뀌지 않음:\n$(cat "$T/carol")"
  [ "$(grep -c -i '^[[:space:]]*Port' "$T/carol")" -eq 1 ] || fail "Port 줄이 여러 개"
  grep -q '^    IdentitiesOnly yes$' "$T/carol" || fail "기존 설정이 지워짐"
  grep -q 'Port' <(awk '/^Host /{h=$2} h=="github-alice"' "$HOME/.ssh/config") && fail "다른 Host 가 바뀜"
  ls "$HOME/.local/state/gitsw/backups"/*/.ssh_config >/dev/null 2>&1 || fail "백업 없음"
  run gitch setup carol; assert_ok
  case "$OUT" in *"을 고침"*) fail "같은 설정인데 다시 고침" ;; esac
  return 0
}

test_setup_keeps_other_and_custom_ssh_hosts() {
  mk_config
  # 고칠 블록 뒤에 들여쓰기·소문자로 쓴 다른 블록이 와도 그 블록은 그대로여야 한다
  printf '  Host work\n    HostName 10.0.0.5\n    Port 2222\nhost other\n    hostname o.example\n    port 2022\n' >> "$HOME/.ssh/config"
  # 사용자가 일부러 서버를 바꿔 둔 블록(22번이 막힌 곳에서 443 으로 우회)은 건드리지 않는다
  awk '/^Host github-alice$/ { print; print "    HostName ssh.github.com"; print "    Port 443"; skip = 1; next }
       /^Host / { skip = 0 } skip && /HostName/ { next } { print }' "$HOME/.ssh/config" > "$T/c" && cat "$T/c" > "$HOME/.ssh/config"
  run gitch config set account.carol.host gitlab.example.com:2200 --yes; assert_ok
  run gitch setup; assert_ok
  grep -q '^    HostName 10.0.0.5$' "$HOME/.ssh/config" || fail "다른 블록의 HostName 이 지워짐:\n$(cat "$HOME/.ssh/config")"
  grep -q '^    Port 2222$' "$HOME/.ssh/config" || fail "다른 블록의 Port 가 지워짐:\n$(cat "$HOME/.ssh/config")"
  grep -q '^    port 2022$' "$HOME/.ssh/config" || fail "소문자 블록의 port 가 지워짐"
  grep -q '^    HostName ssh.github.com$' "$HOME/.ssh/config" || fail "사용자가 바꾼 HostName 을 덮어씀"
  grep -q '^    Port 443$' "$HOME/.ssh/config" || fail "사용자가 바꾼 Port 를 덮어씀"
  grep -q '^    Port 2200$' "$HOME/.ssh/config" || fail "carol 포트가 바뀌지 않음"
  return 0
}

test_ssh_strict_option() {
  mk_config; install_quiet
  run gitch config set gitsw.sshStrict true --yes; assert_ok
  grep -q '^Host github.com$' "$HOME/.ssh/config" || fail "strict 블록 없음"
  grep -q 'PubkeyAuthentication no' "$HOME/.ssh/config" || fail "strict 설정"
  run gitch config set gitsw.sshStrict false --yes; assert_ok
  grep -q 'gitsw strict' "$HOME/.ssh/config" && fail "strict 블록이 남음"
  return 0
}

test_export_import_uninstall_version() {
  mk_config; install_quiet
  run gitch export "$T/exp.cfg"; assert_ok
  grep -q 'account "alice"' "$T/exp.cfg" || fail "내보내기 내용"
  run gitch import "$T/exp.cfg"; assert_fail "비대화형은 --yes 필요"
  run gitch import "$T/exp.cfg" --yes; assert_ok
  run gitch version; assert_ok; assert_out "gitch $(sed -n 's/^GITSW_VERSION="\([^" ]*\)".*/\1/p' "$GITSW_SRC" | head -1)"
  run gitch help; assert_ok; assert_out "gitch preflight"
  run gitch uninstall --yes; assert_ok
  git config --global --get hook.gitsw-pre-commit.command >/dev/null && fail "전역 훅이 남음"
  git config --global --get-regexp '^url\.' >/dev/null && fail "insteadOf 가 남음"
  grep -q '# >>> gitsw >>>' "$RC_FILE" && fail "zshrc 블록이 남음"
  [ -f "$HOME/.config/gitsw/config" ] || fail "설정 파일은 남겨야 함"
  run gitch install; assert_ok "다시 설치"
}

test_install_banner_fits_terminal() {
  mk_config
  # 터미널이 아니면 로고 없이 단계만
  run gitch install; assert_ok; assert_out "◆ 명령  1/5"; assert_out "설치 완료"; assert_no_out "⣿"
  local TERM=xterm-256color
  export TERM GITSW_BANNER=always GITSW_ANIM=0
  COLUMNS=100 LINES=40 run gitch install; assert_ok; assert_out "⣸⣿⣿⣿⣿⣿⣿⣿⡷"
  COLUMNS=80 LINES=24 run gitch install; assert_ok; assert_out "⢿⣿⣿⡇ ⢀⡆"; assert_no_out "⣸⣿⣿⣿⣿⣿⣿⣿⡷"
  COLUMNS=40 LINES=24 run gitch install; assert_ok; assert_out "⣿⣿⠃⢀⡄"
  COLUMNS=20 LINES=24 run gitch install; assert_ok; assert_out "gitch v"; assert_no_out "⣿"
  unset GITSW_BANNER GITSW_ANIM
}

test_install_refuses_app_outside_applications() {
  mac_only || return 0   # Windows 는 test_windows_install_location
  mk_config
  local app
  # 다운로드 폴더의 앱: 응용 프로그램 폴더로 옮기면 끊기므로 연결하지 않는다
  app="$T/Downloads/Gitrochi.app"
  mkdir -p "$app/Contents/Resources"; cp "$GITSW_SRC" "$app/Contents/Resources/gitch"
  run "$app/Contents/Resources/gitch" install; assert_fail "다운로드 폴더의 앱에 연결하면 안 됨"
  assert_out "응용 프로그램 폴더 밖의 앱"; assert_out "/Applications/Gitrochi.app/Contents/Resources/gitch install"
  # 임시 위치(App Translocation): 다음에 앱을 열면 다른 곳이 된다
  app="$T/AppTranslocation/0A1B2C/d/Gitrochi.app"
  mkdir -p "$app/Contents/Resources"; cp "$GITSW_SRC" "$app/Contents/Resources/gitch"
  run "$app/Contents/Resources/gitch" install; assert_fail "임시 위치의 앱에 연결하면 안 됨"; assert_out "임시 위치(App Translocation)"
  [ "$(resolve_path "$HOME/bin/gitch")" = "$(resolve_path "$GITSW_SRC")" ] || fail "거부했는데 ~/bin/gitch 가 바뀜"
  # ~/Applications 의 앱은 된다
  app="$HOME/Applications/Gitrochi.app"
  mkdir -p "$app/Contents/Resources"; cp "$GITSW_SRC" "$app/Contents/Resources/gitch"
  run "$app/Contents/Resources/gitch" install; assert_ok "~/Applications 의 앱"
  [ "$(resolve_path "$HOME/bin/gitch")" = "$(resolve_path "$app/Contents/Resources/gitch")" ] || fail "~/bin/gitch 가 ~/Applications 의 앱을 가리켜야 함"
}

test_install_refuses_disk_image() {
  command -v hdiutil >/dev/null 2>&1 || return 0   # 디스크 이미지는 맥에서만
  mk_config
  mkdir -p "$T/img" "$T/mnt"; cp "$GITSW_SRC" "$T/img/gitch"
  hdiutil create -quiet -srcfolder "$T/img" -volname gitch-test -format UDZO "$T/g.dmg" || fail "이미지를 만들지 못함"
  hdiutil attach -quiet -nobrowse -readonly -mountpoint "$T/mnt" "$T/g.dmg" || fail "이미지를 붙이지 못함"
  trap 'hdiutil detach -quiet -force "$T/mnt" 2>/dev/null; cd /; rm -rf "$T"' EXIT
  # 앱 밖의 gitch 라도 디스크 이미지 안이면 꺼낼 때 끊긴다
  run "$T/mnt/gitch" install; assert_fail "디스크 이미지 안의 gitch 에 연결하면 안 됨"
  assert_out "디스크 이미지에서 실행 중"; assert_out "~/.local/share/gitch/"
  [ "$(resolve_path "$HOME/bin/gitch")" = "$(resolve_path "$GITSW_SRC")" ] || fail "거부했는데 ~/bin/gitch 가 바뀜"
}

test_fork_flow_without_gh_switch() {
  mk_config; install_quiet
  mk_remote_seeded github-alice alice/lib
  echo "tok-alice" > "$FAKE_GH/tokens/alice"
  cd "$HOME/Develop/alice" && run gitch fork alice orig/lib; assert_ok
  grep -q "GH_TOKEN=tok-alice repo fork orig/lib" "$FAKE_GH/log" || fail "포크 호출\n$(cat "$FAKE_GH/log")"
  assert_eq "$(git -C "$HOME/Develop/alice/lib" config remote.upstream.url)" "git@github-alice:orig/lib.git"
}

test_publish_github_creates_private_repo_and_pushes() {
  mk_config; install_quiet
  mk_repo "$HOME/Develop/alice/newproj"
  cd "$HOME/Develop/alice/newproj" && gitch use alice >/dev/null
  echo a > a.txt; gitch c -a -m first >/dev/null
  run gitch publish; assert_rc 2 "--yes 없으면 확인 필요"
  run gitch publish --yes; assert_fail; assert_out "gh 에 alice 계정 로그인이 필요"
  echo tok-alice > "$FAKE_GH/tokens/alice"
  run gitch publish --description "테스트 저장소" --yes; assert_ok
  assert_out "GitHub 저장소를 만들었습니다: https://github.com/alice/newproj (private)"
  grep -q "GH_TOKEN=tok-alice repo create alice/newproj --private --description 테스트 저장소" "$FAKE_GH/log" || fail "gh 호출\n$(cat "$FAKE_GH/log")"
  assert_eq "$(git config remote.origin.url)" "git@github-alice:alice/newproj.git"
  assert_eq "$(git config gitswitch.alias)" "github-alice"
  assert_eq "$(git -C "$FAKE_REMOTES/github-alice/alice/newproj.git" log -1 --format=%s main)" "first"
  run gitch publish --yes; assert_fail; assert_out "이미 origin 이 있습니다"
  mk_repo "$HOME/Develop/alice/dup"
  cd "$HOME/Develop/alice/dup" && gitch use alice >/dev/null && echo b > b && gitch c -a -m b >/dev/null
  run gitch publish newproj --yes; assert_fail; assert_out "이미 alice/newproj 저장소가 있습니다"
}

test_publish_gitlab_push_to_create() {
  mk_config; install_quiet
  mk_repo "$HOME/Develop/corp/svc"
  cd "$HOME/Develop/corp/svc" && gitch use carol >/dev/null
  echo a > a.txt; gitch c -a -m first >/dev/null
  mk_remote gitlab-carol carol/svc   # 실제 GitLab 은 push 하면 프로젝트를 만들어 줌
  run gitch publish --yes; assert_ok
  assert_eq "$(git config remote.origin.url)" "git@gitlab-carol:carol/svc.git"
  assert_eq "$(git -C "$FAKE_REMOTES/gitlab-carol/carol/svc.git" log -1 --format=%s main)" "first"
}

test_backups_skip_identical_and_rules_have_no_case_duplicates() {
  mk_config
  git config -f "$HOME/.config/gitsw/config" org.github.com/TeamX.account bob
  install_quiet; install_quiet; install_quiet
  local n
  n=$(count_dirs "$HOME/.local/state/gitsw/backups"/*/)
  [ "$n" -le 2 ] || fail "같은 내용인데도 백업이 계속 쌓임 ($n 개)"
  git config --global --list --name-only | grep -q 'url.git@github-bob:teamx/' && fail "대소문자만 다른 규칙이 또 생김"
  git config --global --list --name-only | grep -q 'url.git@github-bob:TeamX/' || fail "조직 규칙 없음"
  mkdir -p "$HOME/.local/state/gitsw/backups/v1-원본"
  for i in $(seq 1 32); do mkdir -p "$HOME/.local/state/gitsw/backups/2026010$((i % 9))-0000$i-1"; done
  echo "# change" >> "$RC_FILE"; install_quiet
  [ -d "$HOME/.local/state/gitsw/backups/v1-원본" ] || fail "보관용 폴더는 정리 대상이 아님"
  n=$(count_dirs "$HOME/.local/state/gitsw/backups"/[0-9]*-[0-9]*-[0-9]*/)
  [ "$n" -le 30 ] || fail "백업 폴더가 30개를 넘음 ($n)"
}

test_doctor_email_check_handles_missing_scope() {
  mk_config; install_quiet
  echo tok > "$FAKE_GH/tokens/alice"; echo tok > "$FAKE_GH/tokens/bob"
  echo 1 > "$FAKE_GH/emails_error"
  run gitch doctor; assert_out "이메일 인증 확인은 건너뜀"; assert_no_out "인증돼 있지 않아"
  rm "$FAKE_GH/emails_error"; printf 'alice@example.com\n' > "$FAKE_GH/emails"
  run gitch doctor; assert_out "GitHub bob 계정에 bob@example.com 가 인증돼 있지 않아"; assert_no_out "alice@example.com 가 인증돼"
}
