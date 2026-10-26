# shellcheck shell=bash disable=SC2088  # 화면에 보이는 ~ 를 그대로 비교
# 앱 없이 쓰는 gitch: tools/gitch/install.sh 와 따로 받은 gitch 의 self-update (가짜 curl 이 GitHub 릴리스를 흉내 낸다)

RELEASES_API="api.github.com/repos/Gitrochi/Gitrochi/releases"

# 가짜 릴리스 하나 — 나중에 만든 것이 목록 맨 앞(가장 새 것)
#   $1 태그  $2 gitch 파일(- 이면 없음) [$3 prerelease | badsum | helpers | corrupthelper | missinghelper | missingsum]
mk_release() {
  local tag="$1" src="$2" opt="${3:-}" dl="$FAKE_WEB/github.com/Gitrochi/Gitrochi/releases/download/$1" f assets="" sep="" n=0
  mkdir -p "$dl" "$FAKE_WEB/rel" "$FAKE_WEB/${RELEASES_API%/*}"
  echo setup > "$dl/Gitrochi_${tag#v}_x64-setup.exe"
  if [ "$src" != - ]; then
    cp "$src" "$dl/gitch"
    # 릴리스 작업(맥)은 shasum, Windows 의 Git Bash 에는 sha256sum 만 있을 수 있다
    (cd "$dl" && { shasum -a 256 gitch 2>/dev/null || sha256sum gitch; } > gitch.sha256)
    [ "$opt" = badsum ] && printf '%064d  gitch\n' 0 > "$dl/gitch.sha256"
    case "$opt" in
      engine|badengine|brokenengine)
        for f in gitch-scip-index gitch-graph-watch; do
          cp "$ROOT/$f" "$dl/$f"
          (cd "$dl" && { shasum -a 256 "$f" 2>/dev/null || sha256sum "$f"; } > "$f.sha256")
        done
        f=$(flow_asset_name)
        if [ "$opt" = brokenengine ]; then printf 'not an executable\n' > "$dl/$f"; else cp "$FLOW_ENGINE_BIN" "$dl/$f"; fi
        (cd "$dl" && { shasum -a 256 "$f" 2>/dev/null || sha256sum "$f"; } > "$f.sha256")
        [ "$opt" != badengine ] || printf '%064d  %s\n' 0 "$f" > "$dl/$f.sha256"
        ;;
      helpers|corrupthelper|missinghelper|missingsum)
        for f in gitch-scip-index gitch-graph-watch; do
          [ "$opt:$f" = missinghelper:gitch-graph-watch ] && continue
          cp "$ROOT/$f" "$dl/$f"
          (cd "$dl" && { shasum -a 256 "$f" 2>/dev/null || sha256sum "$f"; } > "$f.sha256")
        done
        [ "$opt" != corrupthelper ] || echo '# corrupted payload after checksum' >> "$dl/gitch-graph-watch"
        [ "$opt" != missingsum ] || rm "$dl/gitch-graph-watch.sha256"
        ;;
    esac
  fi
  for f in "$dl"/*; do
    assets="$assets$sep
      {
        \"name\": \"${f##*/}\",
        \"browser_download_url\": \"https://github.com/Gitrochi/Gitrochi/releases/download/$tag/${f##*/}\"
      }"
    sep=","
  done
  while [ -e "$FAKE_WEB/rel/$n" ]; do n=$((n+1)); done
  cat > "$FAKE_WEB/rel/$n" <<EOF
  {
    "url": "https://api.github.com/repos/Gitrochi/Gitrochi/releases/$n",
    "tag_name": "$tag",
    "name": "Gitrochi ${tag#v}",
    "draft": false,
    "prerelease": $([ "$opt" = prerelease ] && echo true || echo false),
    "assets": [$assets
    ],
    "body": "notes, \"browser_download_url\": \"https://example.com/x/gitch\""
  }
EOF
  sep=""
  {
    echo "["
    while [ $n -ge 0 ]; do printf '%s' "$sep"; cat "$FAKE_WEB/rel/$n"; sep=","; n=$((n-1)); done
    echo "]"
  } > "$FAKE_WEB/$RELEASES_API"
}

gitch_ver() { sed -n 's/^GITSW_VERSION="\([^"]*\)".*/\1/p' "$1" | head -1; }
with_version() {   # $1 version $2 file to create [$3 shared] [$4 bundle] [$5 flow]; older test releases had no helper or engine markers
  if [ "${3:-}" = shared ]; then sed "s/^GITSW_VERSION=.*/GITSW_VERSION=\"$1\"/" "$GITSW_SRC"
  else sed -e "s/^GITSW_VERSION=.*/GITSW_VERSION=\"$1\"/" -e '/^GITCH_VERSION_SCHEME=/d' "$GITSW_SRC"; fi | \
    { if [ "${4:-}" = bundle ]; then cat; else sed '/^GITCH_HELPER_API=/d'; fi; } | \
    { if [ "${5:-}" = flow ]; then cat; else sed '/^GITCH_FLOW_API=/d'; fi; } > "$2"
}

flow_engine_bin() {   # The flow engine built for this machine (tests that need it are skipped without one)
  local b
  for b in "${GITCH_FLOW_TEST_BIN:-}" "$ROOT/../gitch-flow/target/debug/gitch-flow" "$ROOT/../gitch-flow/target/debug/gitch-flow.exe" \
           "$ROOT/../gitch-flow/target/release/gitch-flow" "$ROOT/../gitch-flow/target/release/gitch-flow.exe"; do
    [ -n "$b" ] && [ -x "$b" ] && { printf '%s' "$b"; return 0; }
  done
  return 1
}
flow_asset_name() { case "$(uname -s)" in Darwin) echo gitch-flow-macos ;; Linux) echo gitch-flow-linux-x64 ;; *) echo gitch-flow-windows-x64.exe ;; esac; }
flow_installed_name() { case "$(flow_asset_name)" in *.exe) echo gitch-flow.exe ;; *) echo gitch-flow ;; esac; }
only_gitch_in() { [ "$(ls -A "$1")" = gitch ] || fail "임시 파일이 남음: $(ls -A "$1" | tr '\n' ' ')"; }
only_bundle_in() { [ "$(ls -A "$1" | LC_ALL=C sort | tr '\n' ' ')" = 'gitch gitch-graph-watch gitch-scip-index ' ] || fail "배포 파일 또는 임시 파일 불일치: $(ls -A "$1" | tr '\n' ' ')"; }

standalone_copy() {   # 설치기가 두는 자리에 이 gitch 를 두고 ~/bin/gitch 를 거기로
  mkdir -p "$HOME/.local/share/gitch"
  cp "$GITSW_SRC" "$HOME/.local/share/gitch/gitch"
  mklink_ "$HOME/.local/share/gitch/gitch" "$HOME/bin/gitch"
}

test_installer_installs_release_gitch_without_running_install() {
  local d="$HOME/.local/share/gitch"
  with_version 9.9.9 "$T/new"
  mk_release v0.3.7 "$T/new"
  run sh -c 'cat "$0" | bash' "$ROOT/install.sh"; assert_ok   # README 처럼 curl … | bash
  cmp -s "$d/gitch" "$T/new" || fail "릴리스의 gitch 가 설치되지 않음"
  [ -x "$d/gitch" ] || fail "실행 권한 없음"
  only_gitch_in "$d"
  assert_out "gitch 9.9.9 (v0.3.7) 를 설치했습니다: ~/.local/share/gitch/gitch"
  assert_out "~/.local/share/gitch/gitch add"
  assert_out "~/.local/share/gitch/gitch install"
  # gitch install 은 사용자가 직접 — 설치기는 ~/.zshrc · ~/.gitconfig · ~/.claude · ~/bin 을 건드리지 않는다
  [ ! -e "$RC_FILE" ] || fail "~/.zshrc 를 바꿈"
  [ -z "$(git config --global --get-regexp '^hook\.gitsw-')" ] || fail "전역 검사 훅을 설치함"
  [ -z "$(ls -A "$HOME/.claude")" ] || fail "~/.claude 를 바꿈"
  [ "$(resolve_path "$HOME/bin/gitch")" = "$(resolve_path "$GITSW_SRC")" ] || fail "~/bin/gitch 를 바꿈"
  # 계정이 있으면 add 는 빼고 안내
  mk_config
  run bash "$ROOT/install.sh"; assert_ok; assert_out "이미 최신입니다: gitch 9.9.9 (v0.3.7)"
  assert_no_out "gitch add"; assert_out "~/.local/share/gitch/gitch install"
  [ ! -e "$RC_FILE" ] && [ -z "$(git config --global --get-regexp '^hook\.gitsw-')" ] || fail "계정이 있다고 gitch install 을 실행함"
  # 이미 ~/bin/gitch 가 이 파일이면 바로 쓰인다
  mklink_ "$d/gitch" "$HOME/bin/gitch"
  run bash "$ROOT/install.sh"; assert_ok; assert_out "바로 쓰입니다"; assert_no_out "다음은 터미널에서 직접"
}

test_installer_refuses_to_overwrite_other_files() {
  local d="$HOME/.local/share/gitch"
  with_version 9.9.9 "$T/new"
  mk_release v0.3.7 "$T/new"
  mkdir -p "$d"; echo "my notes" > "$d/gitch"
  run bash "$ROOT/install.sh"; assert_fail; assert_out "gitch 가 아닌 파일"
  assert_eq "$(cat "$d/gitch")" "my notes" "gitch 가 아닌 파일을 덮어씀"
  if mac_only; then   # Git Bash 의 ln -s 는 링크 대신 복사본을 만든다
    rm "$d/gitch"; ln -s "$GITSW_SRC" "$d/gitch"
    run bash "$ROOT/install.sh"; assert_fail; assert_out "링크"
    [ -L "$d/gitch" ] || fail "링크를 덮어씀"
  fi
  rm "$d/gitch"; mkdir "$d/gitch"
  run bash "$ROOT/install.sh"; assert_fail; assert_out "gitch 가 아닌 파일"
  [ -d "$d/gitch" ] || fail "폴더를 덮어씀"
  [ ! -e "$FAKE_WEB/log" ] || fail "덮어쓸 수 없는데 받음: $(cat "$FAKE_WEB/log")"
}

test_installer_checks_sha256_and_replaces_older_gitch() {
  local d="$HOME/.local/share/gitch"
  mkdir -p "$d"; with_version 2.0.0 "$d/gitch"
  with_version 9.9.9 "$T/new"
  mk_release v0.3.7 "$T/new" badsum
  run bash "$ROOT/install.sh"; assert_fail; assert_out "SHA-256"
  assert_eq "$(gitch_ver "$d/gitch")" 2.0.0 "SHA-256 이 틀렸는데 바꿈"
  only_gitch_in "$d"
  mk_release v0.3.8 "$T/new"
  run bash "$ROOT/install.sh"; assert_ok; assert_out "gitch 2.0.0 → 9.9.9 (v0.3.8)"
  cmp -s "$d/gitch" "$T/new" || fail "바뀌지 않음"
  only_gitch_in "$d"
  echo '<html>Not Found</html>' > "$T/html"
  mk_release v0.3.9 "$T/html"
  run bash "$ROOT/install.sh"; assert_fail; assert_out "gitch 가 아닙니다"
  cmp -s "$d/gitch" "$T/new" || fail "gitch 가 아닌 파일로 바꿈"
  only_gitch_in "$d"
}

test_installer_picks_newest_release_with_gitch() {
  run bash "$ROOT/install.sh"; assert_fail; assert_out "릴리스 목록을 받지 못했습니다"
  mk_release v0.3.6 -
  run bash "$ROOT/install.sh"; assert_fail; assert_out "gitch 가 든 릴리스가 아직 없습니다"
  [ ! -e "$HOME/.local/share/gitch/gitch" ] || fail "릴리스가 없는데 설치함"
  with_version 9.9.9 "$T/new"; with_version 9.9.10 "$T/pre"
  mk_release v0.3.7 "$T/new"
  mk_release v0.3.8 -                    # Windows 만 고친 릴리스
  mk_release v0.3.9 "$T/pre" prerelease
  assert_json "$(cat "$FAKE_WEB/$RELEASES_API")" "가짜 릴리스 목록이 JSON 이 아님"
  run bash "$ROOT/install.sh"; assert_ok; assert_out "gitch 9.9.9 (v0.3.7)"
  cmp -s "$HOME/.local/share/gitch/gitch" "$T/new" || fail "gitch 가 든 가장 새 정식 릴리스가 아님"
}

test_self_update_replaces_standalone_copy() {
  local d="$HOME/.local/share/gitch" cur
  cur=$(gitch_ver "$GITSW_SRC")
  standalone_copy
  git init -q "$HOME"   # 홈 폴더를 git 으로 관리해도 gitch 를 올리지 않았으면 따로 받은 것
  with_version 0.99.1 "$T/new" shared; with_version 0.99.3 "$T/pre" shared
  mk_release v0.99.1 "$T/new"
  mk_release v0.99.2 -                    # Windows 만 고친 릴리스
  mk_release v0.99.3 "$T/pre" prerelease
  run gitch self-update; assert_ok; assert_out "gitch $cur → 0.99.1 (v0.99.1): ~/.local/share/gitch/gitch"
  cmp -s "$d/gitch" "$T/new" || fail "바뀌지 않음"
  [ -x "$d/gitch" ] || fail "실행 권한 없음"
  is_linkish "$HOME/bin/gitch" || fail "~/bin/gitch 링크가 사라짐"
  only_gitch_in "$d"
  run gitch version; assert_out "gitch 0.99.1"
  run gitch self-update; assert_ok; assert_out "이미 최신입니다: gitch 0.99.1 (v0.99.1)"
  grep -q '"event":"self-update"' "$HOME/.local/state/gitsw/actions.jsonl" || fail "작업 기록 없음"
}

test_self_update_refuses_bad_or_older_release() {
  local d="$HOME/.local/share/gitch"
  standalone_copy
  with_version 9.9.9 "$T/new"
  mk_release v0.3.7 "$T/new" badsum
  run gitch self-update; assert_fail; assert_out "SHA-256"
  cmp -s "$d/gitch" "$GITSW_SRC" || fail "SHA-256 이 틀렸는데 바꿈"
  only_gitch_in "$d"
  with_version 0.0.1 "$T/old" shared
  mk_release v0.0.1 "$T/old"
  run gitch self-update; assert_ok; assert_out "그대로 뒀습니다"
  cmp -s "$d/gitch" "$GITSW_SRC" || fail "더 낮은 버전으로 바꿈"
  echo '<html>Not Found</html>' > "$T/html"
  mk_release v0.3.9 "$T/html"
  run gitch self-update; assert_fail; assert_out "gitch 가 아닙니다"
  cmp -s "$d/gitch" "$GITSW_SRC" || fail "gitch 가 아닌 파일로 바꿈"
  only_gitch_in "$d"
}

test_shared_version_update_scheme_and_release_tag() {
  local d="$HOME/.local/share/gitch"
  standalone_copy
  with_version 3.2.1 "$T/legacy"
  mk_release v0.3.9 "$T/legacy"
  run gitch self-update; assert_ok; assert_out "이전 독립 CLI 버전 방식"
  cmp -s "$d/gitch" "$GITSW_SRC" || fail "예전 CLI 번호로 돌아감"
  with_version 0.99.1 "$T/new" shared
  mk_release v0.99.2 "$T/new"
  run gitch self-update; assert_fail; assert_out "릴리스 태그"
  cmp -s "$d/gitch" "$GITSW_SRC" || fail "태그와 버전이 다른 파일로 바꿈"
  run bash "$ROOT/install.sh"; assert_fail; assert_out "릴리스 태그"
  cmp -s "$d/gitch" "$GITSW_SRC" || fail "설치기가 태그와 다른 버전을 설치함"
}

test_legacy_version_installer_migrates_to_shared_version() {
  local d="$HOME/.local/share/gitch"
  mkdir -p "$d"; with_version 3.2.1 "$d/gitch"
  with_version 0.99.1 "$T/new" shared
  mk_release v0.99.1 "$T/new"
  run bash "$ROOT/install.sh"; assert_ok; assert_out "gitch 3.2.1 → 0.99.1"
  cmp -s "$d/gitch" "$T/new" || fail "독립 CLI에서 앱 공통 버전으로 옮기지 못함"
  # 새 업데이트 로직도 이전 번호와 새 번호를 숫자로만 비교하지 않는다.
  with_version 3.2.1 "$d/gitch"
  mklink_ "$d/gitch" "$HOME/bin/gitch"
  run gitch self-update; assert_ok; assert_out "gitch 3.2.1 → 0.99.1"
  cmp -s "$d/gitch" "$T/new" || fail "새 버전 방식으로 옮기지 못함"
}

test_self_update_leaves_app_and_repo_copies() {
  local app="$T/Gitrochi.app/Contents/Resources" repo="$T/checkout"
  with_version 9.9.9 "$T/new"
  mk_release v0.3.7 "$T/new"
  mkdir -p "$app" "$repo/tools/gitch"
  cp "$GITSW_SRC" "$app/gitch"
  run "$app/gitch" self-update; assert_ok; assert_out "앱과 함께 업데이트"
  cmp -s "$app/gitch" "$GITSW_SRC" || fail "앱에 든 gitch 를 바꿈"
  # 저장소에 든 gitch 는 그 저장소로 바뀐다 (진짜 tools/gitch/gitch 대신 임시 저장소로 확인)
  git init -q "$repo"; cp "$GITSW_SRC" "$repo/tools/gitch/gitch"; git -C "$repo" add tools/gitch/gitch
  run "$repo/tools/gitch/gitch" self-update; assert_ok; assert_out "앱과 함께 업데이트"
  cmp -s "$repo/tools/gitch/gitch" "$GITSW_SRC" || fail "저장소의 gitch 를 바꿈"
  [ ! -e "$FAKE_WEB/log" ] || fail "릴리스를 받음: $(cat "$FAKE_WEB/log")"
}

test_installer_installs_verified_helper_bundle() {
  local d="$HOME/.local/share/gitch" helper
  with_version 0.99.1 "$T/new" shared bundle
  mk_release v0.99.1 "$T/new" helpers
  run bash "$ROOT/install.sh"; assert_ok
  cmp -s "$d/gitch" "$T/new" || fail 'bundle CLI mismatch'
  for helper in gitch-scip-index gitch-graph-watch; do
    cmp -s "$d/$helper" "$ROOT/$helper" || fail "helper mismatch: $helper"
    [ -x "$d/$helper" ] || fail "helper executable: $helper"
    grep -F "releases/download/v0.99.1/$helper.sha256" "$FAKE_WEB/log" >/dev/null || fail 'helper came from another release'
  done
  only_bundle_in "$d"
  # 같은 CLI여도 도우미가 사라졌으면 self-update가 검증해서 다시 둔다.
  mklink_ "$d/gitch" "$HOME/bin/gitch"
  rm "$d/gitch-graph-watch"
  run gitch self-update; assert_ok; assert_out '이미 최신입니다'
  cmp -s "$d/gitch-graph-watch" "$ROOT/gitch-graph-watch" || fail 'same-version helper repair'
  only_bundle_in "$d"
}

test_helper_checksum_failure_keeps_entire_installed_bundle() {
  local d="$HOME/.local/share/gitch" helper
  standalone_copy
  cp "$d/gitch" "$T/old-cli"
  for helper in gitch-scip-index gitch-graph-watch; do
    printf '#!/usr/bin/env python3\n# previous helper\n' > "$d/$helper"
    cp "$d/$helper" "$T/old-$helper"
  done
  with_version 0.99.1 "$T/new" shared bundle
  mk_release v0.99.1 "$T/new" corrupthelper
  run gitch self-update; assert_fail; assert_out 'SHA-256'; assert_out 'gitch-graph-watch.sha256'
  cmp -s "$d/gitch" "$T/old-cli" || fail 'CLI promoted before all helpers verified'
  for helper in gitch-scip-index gitch-graph-watch; do cmp -s "$d/$helper" "$T/old-$helper" || fail 'helper partially promoted'; done
  only_bundle_in "$d"
  run bash "$ROOT/install.sh"; assert_fail; assert_out 'SHA-256'
  cmp -s "$d/gitch" "$T/old-cli" || fail 'installer CLI partially promoted'
  for helper in gitch-scip-index gitch-graph-watch; do cmp -s "$d/$helper" "$T/old-$helper" || fail 'installer helper partially promoted'; done
  only_bundle_in "$d"
}

test_new_bundle_requires_helpers_historical_release_still_installs() {
  local d="$HOME/.local/share/gitch"
  with_version 0.99.1 "$T/new" shared bundle
  mk_release v0.99.1 "$T/new" missinghelper
  run bash "$ROOT/install.sh"; assert_fail; assert_out '필수 도우미'
  [ ! -e "$d/gitch" ] && [ ! -e "$d/gitch-scip-index" ] || fail 'missing mandatory helper installed partial bundle'
  with_version 0.99.2 "$T/historical" shared
  mk_release v0.99.2 "$T/historical"
  run bash "$ROOT/install.sh"; assert_ok; assert_out '이전 릴리스에는 선택적 그래프 도우미가 없습니다'
  cmp -s "$d/gitch" "$T/historical" || fail 'historical CLI not installed'
  only_gitch_in "$d"
  standalone_copy
  run gitch self-update; assert_ok; assert_out '이전 릴리스에는 선택적 그래프 도우미가 없습니다'
  cmp -s "$d/gitch" "$T/historical" || fail 'historical update blocked'
  only_gitch_in "$d"
}

test_helper_missing_checksum_prevents_bundle_installation() {
  local d="$HOME/.local/share/gitch"
  standalone_copy
  cp "$d/gitch" "$T/old-cli"
  with_version 0.99.1 "$T/new" shared bundle
  mk_release v0.99.1 "$T/new" missingsum
  run gitch self-update; assert_fail; assert_out '도우미 체크섬'
  cmp -s "$d/gitch" "$T/old-cli" || fail 'missing helper checksum replaced CLI'
  only_gitch_in "$d"
  run bash "$ROOT/install.sh"; assert_fail; assert_out '도우미 체크섬'
  cmp -s "$d/gitch" "$T/old-cli" || fail 'installer ignored helper checksum'
  only_gitch_in "$d"
}

test_flow_engine_is_installed_and_updated_with_the_bundle() {
  local d="$HOME/.local/share/gitch" name
  FLOW_ENGINE_BIN=$(flow_engine_bin) || { echo "skipped: build gitch-flow first (cd tools/gitch-flow && cargo build)"; return 0; }
  name=$(flow_installed_name)
  with_version 0.99.1 "$T/new" shared bundle flow
  mk_release v0.99.1 "$T/new" engine
  run bash "$ROOT/install.sh"; assert_ok
  cmp -s "$d/$name" "$FLOW_ENGINE_BIN" || fail 'engine mismatch'
  [ -x "$d/$name" ] || fail 'engine not executable'
  grep -F "releases/download/v0.99.1/$(flow_asset_name).sha256" "$FAKE_WEB/log" >/dev/null || fail 'engine came from another release'
  # gitch finds the engine it put next to itself.
  run env -u GITCH_FLOW "$d/gitch" flow version; assert_ok; assert_out 'gitch-flow'
  # With the same CLI but the engine gone, self-update verifies it and puts it back.
  mklink_ "$d/gitch" "$HOME/bin/gitch"
  rm "$d/$name"
  run gitch self-update; assert_ok
  cmp -s "$d/$name" "$FLOW_ENGINE_BIN" || fail 'same-version engine repair'
}

test_flow_engine_checksum_or_broken_binary_keeps_the_installed_bundle() {
  local d="$HOME/.local/share/gitch"
  FLOW_ENGINE_BIN=$(flow_engine_bin) || { echo "skipped: build gitch-flow first (cd tools/gitch-flow && cargo build)"; return 0; }
  standalone_copy
  cp "$d/gitch" "$T/old-cli"
  with_version 0.99.1 "$T/new" shared bundle flow
  mk_release v0.99.1 "$T/new" badengine
  run gitch self-update; assert_fail; assert_out 'SHA-256'
  cmp -s "$d/gitch" "$T/old-cli" || fail 'CLI promoted before the engine was verified'
  [ ! -e "$d/$(flow_installed_name)" ] || fail 'engine with a bad checksum installed'
  with_version 0.99.2 "$T/broken" shared bundle flow
  mk_release v0.99.2 "$T/broken" brokenengine
  run bash "$ROOT/install.sh"; assert_fail; assert_out '흐름 엔진'
  cmp -s "$d/gitch" "$T/old-cli" || fail 'installer promoted a bundle with a broken engine'
}
