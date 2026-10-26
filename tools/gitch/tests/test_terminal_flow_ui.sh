# shellcheck shell=bash
# 흐름 엔진의 원문 출력과 사람용 화면을 실제 PTY에서 구분한다.

terminal_flow_ui_fixture() {
  cat > "$T/flow-ui-engine" <<'ENGINE'
#!/bin/bash
printf '%s\n' "$@" > "$FLOW_UI_ARGS"
printf '%s\n' "$FLOW_UI_PAYLOAD"
exit "${FLOW_UI_STATUS:-0}"
ENGINE
  chmod +x "$T/flow-ui-engine"
  export GITCH_FLOW="$T/flow-ui-engine" FLOW_UI_ARGS="$T/flow-ui-args"
  export FLOW_UI_STATUS=0 FLOW_UI_PAYLOAD='흐름 엔진 결과'
}

terminal_flow_ui_run() {
  local width=90
  # Windows의 Python에는 pty가 없어 일반 출력 호환성 검사로 확인합니다.
  [ -z "$IS_WIN" ] || return 0
  python3 - "$T/flow-ui-result.json" "$width" env GITSW_COLOR=always GITSW_BANNER=always GITCH_LOGO=on gitch "$@" <<'PY'
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
  OUT=$(jq -r .stdout "$T/flow-ui-result.json")
  # shellcheck disable=SC2034  # 공통 tests/lib.sh 검증 함수가 RC를 읽습니다.
  RC=$(jq -r .code "$T/flow-ui-result.json")
}

terminal_flow_ui_raw() {
  assert_eq "$OUT" "$FLOW_UI_PAYLOAD"
  assert_eq "$(jq -r .stderr "$T/flow-ui-result.json")" ''
  python3 - "$T/flow-ui-result.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1], encoding='utf-8'))
for channel in ('stdout', 'stderr'):
    assert '\x1b' not in result[channel], repr(result)
    assert not any(0x2800 <= ord(char) <= 0x28ff for char in result[channel]), repr(result)
PY
  [ $? -eq 0 ] || fail '흐름 원문에 로고·ANSI가 섞임'
}

test_terminal_flow_ui_contract_and_event_streams_stay_raw() {
  mac_only || return 0
  terminal_flow_ui_fixture
  FLOW_UI_PAYLOAD='{"schemaVersion":1}'
  terminal_flow_ui_run flow schema
  assert_ok; terminal_flow_ui_raw
  FLOW_UI_PAYLOAD=$'{"sequence":1}\n{"sequence":2}'
  terminal_flow_ui_run flow events last
  assert_ok; terminal_flow_ui_raw
  terminal_flow_ui_run flow run checks --events
  assert_ok; terminal_flow_ui_raw
  terminal_flow_ui_run test unit --events
  assert_ok; terminal_flow_ui_raw
  terminal_flow_ui_run ci status --events
  assert_ok; terminal_flow_ui_raw
}

test_terminal_flow_ui_report_formats_stay_raw() {
  mac_only || return 0
  terminal_flow_ui_fixture
  FLOW_UI_PAYLOAD='<testsuites><testsuite/></testsuites>'
  terminal_flow_ui_run flow report last --format junit
  assert_ok; terminal_flow_ui_raw
  FLOW_UI_PAYLOAD='# 흐름 결과'
  terminal_flow_ui_run flow report last --format md
  assert_ok; terminal_flow_ui_raw
  terminal_flow_ui_run flow report last --format=markdown
  assert_ok; terminal_flow_ui_raw
  FLOW_UI_PAYLOAD='<!doctype html><title>흐름 결과</title>'
  terminal_flow_ui_run flow report last --format=html
  assert_ok; terminal_flow_ui_raw
  terminal_flow_ui_run ci report last --format html
  assert_ok; terminal_flow_ui_raw
}

test_terminal_flow_ui_summary_exports_and_internal_names_stay_raw() {
  mac_only || return 0
  terminal_flow_ui_fixture
  FLOW_UI_PAYLOAD='FLOW=SUCCEEDED'
  terminal_flow_ui_run flow run checks --summary
  assert_ok; terminal_flow_ui_raw
  terminal_flow_ui_run test unit --summary
  assert_ok; terminal_flow_ui_raw
  FLOW_UI_PAYLOAD=$'name: checks\njobs: {}'
  terminal_flow_ui_run flow export github --dry-run
  assert_ok; terminal_flow_ui_raw
  FLOW_UI_PAYLOAD=$'unit\nintegration'
  terminal_flow_ui_run flow _names suites
  assert_ok; terminal_flow_ui_raw
}

test_terminal_flow_ui_human_commands_keep_one_header() {
  mac_only || return 0
  terminal_flow_ui_fixture
  local first second
  for first in flow test ci; do
    case "$first" in flow) second=version ;; test) second=unit ;; ci) second=status ;; esac
    terminal_flow_ui_run "$first" "$second"
    assert_ok; assert_out "$FLOW_UI_PAYLOAD"
    python3 - "$T/flow-ui-result.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1], encoding='utf-8'))
assert result['stdout'].count('⣼⣿⣦') == 1, repr(result)
assert result['stdout'].endswith('흐름 엔진 결과\n'), repr(result)
assert result['stderr'] == '', repr(result)
PY
    [ $? -eq 0 ] || fail '사람용 흐름 명령의 작은 눈 헤더'
    assert_eq "$(sed -n '1p' "$FLOW_UI_ARGS")" "$(if [ "$first" = flow ]; then printf '%s' "$second"; else printf '%s' "$first"; fi)"
  done
}

test_terminal_flow_ui_raw_modes_preserve_exit_code() {
  mac_only || return 0
  terminal_flow_ui_fixture
  FLOW_UI_PAYLOAD='{"sequence":1}'; FLOW_UI_STATUS=3
  terminal_flow_ui_run flow events last
  assert_rc 3; terminal_flow_ui_raw
}
