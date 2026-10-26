#!/bin/bash
# ==========================================================
#  gitch 설치 — Gitrochi 앱 없이 CLI 만 (macOS 기본 bash 3.2 · Windows 의 Git Bash + curl)
#    curl -fsSL https://raw.githubusercontent.com/Gitrochi/Gitrochi/main/tools/gitch/install.sh | bash
#  릴리스의 gitch 를 gitch.sha256 과 맞춰 본 뒤 ~/.local/share/gitch/gitch 에 둔다(같은 폴더의 임시 파일 → mv).
#  gitch install 은 하지 않는다 — ~/.zshrc, ~/.gitconfig, ~/.claude, ~/.codex 를 바꾸므로 할 일만 보여 준다.
#  업데이트: gitch self-update (같은 방법으로 받는다)
# ==========================================================

# shellcheck disable=SC2088  # 화면 표시용 ~ 는 일부러 펼치지 않음
REPO="Gitrochi/Gitrochi"
DEST_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/gitch"
DEST="$DEST_DIR/gitch"
CFG="${GITSW_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/gitsw/config}"
TMP=""
case "${OSTYPE:-}" in msys*|cygwin*) RC="~/.bashrc" ;; *) RC="~/.zshrc" ;; esac

# 릴리스 목록(GitHub API)에서 초안·시험판이 아니고 gitch 가 든 첫(가장 새) 릴리스 → "태그 주소"
# Windows 만 고친 릴리스가 최신일 수 있어서 releases/latest 를 쓰지 않는다. gitch 의 self-update 와 같은 내용.
RELEASE_AWK='
/^[[:space:]]*"tag_name":/ { tag = $0; sub(/^[^:]*:[[:space:]]*"/, "", tag); sub(/".*/, "", tag); skip = 0 }
/^[[:space:]]*"(draft|prerelease)":[[:space:]]*true/ { skip = 1 }
/^[[:space:]]*"browser_download_url":.*\/gitch"/ && !skip { url = $0; sub(/^[^:]*:[[:space:]]*"/, "", url); sub(/".*/, "", url); print tag, url; exit }'

say() { printf '%s\n' "$*"; }
die() { printf '%s\n' "$*" >&2; exit 1; }
tilde() { case "$1" in "$HOME"/*) printf '%s' "~/${1#"$HOME"/}" ;; *) printf '%s' "$1" ;; esac; }
link_target() {   # 심볼릭 링크, 또는 Windows 에서 gitch install 이 만드는 연결 스크립트('# gitch-link: <경로>')가 가리키는 곳
  if [ -L "$1" ]; then readlink "$1"; return 0; fi
  [ -f "$1" ] && [ "$(head -1 "$1" 2>/dev/null)" = "#!/bin/sh" ] || return 1
  sed -n '2s/^# gitch-link: //p' "$1" | grep .
}
resolve_link() {   # 심볼릭 링크(연결 스크립트도)를 끝까지 따라간 실제 경로
  local p="$1" t
  while t=$(link_target "$p"); do
    case "$t" in /*) p="$t" ;; *) p="$(dirname "$p")/$t" ;; esac
  done
  printf '%s' "$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)/$(basename "$p")"
}
curl_get() { curl -fsSL --connect-timeout 15 --max-time 120 "$@"; }
sha256_of() { { shasum -a 256 "$1" 2>/dev/null || sha256sum "$1"; } | awk '{ print $1 }'; }
gitch_version() { sed -n 's/^GITSW_VERSION="\([^"]*\)".*/\1/p' "$1" 2>/dev/null | head -1; }

# Helper scripts come only from the selected gitch release directory and need their own matching checksum.
# Every download is verified before any installed file is promoted.
release_stage_helpers() {   # $1 staging directory $2 selected gitch URL $3 helper API (empty = historical optional release)
  local stage=$1 base=${2%/gitch} api=$3 name want have missing=""
  STAGED_HELPERS=""
  case "$api" in ""|1) ;; *) die "알 수 없는 그래프 도우미 배포 방식: $api" ;; esac
  for name in gitch-scip-index gitch-graph-watch; do
    if ! curl_get -o "$stage/$name" "$base/$name" 2>/dev/null; then
      [ -z "$api" ] || die "릴리스의 필수 도우미를 받지 못했습니다: $base/$name (설치 파일은 바꾸지 않았습니다)"
      rm -f "$stage/$name"; missing=1; continue
    fi
    curl_get -o "$stage/$name.sha256" "$base/$name.sha256" || die "도우미 체크섬을 받지 못했습니다: $name.sha256 (설치 파일은 바꾸지 않았습니다)"
    want=$(awk -v name="$name" '$2 == name || $2 == "*" name { print $1; exit }' "$stage/$name.sha256")
    have=$(sha256_of "$stage/$name")
    [ -n "$want" ] && [ "$want" = "$have" ] || die "SHA-256 이 $name.sha256 과 맞지 않아 설치 파일을 바꾸지 않았습니다."
    [ "$(head -1 "$stage/$name")" = '#!/usr/bin/env python3' ] || die "받은 파일이 그래프 도우미가 아닙니다: $name"
    if command -v python3 >/dev/null 2>&1; then
      python3 -c 'import ast,sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "$stage/$name" 2>/dev/null || die "그래프 도우미 문법이 잘못되어 설치하지 않았습니다: $name"
    fi
    STAGED_HELPERS="$STAGED_HELPERS $name"
  done
  [ -z "$missing" ] || say "이전 릴리스에는 선택적 그래프 도우미가 없습니다. 기본 CLI는 설치하며 정밀 분석·자동 갱신은 도우미가 포함된 최신 Gitrochi 배포본에서 사용하세요."
}
# The flow engine is a native binary per OS. It comes from the same release directory, needs its own checksum,
# must run, and is promoted together with the helpers (as gitch-flow or gitch-flow.exe beside gitch).
flow_asset() {   # 이 컴퓨터용 흐름 엔진 배포 파일 이름(배포하지 않는 운영체제면 빈 값)
  case "$(uname -s 2>/dev/null)" in
    Darwin) printf 'gitch-flow-macos' ;;
    Linux) case "$(uname -m 2>/dev/null)" in x86_64|amd64) printf 'gitch-flow-linux-x64' ;; esac ;;
    MINGW*|MSYS*|CYGWIN*) printf 'gitch-flow-windows-x64.exe' ;;
  esac
}
release_stage_engine() {   # $1 staging directory $2 selected gitch URL $3 flow API (empty = release without the engine)
  local stage=$1 base=${2%/gitch} api=$3 asset name want have
  [ -n "$api" ] || return 0
  asset=$(flow_asset)
  if [ -z "$asset" ]; then say "이 운영체제용 흐름 엔진은 배포하지 않습니다 — gitch flow · gitch test 는 직접 빌드한 gitch-flow 가 있어야 합니다."; return 0; fi
  case "$asset" in *.exe) name=gitch-flow.exe ;; *) name=gitch-flow ;; esac
  curl_get -o "$stage/$name" "$base/$asset" || die "흐름 엔진을 받지 못했습니다: $base/$asset (설치 파일은 바꾸지 않았습니다)"
  curl_get -o "$stage/$asset.sha256" "$base/$asset.sha256" || die "흐름 엔진 체크섬을 받지 못했습니다: $asset.sha256 (설치 파일은 바꾸지 않았습니다)"
  want=$(awk -v name="$asset" '$2 == name || $2 == "*" name { print $1; exit }' "$stage/$asset.sha256")
  have=$(sha256_of "$stage/$name")
  [ -n "$want" ] && [ "$want" = "$have" ] || die "SHA-256 이 $asset.sha256 과 맞지 않아 설치 파일을 바꾸지 않았습니다."
  chmod 755 "$stage/$name" || die "실행 권한을 설정하지 못했습니다: $name"
  "$stage/$name" version --json 2>/dev/null | grep -q '"flowApi"' || die "받은 흐름 엔진이 이 컴퓨터에서 돌지 않아 설치하지 않았습니다: $asset"
  STAGED_HELPERS="$STAGED_HELPERS $name"
}
release_promote() {   # $1 staging directory $2 destination directory $3 CLI destination basename
  local stage=$1 dir=$2 cli=$3 name rollback_name promoted="" existed=""
  mkdir "$stage/rollback" || die "업데이트 복구 폴더를 만들지 못했습니다."
  for name in $STAGED_HELPERS "$cli"; do
    [ ! -L "$dir/$name" ] && { [ ! -e "$dir/$name" ] || [ -f "$dir/$name" ]; } || die "도우미/CLI 대상이 링크나 폴더라 덮어쓰지 않았습니다: $dir/$name"
    if [ -f "$dir/$name" ]; then cp -p "$dir/$name" "$stage/rollback/$name" || die "기존 파일을 보존하지 못했습니다: $name"; existed="$existed $name"; fi
    if [ "$name" = "$cli" ]; then chmod 755 "$stage/gitch"; else chmod 755 "$stage/$name"; fi || die "실행 권한을 설정하지 못했습니다: $name"
  done
  # Helpers first, CLI last. All checksums and rollback copies already passed.
  for name in $STAGED_HELPERS "$cli"; do
    if { [ "$name" = "$cli" ] && mv -f "$stage/gitch" "$dir/$name"; } || { [ "$name" != "$cli" ] && mv -f "$stage/$name" "$dir/$name"; }; then
      promoted="$promoted $name"
    else
      for rollback_name in $promoted; do
        case " $existed " in *" $rollback_name "*) mv -f "$stage/rollback/$rollback_name" "$dir/$rollback_name" ;; *) rm -f "$dir/$rollback_name" ;; esac
      done
      die "설치 파일 교체에 실패해 이전 파일로 되돌렸습니다."
    fi
  done
}

main() {
  local json tag url want have old="" new d scheme helper_api
  command -v curl >/dev/null 2>&1 || die "curl 이 필요합니다."
  # 그 자리에 다른 것이 있으면 건드리지 않는다
  [ -L "$DEST" ] && die "$(tilde "$DEST") 가 링크(→ $(tilde "$(resolve_link "$DEST")"))라 덮어쓰지 않았습니다. 지우고 다시 실행하세요."
  if [ -e "$DEST" ]; then
    old=$(gitch_version "$DEST")
    [ -f "$DEST" ] && [ -n "$old" ] || die "$(tilde "$DEST") 에 gitch 가 아닌 파일이 있어 덮어쓰지 않았습니다. 옮기거나 지우고 다시 실행하세요."
  fi

  json=$(curl_get -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/$REPO/releases?per_page=20") \
    || die "릴리스 목록을 받지 못했습니다: https://github.com/$REPO/releases"
  read -r tag url <<< "$(printf '%s\n' "$json" | tr ',' '\n' | awk "$RELEASE_AWK")"
  [ -n "$url" ] || die "gitch 가 든 릴리스가 아직 없습니다: https://github.com/$REPO/releases"

  mkdir -p "$DEST_DIR" || die "폴더를 만들지 못했습니다: $(tilde "$DEST_DIR")"
  TMP=$(mktemp -d "$DEST_DIR/.gitch-install.XXXXXX") || die "임시 파일을 만들지 못했습니다: $(tilde "$DEST_DIR")"
  trap 'rm -rf "$TMP"' EXIT
  say "gitch 받는 중: $url"
  curl_get -o "$TMP/gitch" "$url" && curl_get -o "$TMP/gitch.sha256" "$url.sha256" || die "받지 못했습니다: $url"
  want=$(awk '$2 == "gitch" || $2 == "*gitch" { print $1; exit }' "$TMP/gitch.sha256")
  have=$(sha256_of "$TMP/gitch")
  [ -n "$want" ] && [ "$want" = "$have" ] || die "SHA-256 이 gitch.sha256 과 맞지 않아 설치하지 않았습니다 ($tag)"
  new=$(gitch_version "$TMP/gitch")
  [ -n "$new" ] && "${BASH:-bash}" -n "$TMP/gitch" 2>/dev/null || die "받은 파일이 gitch 가 아닙니다: $url"
  scheme=$(sed -n 's/^GITCH_VERSION_SCHEME="\([^"]*\)".*/\1/p' "$TMP/gitch" | head -1)
  if [ "$scheme" = gitrochi ]; then
    [ "$new" = "${tag#v}" ] || die "릴리스 태그($tag)와 gitch 버전($new)이 달라 설치하지 않았습니다."
  elif [ -n "$scheme" ]; then
    die "알 수 없는 gitch 버전 방식($scheme)이라 설치하지 않았습니다."
  fi

  helper_api=$(sed -n 's/^GITCH_HELPER_API="\([^"]*\)".*/\1/p' "$TMP/gitch" | head -1)
  release_stage_helpers "$TMP" "$url" "$helper_api"
  release_stage_engine "$TMP" "$url" "$(sed -n 's/^GITCH_FLOW_API="\([^"]*\)".*/\1/p' "$TMP/gitch" | head -1)"
  if [ -n "$old" ] && [ "$have" = "$(sha256_of "$DEST")" ]; then
    release_promote "$TMP" "$DEST_DIR" gitch
    say "✔ 이미 최신입니다: gitch $new ($tag) — $(tilde "$DEST")"
  else
    release_promote "$TMP" "$DEST_DIR" gitch
    if [ -n "$old" ]; then say "✔ gitch $old → $new ($tag): $(tilde "$DEST")"
    else say "✔ gitch $new ($tag) 를 설치했습니다: $(tilde "$DEST")"; fi
  fi

  say ""
  if [ "$(resolve_link "$HOME/bin/gitch")" = "$(resolve_link "$DEST")" ]; then
    say "~/bin/gitch 가 이 파일을 가리켜 바로 쓰입니다. AI 규칙·스킬·검사 훅도 새 버전으로 쓰려면: gitch install"
  else
    d=$(tilde "$DEST")
    say "다음은 터미널에서 직접 하세요. gitch install 은 $RC, ~/.gitconfig, ~/.claude, ~/.codex 를 바꿉니다(바꾸기 전 파일은 백업)."
    [ -f "$CFG" ] || say "  $d add        # 계정 추가: 아이디·이메일·서버를 묻고 SSH 키를 만든다"
    say "  $d install    # ~/bin/gitch 연결, 자동 규칙, 검사 훅, AI 연동, 터미널 연동"
    say "  source $RC"

  fi
  say "업데이트: gitch self-update"
}

main "$@"
