# shellcheck shell=bash disable=SC2088  # 화면 표시용 ~ 문자열
# Windows(Git Bash) 에서만: ~/bin/gitch 연결 스크립트 · PowerShell 용 .cmd · 사용자 PATH · ~/.bashrc · 설치 위치

test_windows_install_links_cmd_and_path() {
  [ -n "$IS_WIN" ] || return 0
  mk_config
  rm -f "$HOME/bin/gitch"
  bash "$GITCH_SRC" install >/dev/null 2>&1 || fail "처음 설치 실패"
  local self; self=$(resolve_path "$GITCH_SRC")
  [ "$(resolve_path "$HOME/bin/gitch")" = "$self" ] || fail "~/bin/gitch 연결 스크립트가 이 파일을 가리키지 않음\n$(cat "$HOME/bin/gitch")"
  [ ! -e "$HOME/bin/gitsw" ] || fail "~/bin/gitsw(예전 이름)를 만듦"
  run "$HOME/bin/gitch" version; assert_ok; assert_out "gitch $(sed -n 's/^GITCH_VERSION="\([^" ]*\)".*/\1/p' "$GITCH_SRC" | head -1)"
  grep -q 'gitch-link' "$HOME/bin/gitch.cmd" && grep -q 'bash.exe' "$HOME/bin/gitch.cmd" || fail "gitch.cmd\n$(cat "$HOME/bin/gitch.cmd" 2>&1)"
  [ ! -e "$HOME/bin/gitsw.cmd" ] || fail "gitsw.cmd(예전 이름)를 만듦"
  run cmd //c "$(cygpath -w "$HOME/bin/gitch.cmd")" version; assert_ok "cmd 에서 gitch.cmd"; assert_out "gitch $(sed -n 's/^GITCH_VERSION="\([^" ]*\)".*/\1/p' "$GITCH_SRC" | head -1)"
  grep -qixF "$(cygpath -w "$HOME/bin")" "$T/userpath" || fail "사용자 PATH 에 ~/bin 이 없음"
  [ -f "$HOME/.local/state/gitch/windows-path" ] || fail "PATH 를 넣었다는 표시 없음"
  # 훅 연결 스크립트가 ~/bin/gitch 를 부른다
  grep -q "$HOME/bin/gitch" "$HOME/.local/share/gitch/hook" || fail "훅이 ~/bin/gitch 를 부르지 않음"
  # .bashrc: 한 번만, PATH 와 프롬프트(Git Bash 기본 프롬프트는 '\n$ ' 로 끝난다)
  [ "$(grep -c '# >>> gitch >>>' "$HOME/.bashrc")" -eq 1 ] || fail ".bashrc 블록"
  install_quiet
  [ "$(grep -c '# >>> gitch >>>' "$HOME/.bashrc")" -eq 1 ] || fail ".bashrc 블록 중복"
  [ "$(grep -c . "$T/userpath")" -eq 1 ] || fail "PATH 가 두 번 들어감"
  # shellcheck disable=SC2016
  bash -c 'PS1="\\w\\n\$ "; . "$HOME/.bashrc"; case "$PS1" in *_gitch_prompt*"\n$ ") ;; *) echo "$PS1"; exit 1 ;; esac' || fail "Git Bash 프롬프트에 계정이 없음"
  run gitch doctor --no-net; assert_out "~/bin/gitch.cmd"
  run gitch uninstall --yes; assert_ok
  grep -q '# >>> gitch >>>' "$HOME/.bashrc" && fail ".bashrc 블록이 남음"
  [ ! -s "$T/userpath" ] || fail "gitch 가 넣은 PATH 가 남음"
}

test_windows_keeps_user_path_and_cmd() {
  [ -n "$IS_WIN" ] || return 0
  mk_config
  cygpath -w "$HOME/bin" > "$T/userpath"          # 사용자가 이미 넣어 둔 PATH
  echo "@echo mine" > "$HOME/bin/gitch.cmd"
  run gitch install; assert_ok; assert_out "gitch.cmd 가 gitch 가 만든 파일이 아니라"
  grep -q mine "$HOME/bin/gitch.cmd" || fail "사용자 .cmd 를 덮어씀"
  [ ! -f "$HOME/.local/state/gitch/windows-path" ] || fail "원래 있던 PATH 인데 표시를 남김"
  run gitch uninstall --yes; assert_ok
  grep -qixF "$(cygpath -w "$HOME/bin")" "$T/userpath" || fail "사용자가 넣은 PATH 를 지움"
}

test_windows_install_location() {
  [ -n "$IS_WIN" ] || return 0
  mk_config
  local app="$T/portable"
  # 설치하지 않은(포터블 · 빌드) Gitrochi: 옆에 uninstall.exe 가 없다
  mkdir -p "$app"; cp "$GITCH_SRC" "$app/gitch"; : > "$app/Gitrochi.exe"
  run "$app/gitch" install; assert_fail "포터블 Gitrochi 에 연결하면 안 됨"
  assert_out "설치하지 않은(포터블 · 빌드) Gitrochi"; assert_out "~/AppData/Local/Gitrochi/gitch install"
  [ "$(resolve_path "$HOME/bin/gitch")" = "$(resolve_path "$GITCH_SRC")" ] || fail "거부했는데 ~/bin/gitch 가 바뀜"
  # 설치 프로그램으로 깐 것은 된다
  app="$HOME/AppData/Local/Gitrochi"
  mkdir -p "$app"; cp "$GITCH_SRC" "$app/gitch"; : > "$app/Gitrochi.exe"; : > "$app/uninstall.exe"
  run "$app/gitch" install; assert_ok "설치한 Gitrochi"
  [ "$(resolve_path "$HOME/bin/gitch")" = "$(resolve_path "$app/gitch")" ] || fail "~/bin/gitch 가 설치한 앱을 가리켜야 함"
  # 앱에 든 gitch 는 앱과 함께 업데이트
  run "$app/gitch" self-update; assert_ok; assert_out "앱과 함께 업데이트"
}

test_windows_guard_blocks_windows_style_paths() {
  [ -n "$IS_WIN" ] || return 0
  mk_config
  # Windows 의 Claude Code 는 Edit/Write 경로와 작업 폴더를 C:\Users\… 로 보낸다 (대소문자도 다를 수 있음)
  local w; w=$(cygpath -w "$HOME/.ssh/config")
  [ "$(ge "$w")" = deny ] || fail "Edit $w 는 deny"
  [ "$(ge "$(printf '%s' "$w" | tr '[:lower:]' '[:upper:]')")" = deny ] || fail "대문자 경로도 deny"
  [ "$(ge "$(cygpath -m "$HOME/.gitconfig")")" = deny ] || fail "C:/…/.gitconfig 는 deny"
  [ "$(ge "$(cygpath -w "$HOME/notes.txt")")" = none ] || fail "다른 파일은 그대로"
  [ "$(gd 'echo x > .gitconfig' "$(cygpath -w "$HOME")")" = deny ] || fail "작업 폴더가 C:\… 여도 상대 경로를 막아야 함"
}

test_windows_graph_out_accepts_windows_paths() {
  [ -n "$IS_WIN" ] || return 0
  mk_repo "$T/g"; cd "$T/g" || return 1
  echo x > a.txt; git add a.txt; GITCH_SKIP=all git -c user.name=a -c user.email=a@example.com commit -q -m init
  # 앱은 --out 을 C:/… 로 넘긴다 — 저장소 안이 아니라 그 자리에 써야 한다
  run gitch graph tree --format html --out "$(cygpath -m "$T/out/t.html")" --no-open; assert_ok
  [ -s "$T/out/t.html" ] || fail "C:/… 로 준 자리에 쓰지 않음"
  run gitch graph tree --format html --out "$(cygpath -w "$T/out/w.html")" --no-open; assert_ok
  [ -s "$T/out/w.html" ] || fail "C:\… 로 준 자리에 쓰지 않음"
  [ -z "$(git status --porcelain)" ] || fail "저장소 안에 파일이 생김\n$(git status --porcelain)"
}
