"""Health checks: an HTTP(S) URL answering 2xx/3xx, a TCP port accepting connections, or a command exiting 0."""

from __future__ import annotations

import socket
import time
import urllib.error
import urllib.request
from typing import Dict, Optional, Tuple

from gitrochi import procs
from gitrochi.runtime.manifest import Health, expand


def check(health: Health, values: Dict[str, str], env: Optional[Dict[str, str]] = None, cwd: Optional[str] = None) -> Tuple[bool, str]:
    if health.http:
        url = expand(health.http, values)
        # Health checks talk to this machine's services; a configured proxy must not be in the way.
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        try:
            with opener.open(urllib.request.Request(url, method="GET", headers={"user-agent": "gitrochi-py"}), timeout=health.timeout) as response:
                status = response.status
        except urllib.error.HTTPError as exc:
            status = exc.code
        except (urllib.error.URLError, socket.timeout, ConnectionError, OSError) as exc:
            reason = getattr(exc, "reason", exc)
            return False, f"{url}: {reason}"
        return (200 <= status < 400), f"HTTP {status}"
    if health.tcp:
        target = expand(health.tcp, values)
        host, _, port = target.rpartition(":")
        try:
            with socket.create_connection((host.strip("[]") or "127.0.0.1", int(port)), timeout=health.timeout):
                return True, f"{target} accepts connections"
        except (OSError, ValueError) as exc:
            return False, f"{target}: {exc}"
    if health.command:
        cmd = [expand(part, values) for part in health.command]
        result = procs.run_capture(cmd, cwd=cwd, env=env, timeout=health.timeout)
        if result["timedOut"]:
            return False, f"timed out after {health.timeout:g}s"
        if result["error"]:
            return False, result["error"]
        tail = (result["output"] or "").strip().splitlines()[-1:] or [""]
        return result["exitCode"] == 0, f"exit {result['exitCode']}" + (f": {tail[0][:200]}" if tail[0] else "")
    return True, "no health check"


def wait_healthy(health: Optional[Health], values: Dict[str, str], deadline: float, alive, env: Optional[Dict[str, str]] = None,
                 cwd: Optional[str] = None, interval: float = 0.25) -> Tuple[bool, str, int]:
    """Poll until healthy, the process dies (alive() is False) or the deadline passes. Returns (ok, detail, attempts)."""
    attempts = 0
    detail = "not checked"
    while True:
        if not alive():
            return False, f"the process exited before it was healthy ({detail})", attempts
        if health is None:
            return True, "no health check (process is running)", attempts
        attempts += 1
        ok, detail = check(health, values, env, cwd)
        if ok:
            return True, detail, attempts
        if time.monotonic() >= deadline:
            return False, f"not healthy before the timeout: {detail}", attempts
        time.sleep(min(interval, max(0.0, deadline - time.monotonic())))
