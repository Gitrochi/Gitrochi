# shellcheck shell=bash disable=SC2088  # 화면 표시용 ~ 문자열
# gitch 로 이름을 바꾼 뒤에도 예전 이름(gitsw)으로 쓰던 것이 그대로 되는지

test_install_links_gitch_and_gitsw_shim() {
  mk_config
  install_quiet
  local self; self=$(resolve_path "$GITSW_SRC")
  [ "$(resolve_path "$HOME/bin/gitch")" = "$self" ] || fail "~/bin/gitch 가 이 파일을 가리키지 않음"
  [ "$(resolve_path "$HOME/bin/gitsw")" = "$self" ] || fail "~/bin/gitsw(예전 이름)가 이 파일을 가리키지 않음"
  run gitsw version; assert_ok; assert_out "gitch $(sed -n 's/^GITSW_VERSION="\([^" ]*\)".*/\1/p' "$GITSW_SRC" | head -1)"
  if mac_only; then
    grep -qx "alias gitch='noglob gitch'" "$RC_FILE" || fail "gitch alias 없음"
    grep -qx "alias gitsw='noglob gitsw'" "$RC_FILE" || fail "gitsw alias 없음"
  fi
  [ "$(grep -c '# >>> gitch >>>' "$RC_FILE")" -eq 1 ] || fail "zshrc 블록 중복"
  [ "$(git config --global --get hook.gitsw-pre-commit.event)" = pre-commit ] || fail "전역 훅이 설치되지 않음"
  run gitsw status --json; assert_ok; assert_json "$OUT"
}

test_install_without_accounts_links_command() {
  # 계정이 없으면(설정 파일 없음) 명령 · 터미널만 연결한다 — 예전에는 「먼저 gitch add」로 멈춰, gitch add 가 안 되던 사람은 gitch 를 아예 못 썼다
  rm -f "$HOME/bin/gitch" "$HOME/bin/gitsw"
  run "$GITSW_SRC" install; assert_ok "계정 없이 install"; assert_out "계정이 아직 없어"; assert_out "gitch add"
  local self; self=$(resolve_path "$GITSW_SRC")
  [ "$(resolve_path "$HOME/bin/gitch")" = "$self" ] || fail "~/bin/gitch 가 연결되지 않음"
  [ "$(grep -c '# >>> gitch >>>' "$RC_FILE")" -eq 1 ] || fail "터미널 연동이 없음"
  # 계정 없이 깔면 모든 저장소의 커밋이 막히므로 useConfigOnly · 훅은 아직
  assert_eq "$(git config --global --get user.useConfigOnly)" "" "계정 없이 useConfigOnly 를 켜면 안 됨"
  assert_eq "$(git config --global --get hook.gitsw-pre-commit.event)" "" "계정 없이 검사 훅을 깔면 안 됨"
  # 계정이 필요 없는 명령은 바로 된다
  mkdir -p "$T/solo" && cd "$T/solo" && git init -q && printf 'import { b } from "./b";\n' > a.ts && printf 'export const b = 1;\n' > b.ts && git add -A
  run gitch g --json; assert_ok "계정 없이 gitch g"; assert_json "$OUT"
  # 계정을 만든 뒤 다시 하면 나머지까지
  mk_config
  run gitch install; assert_ok
  assert_eq "$(git config --global --get user.useConfigOnly)" "true"
  [ "$(git config --global --get hook.gitsw-pre-commit.event)" = pre-commit ] || fail "계정을 만든 뒤 전역 훅이 설치되지 않음"
}

test_app_opens_gitrochi() {
  mac_only || return 0                                   # Windows 는 설치 폴더의 Gitrochi.exe 를 기본 앱으로 연다
  local app="$HOME/Applications/Gitrochi.app"
  mkdir -p "$app/Contents/Resources" "$app/Contents/MacOS" && cp "$GITSW_SRC" "$app/Contents/Resources/gitch"
  run "$app/Contents/Resources/gitch" app; assert_ok "gitch app"; assert_out "Gitrochi 앱을 열었습니다"
  grep -qF "open -a $app" "$T/opened" || fail "이 gitch 가 든 앱을 열지 않음\n$(cat "$T/opened" 2>&1)"
}

test_install_keeps_user_gitsw_file() {
  mk_config
  printf '#!/bin/sh\necho mine\n' > "$HOME/bin/gitsw"; chmod +x "$HOME/bin/gitsw"
  run gitch install; assert_ok; assert_out "링크가 아닌 파일이라 그대로"
  ! is_linkish "$HOME/bin/gitsw" && grep -q 'echo mine' "$HOME/bin/gitsw" || fail "사용자 파일을 덮어씀"
}

test_install_repoints_shim_from_another_copy() {
  mk_config
  printf '#!/bin/bash\necho old-copy\n' > "$T/old-gitsw"; chmod +x "$T/old-gitsw"
  mklink_ "$T/old-gitsw" "$HOME/bin/gitsw"
  run gitch doctor --no-net; assert_out "~/bin/gitsw(예전 이름)가 다른 파일을 가리킵니다"
  install_quiet
  run gitsw version; assert_ok; assert_out "gitch $(sed -n 's/^GITSW_VERSION="\([^" ]*\)".*/\1/p' "$GITSW_SRC" | head -1)"
  run gitch doctor --no-net; assert_no_out "다른 파일을 가리킵니다"
}

test_install_migrates_gitsw_ai_files() {
  mk_config
  mkdir -p "$HOME/.claude/skills/gitsw" "$HOME/.claude/skills/mine"
  printf -- '---\nname: gitsw\ndescription: old\n---\n' > "$HOME/.claude/skills/gitsw/SKILL.md"
  printf -- '---\nname: mine\n---\n' > "$HOME/.claude/skills/mine/SKILL.md"
  printf '# 내 규칙\n\n<!-- gitsw:begin — old -->\n## Git 계정 규칙 (gitsw)\n옛 규칙 내용\n<!-- gitsw:end -->\n' > "$HOME/.claude/CLAUDE.md"
  cat > "$HOME/.claude/settings.json" <<'EOF'
{"permissions": {"allow": ["Bash(gitsw ck:*)", "Bash(gitsw c:*)", "Bash(npm test)"]},
 "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "\"/old/bin/gitsw\" guard --claude", "timeout": 15}]}]}}
EOF
  install_quiet
  [ ! -e "$HOME/.claude/skills/gitsw" ] || fail "예전 이름의 스킬이 남음"
  [ -f "$HOME/.claude/skills/gitch/SKILL.md" ] || fail "gitch 스킬 없음"
  [ -f "$HOME/.claude/skills/mine/SKILL.md" ] || fail "사용자 스킬을 지움"
  local md="$HOME/.claude/CLAUDE.md" s="$HOME/.claude/settings.json"
  [ "$(grep -c 'gitsw:begin' "$md")" -eq 1 ] || fail "규칙 블록이 중복됨"
  grep -q '모든 git 작업은 `gitch` 로 한다' "$md" || fail "규칙이 gitch 로 바뀌지 않음"
  grep -q '옛 규칙 내용' "$md" && fail "예전 규칙이 남음"
  grep -q '# 내 규칙' "$md" || fail "사용자 내용을 지움"
  jq -e '.permissions.allow | index("Bash(npm test)")' "$s" >/dev/null || fail "사용자 허용 항목을 지움"
  jq -e '.permissions.allow | index("Bash(gitch ck:*)")' "$s" >/dev/null || fail "gitch 허용 항목 없음"
  jq -e '[.permissions.allow[] | select(startswith("Bash(gitsw "))] | length == 0' "$s" >/dev/null || fail "gitsw 허용 항목이 남음"
  jq -e '[.hooks.PreToolUse[].hooks[].command | select(test("guard --claude"))] | length == 2' "$s" >/dev/null || fail "검사 훅 개수"
  jq -e '[.hooks.PreToolUse[].hooks[].command | select(test("guard --claude"))] | all(test("gitch\"? guard"))' "$s" >/dev/null \
    || fail "예전 gitsw 검사 훅이 남음"
  # 지우면 두 이름의 흔적이 다 없어진다
  run gitch ai --remove; assert_ok
  [ ! -e "$HOME/.claude/skills/gitch" ] || fail "gitch 스킬이 남음"
  jq -e '[.permissions.allow[]? | select(startswith("Bash(gitch ") or startswith("Bash(gitsw "))] | length == 0' "$s" >/dev/null || fail "허용 항목이 남음"
}

test_guard_treats_gitsw_as_gitch() {
  mk_config
  expect deny 'gitch add'
  expect deny 'gitsw add'
  expect deny '~/bin/gitsw setup alice'
  expect deny 'gitsw sign on'
  expect ask 'gitch unlock'
  expect ask 'gitsw unlock'
  expect ask 'gitsw install'
  expect none 'gitch ck'
  expect none 'gitsw ck'
}

test_allow_marker_both_names() {
  hook_repo
  printf 'token = "ghp_%s"  # gitch:allow\n' "abcdefghijklmnopqrstuvwxyz0123456789" > a.py; git add a.py
  run git commit -q -m a; assert_ok "gitch:allow 줄은 통과"
  printf 'token = "ghp_%s"  # gitsw:allow\n' "zyxwvutsrqponmlkjihgfedcba9876543210" > b.py; git add b.py
  run git commit -q -m b; assert_ok "예전 이름 gitsw:allow 줄도 통과"
  printf 'token = "ghp_%s"\n' "0123456789abcdefghijklmnopqrstuvwxyz" > c.py; git add c.py
  run git commit -q -m c; assert_fail; assert_out "gitch:allow"
}

test_self_update_does_not_pull() {
  run gitch self-update; assert_ok; assert_out "앱과 함께 업데이트"
}

test_install_replaces_old_shell_block() {
  # installs before the rename wrote a gitsw-marked block; install swaps it for the gitch one, uninstall removes either
  mk_config
  printf 'export KEEP=1\n# >>> gitsw >>>  (old)\n_gitsw_prompt() { :; }\n# <<< gitsw <<<\n' > "$RC_FILE"
  install_quiet
  grep -q '# >>> gitsw >>>' "$RC_FILE" && fail "the old gitsw block is left"
  grep -q '_gitsw_prompt' "$RC_FILE" && fail "the old prompt function is left"
  [ "$(grep -c '# >>> gitch >>>' "$RC_FILE")" -eq 1 ] || fail "no gitch block"
  grep -qx 'export KEEP=1' "$RC_FILE" || fail "a line outside the block was lost"
  printf '# >>> gitsw >>>\n# <<< gitsw <<<\n' >> "$RC_FILE"
  run gitch uninstall --yes; assert_ok
  grep -qE '# >>> (gitch|gitsw) >>>' "$RC_FILE" && fail "uninstall left a shell block"
  grep -qx 'export KEEP=1' "$RC_FILE" || fail "uninstall lost a line outside the block"
}

test_prompt_shows_nothing_without_account() {
  mac_only || return 0
  command -v zsh >/dev/null || return 0
  mk_config
  install_quiet
  mkdir -p "$T/plain" && cd "$T/plain" && git init -q
  # shellcheck disable=SC2016
  local out; out=$(zsh -fc 'eval "$(sed -n "/^_gitch_prompt()/,/^}/p" "$1")"; _gitch_prompt' _ "$RC_FILE")
  assert_eq "$out" "" "a repository with no account shows a marker"
  git config gitswitch.account work
  # shellcheck disable=SC2016
  out=$(zsh -fc 'eval "$(sed -n "/^_gitch_prompt()/,/^}/p" "$1")"; _gitch_prompt' _ "$RC_FILE")
  assert_eq "$out" "%F{green}[work]%f" "the account is not shown"
}
