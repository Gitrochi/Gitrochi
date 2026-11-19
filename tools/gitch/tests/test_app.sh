# shellcheck shell=bash
# 앱 실행은 모두 가짜 open/PowerShell 로 검증한다. 실제 Gitrochi 는 실행하지 않는다.

app_fakes() {
  export APP_TEST_LOG="$T/app-launched" APP_TEST_ARGS="$T/app-args" APP_TEST_ROUTE="$T/app-route" APP_TEST_STATUS=0 APP_TEST_WINDOWS_ROOT="$T"
  export GITCH_OS=darwin
  unset LOCALAPPDATA PROGRAMFILES ProgramFiles PROGRAMW6432
  cat > "$T/fakebin/open" <<'EOF'
#!/bin/bash
printf '%s\n' "$#" "$@" > "$APP_TEST_ARGS"
printf '%s' "${2:-}" > "$APP_TEST_LOG"
exit "$APP_TEST_STATUS"
EOF
  cat > "$T/fakebin/powershell" <<'EOF'
#!/bin/bash
printf '%s\n' "$#" "$@" > "$APP_TEST_ARGS"
printf '%s' "$GITCH_APP_PATH" > "$APP_TEST_LOG"
printf '%s' "$GITCH_APP_ROUTE" > "$APP_TEST_ROUTE"
exit "$APP_TEST_STATUS"
EOF
  cat > "$T/fakebin/cygpath" <<'EOF'
#!/bin/bash
case "$1" in
  -w) printf 'native:%s' "$2" ;;
  -u) case "$2" in C:/*) printf '%s/%s' "$APP_TEST_WINDOWS_ROOT" "${2#C:/}" ;; *) printf '%s' "$2" ;; esac ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$T/fakebin/open" "$T/fakebin/powershell" "$T/fakebin/cygpath"
}

app_cli_copy() { mkdir -p "$(dirname "$1")"; cp "$GITCH_SRC" "$1"; chmod +x "$1"; }
app_mac_bundle() { mkdir -p "$1/Contents/MacOS"; }
app_windows_exe() { mkdir -p "$(dirname "$1")"; : > "$1"; }

test_app_help_and_arguments() {
  app_fakes
  run gitch app --help; assert_ok; assert_out 'gitch app [저장소|폴더]'; assert_out 'macOS · Windows'
  [ ! -f "$APP_TEST_LOG" ] || fail '도움말에서 앱을 실행함'
  run gitch help; assert_ok; assert_out 'gitch app [--path 앱경로]'
  run gitch app --path; assert_fail; assert_out '--path 뒤에 앱 경로'
  run gitch app --path=; assert_fail; assert_out '--path 뒤에 앱 경로'
  run gitch app --unknown; assert_fail; assert_out '알 수 없는 app 인자'
  [ ! -f "$APP_TEST_LOG" ] || fail '잘못된 인자에서 앱을 실행함'
}

test_app_repository_and_file_route() {
  app_fakes
  local app="$T/Gitrochi.app" repo="$T/repo space 한글 & literal"
  app_mac_bundle "$app"
  mk_repo "$repo"
  run gitch app --path "$app" --repo "$repo" --file 'src/한글 #?.ts' --line 25
  assert_ok
  local uri
  uri=$(tail -1 "$APP_TEST_ARGS")
  case "$uri" in gitrochi://open?repo=*repo%20space%20%ED%95%9C%EA%B8%80%20%26%20literal\&file=src%2F%ED%95%9C%EA%B8%80%20%23%3F.ts\&line=25) ;; *) fail "경로 URL 인코딩: $uri" ;; esac
  assert_eq "$(head -1 "$APP_TEST_ARGS")" 3 'open 의 URL 인자 경계'
  cd "$repo" || fail "cd $repo"
  run gitch app . --path "$app"; assert_ok; assert_out '앱을 열었습니다'
  run gitch app --path "$app" --file 'removed/file.ts' --view diff; assert_ok
  case "$(tail -1 "$APP_TEST_ARGS")" in *\&file=removed%2Ffile.ts\&view=diff) ;; *) fail '삭제한 파일의 diff 라우트' ;; esac
}

test_app_route_rejects_unsafe_files_and_invalid_views() {
  app_fakes
  local app="$T/Gitrochi.app" repo="$T/repo" bad
  app_mac_bundle "$app"; mk_repo "$repo"
  mkdir -p "$T/outside"
  local has_link=""
  if [ -n "$IS_WIN" ]; then MSYS=winsymlinks:nativestrict ln -s "$T/outside" "$repo/link" 2>/dev/null || :
  else ln -s "$T/outside" "$repo/link"; fi
  [ ! -L "$repo/link" ] || has_link=1
  for bad in '../secret' '/etc/passwd' 'a/../secret' 'a\\b' 'C:secret'; do
    run gitch app --path "$app" --repo "$repo" --file "$bad"; assert_fail
  done
  if [ -n "$has_link" ]; then run gitch app --path "$app" --repo "$repo" --file 'link/secret'; assert_fail; fi
  for bad in 0 -1 1x 1000000000; do
    run gitch app --path "$app" --repo "$repo" --file source.ts --line "$bad"; assert_fail
  done
  run gitch app --path "$app" --repo "$repo" --line 12; assert_fail
  run gitch app --path "$app" --repo "$repo" --view unknown; assert_fail
  run gitch app --path "$app" --repo "$repo" --view diff; assert_fail
  run gitch app --path "$app" --repo "$repo" --commit short; assert_fail
  run gitch app --path "$app" --repo "$repo" "$repo"; assert_fail
  [ ! -f "$APP_TEST_LOG" ] || fail '잘못된 경로에서 앱을 실행함'
}

test_app_commit_route() {
  app_fakes
  local app="$T/Gitrochi.app" repo="$T/repo" hash=0123456789012345678901234567890123456789
  app_mac_bundle "$app"; mk_repo "$repo"
  run gitch app --path "$app" --repo "$repo" --file source.ts --commit "$hash" --view graph
  assert_ok
  case "$(tail -1 "$APP_TEST_ARGS")" in *\&view=graph\&commit="$hash") ;; *) fail '커밋 라우트가 보존되지 않음' ;; esac
}

test_app_repository_name_and_windows_route() {
  app_fakes; mk_config
  local app="$T/Gitrochi.exe" repo="$HOME/Develop/alice/RouteProject"
  app_windows_exe "$app"; mk_repo "$repo"
  export GITCH_OS=msys
  run gitch app RouteProject --path "$app" --file source.ts --line 3
  assert_ok
  case "$(cat "$APP_TEST_ROUTE")" in gitrochi://open?repo=native%3A*RouteProject\&file=source.ts\&line=3) ;; *) fail 'Windows 라우트가 보존되지 않음' ;; esac
}

test_app_mac_explicit_spaced_path_and_failure() {
  app_fakes
  # 셸 기호와 작은따옴표도 경로일 뿐이다.
  local app="$T/앱 space ' \$literal; quote/Gitrochi.app"
  app_mac_bundle "$app"
  run gitch app --path "$app"; assert_ok
  assert_eq "$(cat "$APP_TEST_LOG")" "$app"
  assert_eq "$(cat "$APP_TEST_ARGS")" "$(printf '2\n-a\n%s' "$app")" 'open 의 인자 경계'
  export APP_TEST_STATUS=7
  run gitch app --path="$app"; assert_fail; assert_out '앱을 열지 못했습니다'
}

test_app_mac_bundled_cli_and_symlink() {
  app_fakes
  local app="$T/Bundle Space/Gitrochi.app"
  app_mac_bundle "$app"
  app_cli_copy "$app/Contents/Resources/gitch"
  mklink_ "$app/Contents/Resources/gitch" "$T/gitch-link"
  run bash "$T/gitch-link" app; assert_ok
  assert_eq "$(cat "$APP_TEST_LOG")" "$app" '동봉 앱 우선'
}

test_app_mac_source_build_precedes_install() {
  app_fakes
  local source="$T/source space" app="$T/source space/macos/build/Gitrochi.app"
  app_cli_copy "$source/tools/gitch/gitch"
  app_mac_bundle "$app"
  app_mac_bundle "$HOME/Applications/Gitrochi.app"
  run bash "$source/tools/gitch/gitch" app; assert_ok
  assert_eq "$(cat "$APP_TEST_LOG")" "$app" '개발 빌드 우선'
}

test_app_mac_standalone_finds_user_install() {
  app_fakes
  local cli="$T/standalone/gitch" app="$HOME/Applications/Gitrochi.app"
  app_cli_copy "$cli"
  app_mac_bundle "$app"
  run bash "$cli" app; assert_ok
  assert_eq "$(cat "$APP_TEST_LOG")" "$app"
  run bash "$cli" app --path "$T/missing.app"; assert_fail; assert_out '앱을 찾을 수 없습니다'
  run bash "$cli" app --path "$T"; assert_fail; assert_out '앱을 찾을 수 없습니다'
}

test_app_windows_bundled_cli() {
  app_fakes
  export GITCH_OS=msys
  local dir="$T/Bundled App" app="$T/Bundled App/Gitrochi.exe"
  app_cli_copy "$dir/gitch"
  app_windows_exe "$app"
  run bash "$dir/gitch" app; assert_ok
  assert_eq "$(cat "$APP_TEST_LOG")" "native:$app"
  assert_eq "$(head -n 4 "$APP_TEST_ARGS")" "$(printf '4\n-NoProfile\n-NonInteractive\n-EncodedCommand')" '안전한 PowerShell 실행'
}

test_app_windows_source_build_precedes_install() {
  app_fakes
  export GITCH_OS=msys
  local source="$T/source" app="$T/source/windows/src-tauri/target/release/gitrochi.exe"
  app_cli_copy "$source/tools/gitch/gitch"
  app_windows_exe "$app"
  app_windows_exe "$HOME/AppData/Local/Gitrochi/Gitrochi.exe"
  run bash "$source/tools/gitch/gitch" app; assert_ok
  assert_eq "$(cat "$APP_TEST_LOG")" "native:$app"
}

test_app_windows_user_and_machine_install_locations() {
  app_fakes
  export GITCH_OS=msys
  local cli="$T/standalone/gitch" app="$HOME/AppData/Local/Gitrochi/Gitrochi.exe"
  app_cli_copy "$cli"
  app_windows_exe "$app"
  run bash "$cli" app; assert_ok
  assert_eq "$(cat "$APP_TEST_LOG")" "native:$app"
  rm "$app"
  export LOCALAPPDATA='C:/Local Space'
  app="$T/Local Space/Programs/Gitrochi/Gitrochi.exe"
  app_windows_exe "$app"
  run bash "$cli" app; assert_ok
  assert_eq "$(cat "$APP_TEST_LOG")" "native:$app"
  rm "$app"
  export PROGRAMFILES='C:/Program Files'
  app="$T/Program Files/Gitrochi/Gitrochi.exe"
  app_windows_exe "$app"
  run bash "$cli" app; assert_ok
  assert_eq "$(cat "$APP_TEST_LOG")" "native:$app"
}

test_app_windows_explicit_special_path_and_launch_failure() {
  app_fakes
  export GITCH_OS=msys
  local app="$T/space ' \$literal; & [bracket]/Gitrochi.exe"
  app_windows_exe "$app"
  run gitch app --path "$app"; assert_ok
  assert_eq "$(cat "$APP_TEST_LOG")" "native:$app"
  export APP_TEST_STATUS=5
  run gitch app --path "$app"; assert_fail; assert_out '앱을 열지 못했습니다'
}

test_app_not_installed_and_unsupported_platform() {
  app_fakes
  export GITCH_OS=msys
  local cli="$T/standalone/gitch"
  app_cli_copy "$cli"
  run bash "$cli" app; assert_fail; assert_out '앱을 찾을 수 없습니다'; assert_out 'gitch app --path'
  [ ! -f "$APP_TEST_LOG" ] || fail '앱이 없는데 실행을 시도함'
  export GITCH_OS=linux-gnu
  run bash "$cli" app; assert_fail; assert_out 'macOS · Windows 에서 지원'
  run bash "$cli" app --help; assert_ok
}
