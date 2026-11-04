# shellcheck shell=bash
# 배포할 앱 · CLI · 두 플랫폼 패키지 버전이 엇갈리면 빌드 전에 멈춘다.
VERSION_FILES="macos/Resources/Info.plist tools/gitch/gitch tools/gitch/README.md windows/package.json windows/package-lock.json windows/src-tauri/tauri.conf.json windows/src-tauri/Cargo.toml windows/src-tauri/Cargo.lock tools/gitch-flow/Cargo.toml tools/gitch-flow/Cargo.lock"

copy_version_fixture() {   # $1 folder — copies every file check-versions.sh reads
  local f
  for f in $VERSION_FILES; do
    mkdir -p "$1/$(dirname "$f")"
    cp "$ROOT/../../$f" "$1/$f" || fail "copy the version fixture: $f"
  done
}

test_versions_match_gitrochi() {
  run bash "$ROOT/../check-versions.sh"; assert_ok; assert_out "버전 일치"
}

test_version_checker_rejects_mismatched_cli() {
  local fixture="$T/version-fixture"
  copy_version_fixture "$fixture"
  sed 's/^GITSW_VERSION=.*/GITSW_VERSION="99.0.0"/' "$GITSW_SRC" > "$fixture/tools/gitch/gitch"
  run bash "$ROOT/../check-versions.sh" "$fixture"; assert_fail; assert_out "버전 불일치: gitch"
}

test_version_checker_rejects_mismatched_engine() {
  local fixture="$T/version-fixture"
  copy_version_fixture "$fixture"
  run bash "$ROOT/../check-versions.sh" "$fixture"; assert_ok
  sed 's/^version = ".*"/version = "99.0.0"/' "$ROOT/../gitch-flow/Cargo.toml" > "$fixture/tools/gitch-flow/Cargo.toml"
  run bash "$ROOT/../check-versions.sh" "$fixture"; assert_fail; assert_out "버전 불일치: tools/gitch-flow/Cargo.toml"
}

test_version_checker_rejects_stale_cli_readme() {
  local fixture="$T/version-fixture"
  copy_version_fixture "$fixture"
  sed 's/(현재 `[^`]*`)/(현재 `0.0.1`)/' "$ROOT/README.md" > "$fixture/tools/gitch/README.md"
  run bash "$ROOT/../check-versions.sh" "$fixture"; assert_fail; assert_out "버전 불일치: tools/gitch/README.md = 0.0.1"
  sed 's/^  "version": ".*",$/  "version": "0.0.1",/' "$ROOT/README.md" > "$fixture/tools/gitch/README.md"
  run bash "$ROOT/../check-versions.sh" "$fixture"; assert_fail; assert_out "버전 불일치: tools/gitch/README.md graph JSON = 0.0.1"
}
