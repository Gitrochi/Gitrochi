"""Platform helpers for the optional Python graph backends' integration tests."""

import os
from pathlib import Path
import shutil
import signal
import subprocess
import time


def bash_executable():
    override = os.environ.get("GITCH_TEST_BASH")
    if override and Path(override).is_file():
        return override
    if os.name == "nt":
        git = shutil.which("git")
        if git:
            for parent in Path(git).resolve().parents:
                for relative in ("bin/bash.exe", "usr/bin/bash.exe"):
                    candidate = parent / relative
                    if candidate.is_file():
                        return str(candidate)
    return shutil.which("bash") or "bash"


def write_utf8(path, text):
    """Write fixture bytes literally, including LF shell script line endings."""
    return Path(path).write_bytes(text.encode("utf-8"))


def stop_process_tree(pid):
    """Stop only a process tree created by the current isolated test."""
    if os.name == "nt":
        subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=5)
    else:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass


def remove_when_released(directory, timeout=10):
    """Remove a test's TemporaryDirectory once the processes it stopped have let go of it.

    Windows ends a killed process tree asynchronously: until a git or Git Bash process from that tree
    has exited, the folder it works in stays in use (WinError 32).
    """
    deadline = time.monotonic() + timeout
    while True:
        try:
            directory.cleanup()
            return
        except PermissionError:
            if os.name != "nt" or time.monotonic() >= deadline:
                raise
            time.sleep(0.1)
