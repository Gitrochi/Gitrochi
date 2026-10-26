# shellcheck shell=bash
# 배포할 앱 · CLI · 두 플랫폼 패키지 버전이 엇갈리면 빌드 전에 멈춘다.
test_versions_match_gitrochi() {
  run bash "$ROOT/../check-versions.sh"; assert_ok; assert_out "버전 일치"
}

test_version_checker_rejects_mismatched_cli() {
  local fixture="$T/version-fixture" f
  for f in macos/Resources/Info.plist tools/gitch/gitch windows/package.json windows/package-lock.json windows/src-tauri/tauri.conf.json windows/src-tauri/Cargo.toml windows/src-tauri/Cargo.lock tools/gitch-flow/Cargo.toml tools/gitch-flow/Cargo.lock; do
    mkdir -p "$fixture/$(dirname "$f")"
    cp "$ROOT/../../$f" "$fixture/$f" || fail "버전 예제 복사: $f"
  done
  sed 's/^GITSW_VERSION=.*/GITSW_VERSION="99.0.0"/' "$GITSW_SRC" > "$fixture/tools/gitch/gitch"
  run bash "$ROOT/../check-versions.sh" "$fixture"; assert_fail; assert_out "버전 불일치: gitch"
}

test_version_checker_rejects_mismatched_engine() {
  local fixture="$T/version-fixture" f
  for f in macos/Resources/Info.plist tools/gitch/gitch windows/package.json windows/package-lock.json windows/src-tauri/tauri.conf.json windows/src-tauri/Cargo.toml windows/src-tauri/Cargo.lock tools/gitch-flow/Cargo.toml tools/gitch-flow/Cargo.lock; do
    mkdir -p "$fixture/$(dirname "$f")"
    cp "$ROOT/../../$f" "$fixture/$f" || fail "버전 예제 복사: $f"
  done
  run bash "$ROOT/../check-versions.sh" "$fixture"; assert_ok
  sed 's/^version = ".*"/version = "99.0.0"/' "$ROOT/../gitch-flow/Cargo.toml" > "$fixture/tools/gitch-flow/Cargo.toml"
  run bash "$ROOT/../check-versions.sh" "$fixture"; assert_fail; assert_out "버전 불일치: tools/gitch-flow/Cargo.toml"
}
