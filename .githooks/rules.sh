#!/bin/sh
# Gitrochi Git rules — explained in docs/git-workflow.md.
#   rules.sh message <파일>        커밋 메시지(commit-msg 훅)
#   rules.sh staged                스테이지한 파일(pre-commit 훅)
#   rules.sh range <base> <head>   그 사이의 커밋과 바뀐 파일(GitHub Actions)
#   rules.sh push                  푸시할 ref(pre-push 훅, 표준 입력): main 으로는 보내지 않는다
# POSIX sh 로 쓴다(맥 · 리눅스 · Windows 의 Git Bash 에서 같이 돈다).
# 기여자가 여러 나라 사람이라 알림은 영어로 낸다.
set -u

MAX_SUBJECT=100
MAX_BYTES=2097152
fail=0
err() {
  printf '✗ %s\n' "$*" >&2
  fail=1
}

# 글자 수를 셀 UTF-8 로캘(한글 한 글자 = 1)
UTF8=C
for l in C.UTF-8 en_US.UTF-8 UTF-8; do
  if [ "$(printf '가' | LC_ALL=$l wc -m 2>/dev/null | tr -d ' ')" = 1 ]; then
    UTF8=$l
    break
  fi
done
chars() { printf '%s' "$1" | LC_ALL=$UTF8 wc -m | tr -d ' '; }

# 영어 글로 치는 ASCII 밖 글자(바이트로 비교): 악센트 붙은 라틴 문자 À–ſ, ·, 일반 문장 부호(— – ‘ ’ “ ” …), 화살표
CONT=$(printf '\200-\277')
LATIN=$(printf '\303\304\305')
MIDDOT=$(printf '\302\267')
PUNCT=$(printf '\342\200')
ARROW=$(printf '\342\206')
TAB=$(printf '\t')

# 영어가 아닌 글자가 남은 줄 번호(없으면 빈 글). `코드 조각` 안과 트레일러(Co-Authored-By: 이름 …)는 뺀다.
non_english_lines() {
  printf '%s\n' "$1" |
    LC_ALL=C sed -E -e 's/^[A-Za-z]+(-[A-Za-z]+)+: .*//' -e 's/`[^`]*`//g' \
      -e "s/[$LATIN][$CONT]//g" -e "s/$MIDDOT//g" -e "s/$PUNCT[$CONT]//g" -e "s/$ARROW[$CONT]//g" |
    LC_ALL=C grep -n "[^$TAB -~]" | cut -d: -f1 | tr '\n' ',' | sed 's/,$//'
}

# $1 = 메시지 파일, $2 = 알림에 붙일 커밋(없으면 지금 쓰는 메시지)
check_message() {
  at=${2:+"$2 "}
  # git 이 지우는 부분(주석 줄, 가위 줄 아래, 앞쪽 빈 줄)은 빼고 본다
  msg=$(sed -e '/^# -* >8 -*$/,$d' -e '/^#/d' "$1" | sed '/./,$!d')
  subject=$(printf '%s\n' "$msg" | sed -n 1p)
  second=$(printf '%s\n' "$msg" | sed -n 2p)
  case $subject in
    "Merge "* | "Revert \""*) return ;; # git 이 만든 제목
  esac
  if [ -z "$subject" ]; then
    err "${at}Empty commit subject"
    return
  fi
  lines=$(non_english_lines "$msg")
  [ -z "$lines" ] || err "${at}Write the commit message in English (line ${lines}) — quote other languages in \`backticks\`"
  case $subject in
    "Release "[0-9]*) ;; # 버전 커밋은 요약이 길다
    *) [ "$(chars "$subject")" -le $MAX_SUBJECT ] || err "${at}Keep the subject within ${MAX_SUBJECT} characters: $subject" ;;
  esac
  case $subject in
    *. | *" ") err "${at}No period or space at the end of the subject: $subject" ;;
  esac
  case $subject in
    "fixup! "* | "squash! "* | "amend! "*) err "${at}Squash fixup commits before pushing (git rebase -i --autosquash origin/main): $subject" ;;
  esac
  case $(printf '%s' "$subject" | tr 'A-Z' 'a-z') in
    wip | wip:* | "wip "* | tmp | temp | test | tests | fix | fixes | update | updates | changes | misc | stuff | minor | . | ...)
      err "${at}Say what the commit does: $subject" ;;
  esac
  area=${subject%%:*}
  summary=$subject
  if [ "$area" != "$subject" ]; then
    rest=${subject#*:}
    case $rest in
      " "?*) summary=${rest# } ;;
      //*) ;; # 주소(https://…)
      *) err "${at}Use \"Area: Summary\" with one space after the colon: $subject" ;;
    esac
    [ -n "$area" ] || err "${at}Put the area before the colon: $subject"
  else
    # the area is required (Graph, Sidebar, Terminal, macOS, Windows …); only the version commit goes without
    case $subject in
      "Release "[0-9]*) ;;
      *) err "${at}Start the subject with an area and a colon (\"Area: Summary\", e.g. Graph: Show avatars): $subject" ;;
    esac
  fi
  # 명령형: 「Add …」(과거형·3인칭·진행형 아님)
  case $(printf '%s' "${summary%% *}" | tr 'A-Z' 'a-z') in
    added | fixed | updated | changed | removed | renamed | moved | improved | refactored | implemented | created | deleted | made | \
      adds | fixes | updates | changes | removes | renames | moves | improves | makes | \
      adding | fixing | updating | changing | removing | making)
      err "${at}Use the imperative mood (\"Add …\", \"Fix …\"): $subject" ;;
  esac
  [ -z "$second" ] || err "${at}Leave the second line blank, then write the body"
}

SECRETS='-----BEGIN [A-Z ]*PRIVATE KEY-----|untrusted comment: (rsign|minisign) encrypted secret key|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{40,}|glpat-[A-Za-z0-9_-]{20}|sk-ant-[A-Za-z0-9_-]{20,}|xox[abpr]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}'
# 경로가 시작하는 곳의 /Users/<이름> · /home/<이름> · C:\Users\<이름> (주소 https://…/home/… 는 빼고)
HOME_PATH='(^|[^A-Za-z0-9._~-])(/Users/|/home/)[A-Za-z0-9._-]+|[Cc]:(\\\\|\\|/)+Users(\\\\|\\|/)+[A-Za-z0-9._-]+'

# $1 = 경로, $2 = 커밋(비우면 스테이지한 내용)
check_file() {
  p=$1
  if [ -n "$2" ]; then spec="$2:$p"; else spec=":$p"; fi
  case /$p in
    */.DS_Store | */node_modules/* | */dist/* | */target/* | */.build/* | *.key | *.pem | *.p12 | *.pfx | */.env | */.env.*)
      err "$p: Don't commit build output, dependencies, keys or env files"
      return ;;
  esac
  size=$(git cat-file -s "$spec" 2>/dev/null) || return
  [ "$size" -le $MAX_BYTES ] || err "$p: File is larger than 2 MB ($size bytes)"
  # 비밀값은 줄 번호만 알린다(값을 로그에 다시 찍지 않게)
  lines=$(git cat-file -p "$spec" | grep -nIoE -e "$SECRETS" | cut -d: -f1 | tr '\n' ',' | sed 's/,$//')
  [ -z "$lines" ] || err "$p: Looks like a secret (key or token) on line ${lines} — remove it, and revoke it if it was ever pushed"
  case $p in
    macos/Vendor/*) return ;; # 가져온 외부 코드
  esac
  git cat-file -p "$spec" | grep -nIoE -e "$HOME_PATH" | while IFS= read -r hit; do
    name=$(printf '%s' "$hit" | sed -E 's#.*(Users|home)[\\/]+##')
    case $name in
      ? | me | user | username | you | name | example | runner | runneradmin | Shared | Public | linuxbrew) ;; # 예시·시스템 경로
      *) printf '✗ %s:%s: Personal home path — use a placeholder such as /Users/me\n' "$p" "${hit%%:*}" >&2 && echo x ;;
    esac
  done | grep x >/dev/null && fail=1
  return 0
}

# 빈 줄로 끝나는 파일·줄 끝 공백·남은 충돌 표시
check_whitespace() {
  out=$(git -c core.quotePath=false diff --check "$@" 2>&1) || {
    printf '%s\n' "$out" | sed 's/^/✗ /' >&2
    fail=1
  }
}

case ${1:-} in
  message)
    check_message "$2" ""
    ;;
  staged)
    while IFS= read -r p; do
      [ -n "$p" ] && check_file "$p" ""
    done <<EOF
$(git -c core.quotePath=false diff --cached --name-only --diff-filter=ACMR)
EOF
    check_whitespace --cached
    ;;
  range)
    base=$2
    head=$(git rev-parse "$3")
    # 새 브랜치·강제 푸시로 base 가 없으면 main 에서 갈라진 곳부터, 그것도 없으면 마지막 커밋만
    git cat-file -e "$base^{commit}" 2>/dev/null || base=$(git merge-base origin/main "$head" 2>/dev/null || echo "")
    if [ -z "$base" ] || [ "$(git rev-parse "$base")" = "$head" ]; then base=$(git rev-parse "$head^"); fi
    tmp=$(mktemp)
    for c in $(git rev-list --no-merges "$base..$head"); do
      git log -1 --format=%B "$c" >"$tmp"
      check_message "$tmp" "$(git log -1 --format=%h "$c")"
    done
    rm -f "$tmp"
    # 파일은 갈라진 곳부터 비교한다 — PR 브랜치가 main 보다 뒤처져 있어도 그 브랜치가 바꾼 것만 보게
    from=$(git merge-base "$base" "$head" 2>/dev/null || echo "$base")
    while IFS= read -r p; do
      [ -n "$p" ] && check_file "$p" "$head"
    done <<EOF
$(git -c core.quotePath=false diff --name-only --diff-filter=ACMR "$from" "$head")
EOF
    check_whitespace "$from" "$head"
    ;;
  push)
    # main 은 GitHub 에서도 막혀 있다(PR 로만). 서버까지 가기 전에 이유와 할 일을 알려 준다
    while read -r _ _ remote_ref _; do
      [ "$remote_ref" = refs/heads/main ] &&
        err "Don't push to main — push a branch and open a pull request (git switch -c feature/…; git push -u origin HEAD; gh pr create)"
    done
    ;;
  *)
    echo "usage: rules.sh message <file> | staged | range <base> <head> | push" >&2
    exit 2
    ;;
esac

if [ $fail -ne 0 ]; then
  echo "Git rules: see CONTRIBUTING.md (Git 규칙)" >&2
fi
exit $fail
