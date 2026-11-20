# shellcheck shell=bash disable=SC2088  # 화면 표시용 ~ 문자열
# gitch 로 이름을 바꾼 뒤: 예전 이름(gitsw)으로 된 설정을 한 번에 옮기고, 그 뒤로는 gitch 이름만 쓰는지

test_install_links_only_gitch() {
  mk_config
  install_quiet
  local self; self=$(resolve_path "$GITCH_SRC")
  [ "$(resolve_path "$HOME/bin/gitch")" = "$self" ] || fail "~/bin/gitch 가 이 파일을 가리키지 않음"
  [ ! -e "$HOME/bin/gitsw" ] || fail "~/bin/gitsw(예전 이름)를 만듦"
  if mac_only; then
    grep -qx "alias gitch='noglob gitch'" "$RC_FILE" || fail "gitch alias 없음"
    grep -q "gitsw" "$RC_FILE" && fail "zshrc 에 gitsw 가 남음"
  fi
  [ "$(grep -c '# >>> gitch >>>' "$RC_FILE")" -eq 1 ] || fail "zshrc 블록 중복"
  [ "$(git config --global --get hook.gitch-pre-commit.event)" = pre-commit ] || fail "전역 훅이 설치되지 않음"
  run gitch status --json; assert_ok; assert_json "$OUT"
}

test_install_without_accounts_links_command() {
  # 계정이 없으면(설정 파일 없음) 명령 · 터미널만 연결한다 — 예전에는 「먼저 gitch add」로 멈춰, gitch add 가 안 되던 사람은 gitch 를 아예 못 썼다
  rm -f "$HOME/bin/gitch"
  run "$GITCH_SRC" install; assert_ok "계정 없이 install"; assert_out "계정이 아직 없어"; assert_out "gitch add"
  local self; self=$(resolve_path "$GITCH_SRC")
  [ "$(resolve_path "$HOME/bin/gitch")" = "$self" ] || fail "~/bin/gitch 가 연결되지 않음"
  [ "$(grep -c '# >>> gitch >>>' "$RC_FILE")" -eq 1 ] || fail "터미널 연동이 없음"
  # 계정 없이 깔면 모든 저장소의 커밋이 막히므로 useConfigOnly · 훅은 아직
  assert_eq "$(git config --global --get user.useConfigOnly)" "" "계정 없이 useConfigOnly 를 켜면 안 됨"
  assert_eq "$(git config --global --get hook.gitch-pre-commit.event)" "" "계정 없이 검사 훅을 깔면 안 됨"
  # 계정이 필요 없는 명령은 바로 된다
  mkdir -p "$T/solo" && cd "$T/solo" && git init -q && printf 'import { b } from "./b";\n' > a.ts && printf 'export const b = 1;\n' > b.ts && git add -A
  run gitch g --json; assert_ok "계정 없이 gitch g"; assert_json "$OUT"
  # 계정을 만든 뒤 다시 하면 나머지까지
  mk_config
  run gitch install; assert_ok
  assert_eq "$(git config --global --get user.useConfigOnly)" "true"
  [ "$(git config --global --get hook.gitch-pre-commit.event)" = pre-commit ] || fail "계정을 만든 뒤 전역 훅이 설치되지 않음"
}

test_app_opens_gitrochi() {
  mac_only || return 0                                   # Windows 는 설치 폴더의 Gitrochi.exe 를 기본 앱으로 연다
  local app="$HOME/Applications/Gitrochi.app"
  mkdir -p "$app/Contents/Resources" "$app/Contents/MacOS" && cp "$GITCH_SRC" "$app/Contents/Resources/gitch"
  run "$app/Contents/Resources/gitch" app; assert_ok "gitch app"; assert_out "Gitrochi 앱을 열었습니다"
  grep -qF "open -a $app" "$T/opened" || fail "이 gitch 가 든 앱을 열지 않음\n$(cat "$T/opened" 2>&1)"
}





test_allow_marker_both_names() {   # gitsw:allow stays: it is written in shared source files, not in this machine's setup
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


test_prompt_shows_nothing_without_account() {
  mac_only || return 0
  command -v zsh >/dev/null || return 0
  mk_config
  install_quiet
  mkdir -p "$T/plain" && cd "$T/plain" && git init -q
  # shellcheck disable=SC2016
  local out; out=$(zsh -fc 'eval "$(sed -n "/^_gitch_prompt()/,/^}/p" "$1")"; _gitch_prompt' _ "$RC_FILE")
  assert_eq "$out" "" "a repository with no account shows a marker"
  git config gitch.account work
  # shellcheck disable=SC2016
  out=$(zsh -fc 'eval "$(sed -n "/^_gitch_prompt()/,/^}/p" "$1")"; _gitch_prompt' _ "$RC_FILE")
  assert_eq "$out" "%F{green}[work]%f" "the account is not shown"
}

# A home folder and a repository as the gitsw-era releases left them
old_gitsw_setup() {
  mk_config
  install_quiet
  local c="$HOME/.config/gitch" st="$HOME/.local/state/gitch" sh="$HOME/.local/share/gitch" ev
  # the commit runs before the hook dispatcher moves away
  mkdir -p "$T/old/repo" && (cd "$T/old/repo" && git init -q && git -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m one)
  git config -f "$c/config" --rename-section gitch gitsw 2>/dev/null
  git config -f "$c/config" gitsw.aiPush branch
  mv "$c" "$HOME/.config/gitsw"; mv "$st" "$HOME/.local/state/gitsw"; mv "$sh" "$HOME/.local/share/gitsw"
  for ev in $(git config --global --name-only --get-regexp '^hook\.gitch-.*\.event$' | sed 's/^hook\.gitch-//; s/\.event$//'); do
    git config --global --rename-section "hook.gitch-$ev" "hook.gitsw-$ev"
  done
  sed -i.bak 's/^# >>> gitch >>>/# >>> gitsw >>>/; s/^# <<< gitch <<</# <<< gitsw <<</; s/_gitch_prompt/_gitsw_prompt/g' "$RC_FILE" && rm -f "$RC_FILE.bak"
  mkdir -p "$HOME/.ssh"; printf 'Host *\n# >>> gitsw strict >>>  (old)\n  IdentitiesOnly yes\n# <<< gitsw strict <<<\n' >> "$HOME/.ssh/config"
  mklink_ "$GITCH_SRC" "$HOME/bin/gitsw"
  cd "$T/old/repo" || fail cd
  git config gitswitch.account alice; git config gitswitch.protect main
  git update-ref refs/gitsw/backup/20260101-000000-pl HEAD
  printf '#!/bin/sh\n# gitswitch-lock — old\nexit 0\n' > .git/hooks/pre-commit; chmod +x .git/hooks/pre-commit
}

test_moves_gitsw_setup_once() {
  old_gitsw_setup
  run gitch list; assert_ok; assert_out "gitsw"   # the one-line notice names the old folders' name
  [ ! -e "$HOME/.config/gitsw" ] && [ ! -e "$HOME/.local/state/gitsw" ] && [ ! -e "$HOME/.local/share/gitsw" ] || fail "an old folder is left"
  [ -f "$HOME/.config/gitch/config" ] || fail "the config file did not move"
  assert_eq "$(git config -f "$HOME/.config/gitch/config" --get gitch.aiPush)" "branch" "the [gitsw] settings did not move"
  [ -z "$(git config -f "$HOME/.config/gitch/config" --get-regexp '^gitsw\.')" ] || fail "a [gitsw] setting is left"
  [ -z "$(git config --global --get-regexp '^hook\.gitsw-')" ] || fail "an old global hook is left"
  [ "$(git config --global --get hook.gitch-pre-commit.event)" = pre-commit ] || fail "the global hooks were not registered again"
  case "$(git config --global --get hook.gitch-pre-commit.command)" in   # D:/… on Windows
    *share/gitch/hook*) ;; *) fail "the hook does not run the moved dispatcher" ;;
  esac
  grep -q gitsw "$RC_FILE" && fail "the shell file still says gitsw"
  [ "$(grep -c '# >>> gitch >>>' "$RC_FILE")" -eq 1 ] || fail "no gitch shell block"
  grep -q 'gitsw strict' "$HOME/.ssh/config" && fail "the SSH marker still says gitsw"
  grep -q '# >>> gitch strict >>>' "$HOME/.ssh/config" || fail "the SSH block was lost"
  [ ! -e "$HOME/bin/gitsw" ] || fail "~/bin/gitsw is left"
  # the repository gitch ran in moved too
  assert_eq "$(git config --get gitch.account)" "alice" "the repository account did not move"
  assert_eq "$(git config --get gitch.protect)" "main" "the protected branch did not move"
  [ -z "$(git config --get-regexp '^gitswitch\.')" ] || fail "a gitswitch setting is left"
  git rev-parse -q --verify refs/gitch/backup/20260101-000000-pl >/dev/null || fail "the backup ref did not move"
  [ -z "$(git for-each-ref refs/gitsw/)" ] || fail "an old backup ref is left"
  grep -q gitswitch-lock .git/hooks/pre-commit && fail "the fallback hook still has the old marker"
  [ ! -e .git/hooks/pre-commit.local ] || fail "gitch's own old hook was kept as a user hook"
  # once: the next run has nothing to move
  run gitch list; assert_ok; assert_no_out "gitsw"
}

test_install_moves_repositories_it_finds() {
  old_gitsw_setup
  mkdir -p "$T/scan/other" && cd "$T/scan/other" && git init -q && git config gitswitch.account alice
  git config -f "$HOME/.config/gitsw/config" gitsw.scanRoot "$T/scan"
  cd "$T" || fail cd
  install_quiet
  assert_eq "$(git -C "$T/scan/other" config --get gitch.account)" "alice" "install did not move a repository under the scan folder"
}

test_moving_keeps_user_gitsw_file() {
  mk_config
  install_quiet
  mv "$HOME/.config/gitch" "$HOME/.config/gitsw"
  printf '#!/bin/sh\necho mine\n' > "$HOME/bin/gitsw"; chmod +x "$HOME/bin/gitsw"
  run gitch list; assert_ok; assert_out "그대로 뒀습니다"
  grep -q 'echo mine' "$HOME/bin/gitsw" || fail "a file of the user's was removed"
}

test_moving_rewrites_old_ai_files() {
  mk_config
  install_quiet
  mv "$HOME/.config/gitch" "$HOME/.config/gitsw"
  mkdir -p "$HOME/.claude/skills/gitsw" "$HOME/.claude/skills/mine"
  printf -- '---\nname: gitsw\ndescription: old\n---\n' > "$HOME/.claude/skills/gitsw/SKILL.md"
  printf -- '---\nname: mine\n---\n' > "$HOME/.claude/skills/mine/SKILL.md"
  printf '# 내 규칙\n\n<!-- gitsw:begin — old -->\n## Git 계정 규칙 (gitsw)\n옛 규칙 내용\n<!-- gitsw:end -->\n' > "$HOME/.claude/CLAUDE.md"
  run gitch list; assert_ok
  local md="$HOME/.claude/CLAUDE.md"
  [ ! -e "$HOME/.claude/skills/gitsw" ] || fail "the old skill is left"
  [ -f "$HOME/.claude/skills/gitch/SKILL.md" ] || fail "no gitch skill"
  [ -f "$HOME/.claude/skills/mine/SKILL.md" ] || fail "a skill of the user's was removed"
  grep -q 'gitsw' "$md" && fail "the AI rules still say gitsw"
  [ "$(grep -c 'gitch:begin' "$md")" -eq 1 ] || fail "no gitch rules block"
  grep -q '# 내 규칙' "$md" || fail "the user's own rules were removed"
}

test_install_cleans_gitsw_claude_entries() {
  mk_config
  mkdir -p "$HOME/.claude"
  cat > "$HOME/.claude/settings.json" <<'EOF'
{"permissions": {"allow": ["Bash(gitsw ck:*)", "Bash(gitsw c:*)", "Bash(npm test)"]},
 "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "\"/old/bin/gitsw\" guard --claude", "timeout": 15}]}]}}
EOF
  install_quiet
  local s="$HOME/.claude/settings.json"
  jq -e '.permissions.allow | index("Bash(npm test)")' "$s" >/dev/null || fail "a permission of the user's was removed"
  jq -e '[.permissions.allow[] | select(startswith("Bash(gitsw "))] | length == 0' "$s" >/dev/null || fail "a gitsw permission is left"
  jq -e '[.hooks.PreToolUse[].hooks[].command | select(test("guard --claude"))] | all(test("gitch\"? guard"))' "$s" >/dev/null \
    || fail "the old gitsw guard hook is left"
}

test_guard_no_longer_knows_gitsw() {
  mk_config
  expect deny 'gitch add'
  expect none 'gitsw add'
}
