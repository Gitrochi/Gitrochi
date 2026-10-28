"""Child processes in their own process group, so a whole tree can be stopped (POSIX); Windows is best effort."""

from __future__ import annotations

import os
import signal
import subprocess
import time
from typing import Any, Dict, Optional, Sequence

WINDOWS = os.name == "nt"


def group_kwargs() -> Dict[str, Any]:
    """Popen arguments that put the child in a new process group / session."""
    if WINDOWS:
        flags = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0x200) | getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000)
        return {"creationflags": flags}
    return {"start_new_session": True}


def detached_kwargs() -> Dict[str, Any]:
    """Like group_kwargs, for a process that must outlive this one."""
    if WINDOWS:
        flags = (getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0x200) | getattr(subprocess, "DETACHED_PROCESS", 0x8)
                 | getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000))
        return {"creationflags": flags, "close_fds": True}
    return {"start_new_session": True, "close_fds": True}


def pid_alive(pid: Optional[int]) -> bool:
    if not pid or pid <= 0:
        return False
    if WINDOWS:  # pragma: no cover - Windows only
        out = subprocess.run(["tasklist", "/FI", f"PID eq {pid}", "/NH"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        return str(pid) in out.stdout.decode("utf-8", "replace")
    try:
        # An exited child of ours stays a zombie (and "alive" for kill 0) until it is collected.
        if os.waitpid(pid, os.WNOHANG)[0] == pid:
            return False
    except (ChildProcessError, OSError):
        pass
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def reap_group(pgid: int) -> None:
    """Collect exited children of ours in this group; a zombie still counts as a group member for killpg."""
    if WINDOWS:  # pragma: no cover - Windows only
        return
    while True:
        try:
            pid, _ = os.waitpid(-pgid, os.WNOHANG)
        except (ChildProcessError, OSError):
            return
        if pid == 0:
            return


def group_alive(pgid: Optional[int]) -> bool:
    if not pgid or pgid <= 0:
        return False
    if WINDOWS:  # pragma: no cover - Windows only
        return pid_alive(pgid)
    reap_group(pgid)
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def signal_group(pgid: int, sig: int) -> None:
    if WINDOWS:  # pragma: no cover - Windows only
        subprocess.run(["taskkill", "/PID", str(pgid), "/T", "/F"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return
    try:
        os.killpg(pgid, sig)
    except (ProcessLookupError, PermissionError):
        pass


def stop_group(pgid: Optional[int], grace: float = 10.0, proc: Optional[subprocess.Popen] = None) -> None:
    """SIGTERM the whole group, then SIGKILL whatever is left after `grace` seconds."""
    if not pgid:
        return
    signal_group(pgid, signal.SIGTERM if not WINDOWS else 0)
    deadline = time.monotonic() + grace
    while time.monotonic() < deadline:
        if proc is not None:
            proc.poll()
        if not group_alive(pgid):
            return
        time.sleep(0.05)
    if not WINDOWS:
        signal_group(pgid, signal.SIGKILL)
        end = time.monotonic() + 2
        while time.monotonic() < end and group_alive(pgid):
            if proc is not None:
                proc.poll()
            time.sleep(0.05)


def run_capture(cmd: Sequence[str], cwd: Optional[str] = None, env: Optional[Dict[str, str]] = None,
                timeout: Optional[float] = None, max_output: int = 2_000_000) -> Dict[str, Any]:
    """Run a command in its own group; on timeout the group is stopped. Returns exit code, output and timing."""
    started = time.monotonic()
    try:
        proc = subprocess.Popen(list(cmd), cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                stdin=subprocess.DEVNULL, **group_kwargs())
    except OSError as exc:
        return {"exitCode": None, "output": "", "timedOut": False, "error": f"cannot start {cmd[0]}: {exc}", "seconds": 0.0}
    timed_out = False
    try:
        out, _ = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        stop_group(proc.pid, grace=5.0, proc=proc)
        try:
            out, _ = proc.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            out = b""
    except KeyboardInterrupt:
        stop_group(proc.pid, grace=2.0, proc=proc)
        raise
    text = (out or b"")[-max_output:].decode("utf-8", "replace")
    return {"exitCode": proc.returncode if not timed_out else None, "output": text, "timedOut": timed_out, "error": None,
            "seconds": time.monotonic() - started}


def exit_code_of(returncode: Optional[int]) -> Optional[int]:
    """Popen's negative "killed by signal" codes as the shell reports them (128 + signal)."""
    if returncode is None:
        return None
    return 128 - returncode if returncode < 0 else returncode
