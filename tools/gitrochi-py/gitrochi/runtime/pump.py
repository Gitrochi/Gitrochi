#!/usr/bin/env python3
"""Run one service command, copy its output into a size-rotated log file, and record its exit status.

The supervisor and `runtime deploy` start services through this file (by path, standard library only), so a
service keeps logging with rotation whichever process started it. It shares the service's process group:
stopping the group stops both. Signals it receives are passed on to the service.
"""

import argparse
import json
import os
import signal
import subprocess
import sys
import tempfile
import time


class RotatingLog:
    """Append-only log; when it would pass max_bytes it moves to .1, .1 to .2 ... keeping `keep` old files."""

    def __init__(self, path, max_bytes, keep):
        self.path = path
        self.max_bytes = max(1024, int(max_bytes))
        self.keep = max(0, int(keep))
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        self.handle = open(path, "ab")
        self.size = self.handle.tell()

    def write(self, data):
        while data:
            room = self.max_bytes - self.size
            if room <= 0:
                self.rotate()
                room = self.max_bytes
            piece, data = data[:room], data[room:]
            self.handle.write(piece)
            self.size += len(piece)
        self.handle.flush()

    def rotate(self):
        self.handle.close()
        if self.keep == 0:
            open(self.path, "wb").close()
        else:
            oldest = f"{self.path}.{self.keep}"
            if os.path.exists(oldest):
                os.remove(oldest)
            for number in range(self.keep - 1, 0, -1):
                source = f"{self.path}.{number}"
                if os.path.exists(source):
                    os.replace(source, f"{self.path}.{number + 1}")
            os.replace(self.path, f"{self.path}.1")
        self.handle = open(self.path, "ab")
        self.size = 0

    def close(self):
        try:
            self.handle.close()
        except OSError:
            pass


def write_status(path, data):
    if not path:
        return
    folder = os.path.dirname(os.path.abspath(path))
    os.makedirs(folder, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".status.", dir=folder)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(data, handle)
    os.replace(tmp, path)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", required=True)
    parser.add_argument("--max-bytes", type=int, default=10 * 1024 * 1024)
    parser.add_argument("--keep", type=int, default=5)
    parser.add_argument("--status")
    parser.add_argument("--cwd")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("no command")
    log = RotatingLog(args.log, args.max_bytes, args.keep)
    stamp = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime())
    log.write(f"--- {stamp}Z start: {command[0]} (pid {os.getpid()})\n".encode("utf-8"))
    try:
        child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                 cwd=args.cwd or None)
    except OSError as exc:
        log.write(f"--- cannot start {command[0]}: {exc}\n".encode("utf-8"))
        write_status(args.status, {"pumpPid": os.getpid(), "pid": None, "startedAt": time.time(), "endedAt": time.time(),
                                   "exitCode": 127, "error": str(exc)})
        log.close()
        return 127
    pgid = os.getpgid(0) if hasattr(os, "getpgid") else os.getpid()
    status = {"pumpPid": os.getpid(), "pid": child.pid, "pgid": pgid, "startedAt": time.time()}
    write_status(args.status, status)

    def forward(signum, _frame):
        try:
            child.send_signal(signum)
        except OSError:
            pass

    for name in ("SIGTERM", "SIGINT", "SIGHUP"):
        if hasattr(signal, name):
            signal.signal(getattr(signal, name), forward)
    fd = child.stdout.fileno()
    while True:
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        log.write(chunk)
    code = child.wait()
    exit_code = code if code >= 0 else 128 - code
    stamp = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime())
    log.write(f"--- {stamp}Z exit {exit_code}\n".encode("utf-8"))
    log.close()
    status.update(exitCode=exit_code, endedAt=time.time())
    write_status(args.status, status)
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
