# shellcheck shell=bash
# 실제 stdout PTY에서만 사람용 화면을 검사한다. 모든 설정과 저장소는 t_setup의 임시 HOME 안에 둔다.

terminal_ui_repo() {
  mk_config
  mk_repo "$HOME/Develop/alice/terminal-ui"
  cd "$HOME/Develop/alice/terminal-ui" || fail 'terminal fixture cd'
  git config user.name alice
  git config user.email alice@example.com
  mkdir -p src tests
  printf '{"name":"terminal-ui-fixture","dependencies":{"declared":"^1.0.0"}}\n' > package.json
  printf 'export const api = 1;\n' > src/api.ts
  printf 'import { api } from "./api";\nconsole.log(api);\n' > src/app.ts
  printf 'import { api } from "../src/api";\nconsole.log(api);\n' > tests/api.test.ts
  git add package.json src tests
  git commit -q -m 'terminal fixture' || fail 'terminal fixture commit'
}

terminal_ui_run() {   # $1 terminal width, rest: command (env NAME=value gitch ... is supported)
  local width="$1"; shift
  # On Windows, Python's pty module is unavailable; the Git Bash compatibility suite covers plain output.
  [ -z "$IS_WIN" ] || return 0
  python3 - "$T/terminal-result.json" "$width" "$@" <<'PY'
import errno
import fcntl
import json
import locale
import os
import pty
import selectors
import signal
import struct
import subprocess
import sys
import termios
import time

result_path, columns, *command = sys.argv[1:]
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, int(columns), 0, 0))
environment = dict(os.environ)
for key in ("NO_COLOR", "GITCH_STYLE", "GITCH_LOGO", "GITSW_BANNER", "GITSW_COLOR", "COLUMNS", "LINES"):
    environment.pop(key, None)
environment.update(TERM="xterm-256color", COLORTERM="truecolor", GITSW_ANIM="0", COLUMNS=columns, LINES="24")
# Both macOS and Linux provide one of these UTF-8 locales. Do not leak locale warnings into stderr JSON.
for candidate in ("en_US.UTF-8", "C.UTF-8", "UTF-8"):
    try:
        locale.setlocale(locale.LC_CTYPE, candidate)
    except locale.Error:
        continue
    environment["LC_ALL"] = candidate
    break
process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=slave,
                           stderr=subprocess.PIPE, env=environment, start_new_session=True)
os.close(slave)
selector = selectors.DefaultSelector()
selector.register(master, selectors.EVENT_READ, "stdout")
selector.register(process.stderr, selectors.EVENT_READ, "stderr")
chunks = {"stdout": bytearray(), "stderr": bytearray()}
deadline = time.monotonic() + 20
timed_out = False
while selector.get_map():
    if time.monotonic() >= deadline:
        timed_out = True
        os.killpg(process.pid, signal.SIGKILL)
        break
    for key, _ in selector.select(min(0.2, max(0, deadline - time.monotonic()))):
        try:
            data = os.read(key.fd, 65536)
        except OSError as error:
            if error.errno != errno.EIO:
                raise
            data = b""
        if data:
            chunks[key.data].extend(data)
        else:
            selector.unregister(key.fileobj)
process.wait(timeout=5)
selector.close()
os.close(master)
process.stderr.close()
result = {key: bytes(value).decode("utf-8", "replace").replace("\r\n", "\n")
          for key, value in chunks.items()}
result.update(code=process.returncode, timedOut=timed_out)
with open(result_path, "w", encoding="utf-8") as handle:
    json.dump(result, handle, ensure_ascii=False)
if timed_out:
    print("PTY command timed out:", command, file=sys.stderr)
    print(result, file=sys.stderr)
    sys.exit(1)
PY
  [ $? -eq 0 ] || fail 'PTY harness failed'
  OUT=$(jq -r .stdout "$T/terminal-result.json")
  UI_ERR=$(jq -r .stderr "$T/terminal-result.json")
  # shellcheck disable=SC2034  # shared tests/lib.sh assertions consume RC
  RC=$(jq -r .code "$T/terminal-result.json")
}

terminal_ui_once() {
  python3 - "$T/terminal-result.json" <<'PY'
import json, re, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
plain = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", data["stdout"])
for row in ("⣼⣿⣦", "⣿⣿⠃⢀⡄    ⣠⡔ ⢠⣿⣿⡶", "⠈⠻⢦⡾⠃   ⠸⢿⣥⣴⣿⠿⠋"):
    assert plain.count(row) == 1, "expected exactly one unchanged small eye row: " + repr(row) + "\n" + plain
assert "\x1b[?25" not in data["stdout"], "command header must not animate/hide cursor"
assert "\r" not in data["stdout"], "command header must not redraw"
PY
  [ $? -eq 0 ] || fail 'small trademark eye header'
}

terminal_ui_no_decoration() {
  python3 - "$T/terminal-result.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
for channel in ("stdout", "stderr"):
    assert "⣼⣿⣦" not in data[channel], "eye logo contaminated " + channel
    assert not any(0x2800 <= ord(char) <= 0x28ff for char in data[channel]), "legacy Braille logo contaminated " + channel
    assert "\x1b" not in data[channel], "ANSI contaminated " + channel + ": " + repr(data[channel])
PY
  [ $? -eq 0 ] || fail 'protocol/plain output contains terminal decoration'
}

test_terminal_ui_human_commands_show_one_small_eye() {
  mac_only || return 0
  terminal_ui_repo
  terminal_ui_run 90 gitch help
  assert_ok; terminal_ui_once
  terminal_ui_run 90 gitch version
  assert_ok; terminal_ui_once
  terminal_ui_run 90 gitch ck --no-fetch
  assert_ok; terminal_ui_once
  assert_out '작업 상태'
  terminal_ui_run 90 gitch status
  assert_ok; terminal_ui_once
  assert_out alice
  terminal_ui_run 90 gitch preflight --no-fetch
  assert_ok; terminal_ui_once
  assert_out 'PREFLIGHT='
  assert_out 'REPO_ACCOUNT=alice'
  terminal_ui_run 90 gitch graph --help
  assert_ok; terminal_ui_once
  terminal_ui_run 90 gitch list
  assert_ok; terminal_ui_once
}

test_terminal_ui_errors_keep_one_header_and_exit_status() {
  mac_only || return 0
  terminal_ui_run 80 gitch unknown-terminal-command
  assert_rc 1; terminal_ui_once
  case "$UI_ERR" in *'알 수 없는 명령'*) ;; *) fail "missing human error: $UI_ERR" ;; esac
}

test_terminal_ui_no_color_keeps_eyes_without_ansi() {
  mac_only || return 0
  terminal_ui_run 80 env NO_COLOR=1 GITSW_COLOR=always gitch version
  assert_ok; terminal_ui_once
  case "$OUT$UI_ERR" in *$'\033'*) fail 'NO_COLOR must suppress ANSI even with forced color' ;; esac
  terminal_ui_run 80 env GITSW_COLOR=never gitch version
  assert_ok; terminal_ui_once
  case "$OUT$UI_ERR" in *$'\033'*) fail 'GITSW_COLOR=never must suppress ANSI' ;; esac
}

test_terminal_ui_color_auto_on_real_tty() {
  mac_only || return 0
  terminal_ui_run 80 gitch version
  assert_ok; terminal_ui_once
  case "$OUT" in *$'\033['*) ;; *) fail 'real color terminal should use ANSI emphasis' ;; esac
}

test_terminal_ui_install_keeps_one_header_and_clean_results() {
  mac_only || return 0
  terminal_ui_repo
  terminal_ui_run 90 env GITSW_ANIM=0 gitch install
  assert_ok; terminal_ui_once
  assert_no_out '\e[1m' 'legacy result exposed a literal bold escape'
  assert_no_out '\e[0m' 'legacy result exposed a literal reset escape'
}

test_terminal_ui_plain_and_dumb_disable_layout() {
  mac_only || return 0
  terminal_ui_repo
  terminal_ui_run 80 env GITCH_STYLE=plain gitch preflight --no-fetch
  assert_ok; terminal_ui_no_decoration
  assert_out 'PREFLIGHT='
  assert_out 'REPO_ACCOUNT=alice'
  terminal_ui_run 80 env TERM=dumb GITSW_BANNER=always gitch ck --no-fetch
  assert_ok; terminal_ui_no_decoration
  terminal_ui_run 80 env GITSW_BANNER=never gitch version
  assert_ok; terminal_ui_no_decoration
  terminal_ui_run 80 env GITCH_STYLE=plain GITSW_BANNER=always gitch install
  assert_ok; terminal_ui_no_decoration
  terminal_ui_run 80 env TERM=dumb GITSW_BANNER=always gitch install
  assert_ok; terminal_ui_no_decoration
}

test_terminal_ui_pipe_preserves_plain_contract() {
  terminal_ui_repo
  run env TERM=xterm-256color GITSW_COLOR=auto GITSW_BANNER=always gitch preflight --no-fetch
  assert_ok
  assert_out 'PREFLIGHT='
  assert_out 'REPO_ACCOUNT=alice'
  assert_no_out '⣼⣿⣦'
  assert_no_out $'\033'
  run env TERM=xterm-256color GITSW_COLOR=auto GITSW_BANNER=always gitch ck --json --no-fetch
  assert_ok; assert_json "$OUT"
  assert_no_out $'\033'
}

test_terminal_ui_json_tty_stays_parseable_when_forced() {
  mac_only || return 0
  terminal_ui_repo
  local command
  for command in version status ck preflight overlap; do
    case "$command" in
      ck|preflight) terminal_ui_run 80 env GITSW_COLOR=always GITSW_BANNER=always gitch "$command" --json --no-fetch ;;
      *) terminal_ui_run 80 env GITSW_COLOR=always GITSW_BANNER=always gitch "$command" --json ;;
    esac
    assert_ok; assert_json "$OUT" "$command JSON on PTY"
    terminal_ui_no_decoration
  done
  terminal_ui_run 80 env GITSW_COLOR=always GITSW_BANNER=always gitch move src/api.ts src/network/api.ts --plan --json
  assert_ok; assert_json "$OUT"; terminal_ui_no_decoration
  terminal_ui_run 80 env GITSW_COLOR=always GITSW_BANNER=always gitch module audit --json
  assert_ok; assert_json "$OUT"; terminal_ui_no_decoration
}

test_terminal_ui_json_error_channel_stays_clean_on_tty() {
  mac_only || return 0
  terminal_ui_run 80 env GITSW_COLOR=always GITSW_BANNER=always gitch unknown-terminal-command --json
  assert_rc 1
  assert_eq "$OUT" '' 'structured error must not write a human header to stdout'
  assert_json "$UI_ERR" 'structured error stderr'
  terminal_ui_no_decoration
}

test_terminal_ui_raw_protocols_stay_clean_on_tty() {
  mac_only || return 0
  terminal_ui_repo
  terminal_ui_run 80 env GITSW_COLOR=always GITSW_BANNER=always gitch schema ck
  assert_ok; assert_json "$OUT"; terminal_ui_no_decoration
  terminal_ui_run 80 env GITSW_COLOR=always GITSW_BANNER=always gitch completion bash
  assert_ok; terminal_ui_no_decoration
  assert_out '_gitch_completion'
  terminal_ui_run 80 env GITSW_COLOR=always GITSW_BANNER=always gitch _complete -- ver
  assert_ok; terminal_ui_no_decoration
  assert_eq "$OUT" version
  terminal_ui_run 80 env GITSW_COLOR=always GITSW_BANNER=always gitch config path
  assert_ok; terminal_ui_no_decoration
  assert_eq "$OUT" "$HOME/.config/gitsw/config"
  terminal_ui_run 80 env GITSW_COLOR=always GITSW_BANNER=always gitch config get account.alice.email
  assert_ok; terminal_ui_no_decoration
  assert_eq "$OUT" alice@example.com
  terminal_ui_run 80 env GITSW_COLOR=always GITSW_BANNER=always gitch graph files --format dot --no-open
  assert_ok; terminal_ui_no_decoration
  assert_out 'digraph'
}

test_terminal_ui_analysis_commands_keep_paths_and_results() {
  mac_only || return 0
  terminal_ui_repo
  printf '// current work\n' >> src/api.ts
  git worktree add -q -b side "$T/terminal-side" || fail 'terminal side worktree'
  printf '// side work\n' >> "$T/terminal-side/src/api.ts"
  terminal_ui_run 90 gitch overlap --no-deps --fail-on-overlap
  assert_rc 1; terminal_ui_once
  assert_out src/api.ts
  terminal_ui_run 90 gitch move src/api.ts src/network/api.ts --plan
  assert_ok; terminal_ui_once
  assert_out src/api.ts
  assert_out src/network/api.ts
  [ -f src/api.ts ] && [ ! -e src/network/api.ts ] || fail 'human move rendering changed files'
  printf 'import missing from "missing-terminal-dependency";\n' >> src/app.ts
  terminal_ui_run 90 gitch module audit --strict
  assert_rc 1; terminal_ui_once
  assert_out missing-terminal-dependency
  assert_out src/app.ts
}

test_terminal_ui_narrow_headers_fit_display_columns() {
  mac_only || return 0
  terminal_ui_repo
  git branch -m 'codex/아키텍처와모듈관리를정리하는작업' || fail 'Korean header branch fixture'
  local width
  for width in 80 40 28 16 8; do
    terminal_ui_run "$width" env NO_COLOR=1 gitch version
    assert_ok
    python3 - "$T/terminal-result.json" "$width" <<'PY'
import json, re, sys, unicodedata
result = json.load(open(sys.argv[1], encoding="utf-8"))
columns = int(sys.argv[2])
plain = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", result["stdout"])
lines = plain.lstrip("\n").split("\n")
header = []
for line in lines:
    if not line.strip():
        break
    header.append(line)
assert header, "missing terminal header"
assert "\ufffd" not in "\n".join(header), "header truncation split a UTF-8 character"
for line in header:
    width = sum(0 if unicodedata.combining(char) else 2 if unicodedata.east_asian_width(char) in "WF" else 1 for char in line)
    assert width <= columns, f"header line exceeds {columns} columns ({width}): {line!r}"
PY
    [ $? -eq 0 ] || fail "narrow header at $width columns"
  done
}

test_terminal_ui_wide_header_text_columns_align() {
  mac_only || return 0
  terminal_ui_run 90 env NO_COLOR=1 gitch version
  assert_ok; terminal_ui_once
  python3 - "$T/terminal-result.json" <<'PY'
import json, sys, unicodedata
result = json.load(open(sys.argv[1], encoding="utf-8"))
rows = result["stdout"].lstrip("\n").splitlines()
def display_width(text):
    return sum(0 if unicodedata.combining(char) else 2 if unicodedata.east_asian_width(char) in "WF" else 1 for char in text)
first = display_width(rows[0].split("gitch", 1)[0])
second = display_width(rows[1].split("Gitrochi", 1)[0])
assert first == second, f"header title/meta are misaligned: columns {first}/{second}\n" + "\n".join(rows[:3])
PY
  [ $? -eq 0 ] || fail 'side-by-side header text columns'
}

test_terminal_ui_narrow_output_keeps_copyable_paths() {
  mac_only || return 0
  terminal_ui_repo
  local path='src/long-module-name-with-full-path-preserved-for-copying-and-review.ts'
  printf 'export const pending = true;\n' > "$path"
  terminal_ui_run 28 env NO_COLOR=1 gitch ck --no-fetch
  assert_ok
  assert_out "$path" 'narrow layout truncated a copyable file path'
  assert_out 'git add <파일>' 'narrow layout truncated a copyable next command'
}

test_terminal_ui_non_utf8_locale_uses_ascii_header() {
  mac_only || return 0
  terminal_ui_run 60 env LC_ALL=C LANG=C gitch version
  assert_ok
  assert_no_out '⣼⣿⣦'
  python3 - "$T/terminal-result.json" <<'PY'
import json, re, sys
result = json.load(open(sys.argv[1], encoding="utf-8"))
plain = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", result["stdout"])
header = plain.lstrip("\n").split("\n\n", 1)[0]
assert header and header.isascii(), "C locale header must use the ASCII fallback: " + repr(header)
PY
  [ $? -eq 0 ] || fail 'non-UTF8 header fallback'
}

terminal_ui_no_eye() {
  python3 - "$T/terminal-result.json" <<'PY'
import json, re, sys
result = json.load(open(sys.argv[1], encoding="utf-8"))
for channel in ("stdout", "stderr"):
    plain = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", result[channel])
    assert not any(0x2800 <= ord(char) <= 0x28ff for char in plain), "eye logo present in " + channel
    assert not re.search(r"^\s*o o(?:\s|$)", plain, re.MULTILINE), "ASCII eye fallback present in " + channel
PY
  [ $? -eq 0 ] || fail 'disabled logo still renders eyes'
}

test_terminal_ui_logo_off_keeps_rich_layout_at_every_width() {
  mac_only || return 0
  terminal_ui_repo
  run env -u GITCH_LOGO gitch logo off --json; assert_ok
  local width
  for width in 90 40 28 8; do
    terminal_ui_run "$width" gitch ck --no-fetch
    assert_ok; terminal_ui_no_eye
    assert_out '작업 상태' 'logo preference disabled the useful rich body'
    case "$OUT" in *$'\033['*) ;; *) fail 'logo off disabled colors' ;; esac
  done
  terminal_ui_run 60 env LC_ALL=C LANG=C gitch version
  assert_ok; terminal_ui_no_eye
  assert_out gitch
}

test_terminal_ui_logo_command_takes_effect_immediately() {
  mac_only || return 0
  terminal_ui_run 90 env GITCH_LOGO=on gitch logo off
  assert_ok; terminal_ui_no_eye
  terminal_ui_run 90 gitch version
  assert_ok; terminal_ui_no_eye
  terminal_ui_run 90 env GITCH_LOGO=off gitch logo on
  assert_ok; terminal_ui_once
  terminal_ui_run 90 gitch version
  assert_ok; terminal_ui_once
}

test_terminal_ui_logo_environment_override_is_temporary() {
  mac_only || return 0
  run env -u GITCH_LOGO gitch logo off --json; assert_ok
  terminal_ui_run 90 env GITCH_LOGO=on gitch version
  assert_ok; terminal_ui_once
  terminal_ui_run 90 gitch version
  assert_ok; terminal_ui_no_eye
  run env -u GITCH_LOGO gitch logo on --json; assert_ok
  terminal_ui_run 90 env GITCH_LOGO=off gitch version
  assert_ok; terminal_ui_no_eye
  terminal_ui_run 90 gitch version
  assert_ok; terminal_ui_once
  terminal_ui_run 90 env GITCH_LOGO=on GITCH_STYLE=plain GITSW_BANNER=always gitch version
  assert_ok; terminal_ui_no_decoration
  terminal_ui_run 90 env GITCH_LOGO=on GITSW_BANNER=never gitch version
  assert_ok; terminal_ui_no_decoration
}

test_terminal_ui_logo_json_and_error_protocols_are_clean() {
  mac_only || return 0
  local sub
  for sub in status off on; do
    terminal_ui_run 90 env GITSW_COLOR=always GITSW_BANNER=always gitch logo "$sub" --json
    assert_ok; assert_json "$OUT"; terminal_ui_no_decoration
    assert_eq "$UI_ERR" '' 'successful logo JSON wrote stderr'
  done
  terminal_ui_run 90 env GITSW_COLOR=always GITSW_BANNER=always gitch logo off extra --json
  assert_rc 1
  assert_eq "$OUT" '' 'invalid logo JSON wrote human stdout'
  assert_json "$UI_ERR"; terminal_ui_no_decoration
}
