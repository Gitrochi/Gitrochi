#!/bin/bash
# 앱 · CLI 버전을 따로 올려 배포한 뒤 업데이트가 엇갈리는 일을 빌드 전에 막는다.
set -eu
ROOT=${1:-$(cd "$(dirname "$0")/.." && pwd -P)}
expected=$(awk '/<key>CFBundleShortVersionString<\/key>/ { getline; gsub(/.*<string>|<\/string>.*/, ""); print; exit }' "$ROOT/macos/Resources/Info.plist")
failed=0
check() {
  if [ -z "$2" ] || [ "$2" != "$expected" ]; then
    printf '버전 불일치: %s = %s (Gitrochi %s 필요)\n' "$1" "${2:-없음}" "$expected" >&2
    failed=1
  fi
}
json_versions() { sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1"; }
case "$expected" in ''|*[!0-9.]*) printf 'Gitrochi 앱 버전을 읽지 못했습니다.\n' >&2; exit 1 ;; esac
check gitch "$(sed -n 's/^GITSW_VERSION="\([^"]*\)".*/\1/p' "$ROOT/tools/gitch/gitch" | head -1)"
check windows/package.json "$(json_versions "$ROOT/windows/package.json" | head -1)"
check windows/package-lock.json "$(json_versions "$ROOT/windows/package-lock.json" | head -1)"
check 'windows/package-lock.json packages[""]' "$(json_versions "$ROOT/windows/package-lock.json" | sed -n '2p')"
check windows/src-tauri/tauri.conf.json "$(json_versions "$ROOT/windows/src-tauri/tauri.conf.json" | head -1)"
check windows/src-tauri/Cargo.toml "$(sed -n 's/^version = "\([^"]*\)".*/\1/p' "$ROOT/windows/src-tauri/Cargo.toml" | head -1)"
check 'windows/src-tauri/Cargo.lock gitrochi' "$(awk '/^name = "gitrochi"$/ { found = 1; next } found && /^version = / { sub(/^version = "/, ""); sub(/".*$/, ""); print; exit }' "$ROOT/windows/src-tauri/Cargo.lock")"
check tools/gitch-flow/Cargo.toml "$(sed -n 's/^version = "\([^"]*\)".*/\1/p' "$ROOT/tools/gitch-flow/Cargo.toml" | head -1)"
check 'tools/gitch-flow/Cargo.lock gitch-flow' "$(awk '/^name = "gitch-flow"$/ { found = 1; next } found && /^version = / { sub(/^version = "/, ""); sub(/".*$/, ""); print; exit }' "$ROOT/tools/gitch-flow/Cargo.lock")"
[ "$failed" -eq 0 ] || exit 1
printf 'Gitrochi · gitch · gitch-flow 버전 일치: %s\n' "$expected"
