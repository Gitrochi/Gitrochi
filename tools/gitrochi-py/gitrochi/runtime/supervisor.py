"""The supervisor: starts services, watches health, restarts with backoff, and stops whole process groups.

State lives under the manifest's state folder:
  supervisor.json           the running supervisor (pid, services)
  services/<name>.json      each service's state, rewritten as it changes
  control/<name>.<action>   start / stop / restart requests from `runtime restart|down <service>`
  logs/<name>.log[.N]       service output, rotated by pump.py
  deploy/<name>.json        blue/green state of deployable services (see deploy.py)
Deployable services follow deploy/<name>.json: the supervisor watches whichever process is current there.
"""

from __future__ import annotations

import os
import signal
import subprocess
import sys
import threading
import time
from concurrent.futures import Future, ThreadPoolExecutor
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

from gitrochi import procs
from gitrochi.runtime import health as healthmod
from gitrochi.runtime import manifest as mf
from gitrochi.runtime.manifest import Manifest, Service
from gitrochi.util import Failure, atomic_write_json, iso, read_json

PUMP = str(Path(__file__).resolve().parent / "pump.py")
ACTIVE = {"starting", "running", "healthy", "unhealthy", "backoff", "waiting"}
# Services started detached (deploys) outlive the call that started them; holding their Popen objects keeps
# Python from warning about, or reaping, a process that is meant to keep running.
_DETACHED: List[subprocess.Popen] = []


def prune_detached() -> None:
    """Forget detached processes that have ended (poll() records their status)."""
    for popen in list(_DETACHED):
        if popen.poll() is not None:
            _DETACHED.remove(popen)


# ---------- processes ----------

class Proc:
    """A service process group started through pump.py (by this process or another one)."""

    def __init__(self, pid: int, pgid: int, status_file: Optional[str], started: float, popen: Optional[subprocess.Popen] = None):
        self.pid = pid
        self.pgid = pgid
        self.status_file = status_file
        self.started = started
        self.popen = popen

    def alive(self) -> bool:
        if self.popen is not None:
            return self.popen.poll() is None
        return procs.group_alive(self.pgid)

    def exit_code(self) -> Optional[int]:
        if self.popen is not None and self.popen.returncode is not None:
            return procs.exit_code_of(self.popen.returncode)
        status = read_json(Path(self.status_file)) if self.status_file else None
        if isinstance(status, dict) and status.get("exitCode") is not None:
            return int(status["exitCode"])
        return None

    def stop(self, grace: float) -> None:
        procs.stop_group(self.pgid, grace=grace, proc=self.popen)
        if self.popen is not None:
            try:
                self.popen.wait(timeout=1)
            except subprocess.TimeoutExpired:
                pass

    def to_dict(self) -> Dict[str, Any]:
        return {"pid": self.pid, "pgid": self.pgid, "status": self.status_file, "startedAt": self.started}

    @staticmethod
    def from_dict(data: Optional[Dict[str, Any]]) -> Optional["Proc"]:
        if not isinstance(data, dict) or not data.get("pgid"):
            return None
        return Proc(int(data.get("pid") or data["pgid"]), int(data["pgid"]), data.get("status"), float(data.get("startedAt") or 0))


def resolve_cwd(manifest: Manifest, service: Service, values: Dict[str, str]) -> Path:
    cwd = Path(mf.expand(service.cwd, values))
    return cwd if cwd.is_absolute() else (manifest.folder / cwd).resolve()


def spawn(manifest: Manifest, service: Service, values: Dict[str, str], detached: bool = False,
          python: str = sys.executable) -> Proc:
    """Start a service through pump.py in a new process group."""
    env = mf.child_env(service, values)
    cmd = [mf.expand(part, values) for part in service.command]
    cwd = resolve_cwd(manifest, service, values)
    if not cwd.is_dir():
        raise Failure(f"{service.name}: working folder {cwd} does not exist", code="RUNTIME_CWD")
    tag = values.get("SLOT") or "main"
    status = manifest.state_dir / "procs" / f"{service.name}-{tag}-{time.time_ns()}.json"
    status.parent.mkdir(parents=True, exist_ok=True)
    log = manifest.log_path(service)
    log.parent.mkdir(parents=True, exist_ok=True)
    argv = [python, PUMP, "--log", str(log), "--max-bytes", str(service.log_max_bytes), "--keep", str(service.log_keep),
            "--status", str(status), "--cwd", str(cwd), "--"] + cmd
    kwargs = procs.detached_kwargs() if detached else procs.group_kwargs()
    popen = subprocess.Popen(argv, cwd=str(cwd), env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, **kwargs)
    if detached:
        prune_detached()
        _DETACHED.append(popen)
    return Proc(popen.pid, popen.pid, str(status), time.time(), popen)


def health_env(manifest: Manifest, service: Service, values: Dict[str, str]) -> Dict[str, str]:
    return mf.child_env(service, values)


# ---------- state files ----------

def service_state_path(manifest: Manifest, name: str) -> Path:
    return manifest.state_dir / "services" / f"{name}.json"


def deploy_state_path(manifest: Manifest, name: str) -> Path:
    return manifest.state_dir / "deploy" / f"{name}.json"


def read_deploy(manifest: Manifest, name: str) -> Dict[str, Any]:
    data = read_json(deploy_state_path(manifest, name), {})
    return data if isinstance(data, dict) else {}


def supervisor_info(manifest: Manifest) -> Optional[Dict[str, Any]]:
    info = read_json(manifest.state_dir / "supervisor.json")
    if isinstance(info, dict) and procs.pid_alive(int(info.get("pid") or 0)):
        return info
    return None


def request(manifest: Manifest, name: str, action: str) -> None:
    folder = manifest.state_dir / "control"
    folder.mkdir(parents=True, exist_ok=True)
    (folder / f"{name}.{action}").write_text(str(time.time()), encoding="utf-8")


class FileLock:
    """An exclusive lock on a file (flock on POSIX, msvcrt on Windows) so deploy and supervisor take turns."""

    def __init__(self, path: Path):
        self.path = Path(path)
        self.handle = None

    def acquire(self, timeout: float = 0.0) -> bool:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.handle = open(self.path, "a+")
        deadline = time.monotonic() + timeout
        while True:
            try:
                if os.name == "nt":  # pragma: no cover - Windows only
                    import msvcrt
                    msvcrt.locking(self.handle.fileno(), msvcrt.LK_NBLCK, 1)
                else:
                    import fcntl
                    fcntl.flock(self.handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                return True
            except OSError:
                if time.monotonic() >= deadline:
                    self.handle.close()
                    self.handle = None
                    return False
                time.sleep(0.05)

    def release(self) -> None:
        if self.handle is None:
            return
        try:
            if os.name == "nt":  # pragma: no cover - Windows only
                import msvcrt
                msvcrt.locking(self.handle.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                import fcntl
                fcntl.flock(self.handle.fileno(), fcntl.LOCK_UN)
        except OSError:
            pass
        self.handle.close()
        self.handle = None


# ---------- one service ----------

class Runner:
    def __init__(self, sup: "Supervisor", service: Service):
        self.sup = sup
        self.service = service
        self.proc: Optional[Proc] = None
        self.state = "stopped"
        self.restarts = 0
        self.recent: List[float] = []
        self.next_start: Optional[float] = None
        self.last_exit: Optional[int] = None
        self.last_exit_at: Optional[float] = None
        self.message = ""
        self.health_ok: Optional[bool] = None
        self.health_detail = ""
        self.health_at: Optional[float] = None
        self.health_failures = 0
        self.health_future: Optional[Future] = None
        self.next_health = 0.0
        self.values: Dict[str, str] = {}
        self.slot: Optional[str] = None
        self.version: Optional[str] = None
        self.dirty = True

    @property
    def deployable(self) -> bool:
        return self.service.deploy is not None

    def log(self, text: str) -> None:
        self.sup.say(f"{self.service.name}: {text}")

    def set(self, state: str, message: str = "") -> None:
        if state != self.state or message != self.message:
            self.state = state
            self.message = message
            self.dirty = True

    # -- desired release for deployable services --

    def _deploy_target(self) -> Optional[Dict[str, Any]]:
        dep = self.service.deploy
        assert dep is not None
        current = read_deploy(self.sup.manifest, self.service.name).get("current") or {}
        slot = current.get("slot") or next(iter(dep.slots))
        version = current.get("version")
        if dep.release and not version:
            return None
        release_dir = current.get("releaseDir")
        if dep.release and version and not release_dir:
            release_dir = str((self.sup.manifest.folder / mf.expand(dep.release, {"VERSION": version, "SERVICE": self.service.name})).resolve())
        return {"slot": slot, "version": version, "port": dep.slots[slot], "releaseDir": release_dir, "current": current}

    def _values(self, target: Optional[Dict[str, Any]]) -> Dict[str, str]:
        if target is None:
            return self.sup.manifest.variables(self.service)
        return self.sup.manifest.variables(self.service, port=target["port"], version=target.get("version"),
                                           release_dir=target.get("releaseDir"), slot=target["slot"])

    # -- lifecycle --

    def _deploy_lock(self) -> FileLock:
        return FileLock(deploy_state_path(self.sup.manifest, self.service.name).with_suffix(".lock"))

    def start(self, now: float) -> None:
        if not self.deployable:
            self._spawn(now, None)
            return
        # Hold the deploy lock while choosing and recording the process, so a deploy never misses it.
        lock = self._deploy_lock()
        if not lock.acquire(timeout=0.0):
            self.next_start = now + 0.5
            self.set("backoff", "waiting for a deploy to finish")
            return
        try:
            target = self._deploy_target()
            if target is None:
                self.set("not-deployed", f"run `runtime deploy {self.service.name} --version V` first")
                return
            adopted = Proc.from_dict(target["current"]) if target["current"].get("pgid") else None
            if adopted is not None and adopted.alive():
                self.proc = adopted
                self.values = self._values(target)
                self.slot, self.version = target["slot"], target.get("version")
                self._began(now, "adopted")
                return
            self._spawn(now, target)
        finally:
            lock.release()

    def _spawn(self, now: float, target: Optional[Dict[str, Any]]) -> None:
        self.values = self._values(target)
        try:
            self.proc = spawn(self.sup.manifest, self.service, self.values, python=self.sup.python)
        except (Failure, OSError) as exc:
            message = exc.message if isinstance(exc, Failure) else str(exc)
            self.log(f"cannot start: {message}")
            self.proc = None
            self.last_exit, self.last_exit_at = 127, now
            self._after_failure(now, message)
            return
        if target is not None:
            self.slot, self.version = target["slot"], target.get("version")
            self._record_deploy_proc(target)
        self._began(now, "started")

    def _began(self, now: float, verb: str) -> None:
        assert self.proc is not None
        port = self.values.get("PORT")
        self.log(f"{verb} pid {self.proc.pid}" + (f" on port {port}" if port else "") + (f" ({self.version})" if self.version else ""))
        self.health_failures = 0
        self.health_ok = None
        self.health_future = None
        start_period = self.service.health.start_period if self.service.health else 0.0
        self.next_health = now + start_period if self.service.health else float("inf")
        self.set("starting" if self.service.health else "running")

    def _record_deploy_proc(self, target: Dict[str, Any]) -> None:
        """Write the new process into deploy/<name>.json (the caller holds the deploy lock)."""
        state = read_deploy(self.sup.manifest, self.service.name)
        current = dict(state.get("current") or {})
        current.update({"slot": target["slot"], "version": target.get("version"), "port": target["port"],
                        "releaseDir": target.get("releaseDir")})
        current.update(self.proc.to_dict() if self.proc else {})
        state["current"] = current
        state.setdefault("service", self.service.name)
        atomic_write_json(deploy_state_path(self.sup.manifest, self.service.name), state)

    def stop(self, reason: str = "stopped") -> None:
        if self.proc is not None:
            self.log(f"stopping pid {self.proc.pid} ({reason})")
            self.proc.stop(self.service.stop_timeout)
            if self.deployable:
                self._forget_deploy_proc()
        self.proc = None
        self.next_start = None
        self.health_ok = None
        self.health_failures = 0
        self.set("stopped", reason)

    def _forget_deploy_proc(self) -> None:
        lock = self._deploy_lock()
        if not lock.acquire(timeout=2.0):
            return
        try:
            state = read_deploy(self.sup.manifest, self.service.name)
            current = state.get("current")
            if isinstance(current, dict) and self.proc and current.get("pgid") == self.proc.pgid:
                for key in ("pid", "pgid", "status"):
                    current.pop(key, None)
                atomic_write_json(deploy_state_path(self.sup.manifest, self.service.name), state)
        finally:
            lock.release()

    def _after_failure(self, now: float, why: str) -> None:
        policy = self.service.restart
        if self.service.every:
            self.next_start = now + self.service.every
            self.set("waiting", f"last run failed ({why}); next run at {iso(self.next_start)}")
            return
        if policy.policy == "never":
            self.set("failed", why)
            return
        self.recent = [t for t in self.recent if now - t < policy.window]
        if len(self.recent) >= policy.max_restarts:
            self.set("failed", f"gave up after {len(self.recent)} restarts in {policy.window:g}s ({why})")
            self.log(self.message)
            return
        delay = policy.delay(len(self.recent) + 1)
        self.recent.append(now)
        self.restarts += 1
        self.next_start = now + delay
        self.set("backoff", f"{why}; restart {self.restarts} in {delay:.2f}s")
        self.log(self.message)

    def _exited(self, now: float, code: Optional[int]) -> None:
        self.proc = None
        self.last_exit, self.last_exit_at = code, now
        self.dirty = True
        if self.service.every:
            self.next_start = now + self.service.every
            self.set("waiting", f"exited {code}; next run at {iso(self.next_start)}")
            return
        policy = self.service.restart.policy
        if code == 0 and policy != "always":
            self.set("exited", "exited 0")
            self.log("exited 0")
            return
        self._after_failure(now, f"exited {code if code is not None else 'without a status'}")

    def tick(self, now: float) -> None:
        if self.proc is None:
            if self.state in ("backoff", "waiting") and self.next_start is not None and now >= self.next_start:
                self.next_start = None
                self.start(now)
            return
        if self.deployable:
            target = read_deploy(self.sup.manifest, self.service.name).get("current") or {}
            if target.get("pgid") and int(target["pgid"]) != self.proc.pgid:
                adopted = Proc.from_dict(target)
                if adopted is not None and adopted.alive():
                    # A deploy switched releases; follow it and leave the old process to the deploy command.
                    if self.proc.popen is not None:
                        self.sup.orphans.append(self.proc.popen)
                    self.proc = adopted
                    self.slot, self.version = target.get("slot"), target.get("version")
                    self.values = self._values({"slot": target.get("slot"), "version": target.get("version"),
                                                "port": target.get("port"), "releaseDir": target.get("releaseDir")})
                    self._began(now, "following deploy:")
                    return
        if not self.proc.alive():
            if self.deployable:
                lock = self._deploy_lock()
                if not lock.acquire(timeout=0.0):
                    return  # a deploy is running; it decides what runs
                lock.release()
            code = self.proc.exit_code()
            self.log(f"pid {self.proc.pid} exited {code}")
            self._exited(now, code)
            return
        self._tick_health(now)

    def _tick_health(self, now: float) -> None:
        h = self.service.health
        if h is None or self.proc is None:
            return
        if self.health_future is not None:
            if not self.health_future.done():
                return
            try:
                ok, detail = self.health_future.result()
            except Exception as exc:  # pragma: no cover - defensive
                ok, detail = False, str(exc)
            self.health_future = None
            self.health_at = now
            self.health_detail = detail
            self.dirty = True
            if ok:
                if self.health_ok is not True:
                    self.log(f"healthy ({detail})")
                self.health_ok = True
                self.health_failures = 0
                self.set("healthy")
            else:
                self.health_ok = False
                self.health_failures += 1
                if self.health_failures >= h.retries:
                    self.log(f"unhealthy {self.health_failures} times ({detail}); restarting")
                    self.proc.stop(self.service.stop_timeout)
                    self.proc = None
                    self.last_exit, self.last_exit_at = None, now
                    self._after_failure(now, f"health check failed: {detail}")
                    return
                # Until a check first passes the service is still starting; retries decide when it fails.
                state = "starting" if self.state == "starting" else "unhealthy"
                self.set(state, f"health check failed {self.health_failures}/{h.retries}: {detail}")
            self.next_health = now + h.interval
            return
        if now >= self.next_health:
            values = dict(self.values)
            env = health_env(self.sup.manifest, self.service, values)
            cwd = str(resolve_cwd(self.sup.manifest, self.service, values))
            self.health_future = self.sup.pool.submit(healthmod.check, h, values, env, cwd)

    def snapshot(self) -> Dict[str, Any]:
        return {"name": self.service.name, "state": self.state, "message": self.message,
                "pid": self.proc.pid if self.proc else None, "pgid": self.proc.pgid if self.proc else None,
                "startedAt": self.proc.started if self.proc else None, "restarts": self.restarts,
                "lastExit": self.last_exit, "lastExitAt": self.last_exit_at, "nextStartAt": self.next_start,
                "port": int(self.values["PORT"]) if self.values.get("PORT") else None, "slot": self.slot, "version": self.version,
                "health": {"ok": self.health_ok, "detail": self.health_detail, "checkedAt": self.health_at, "failures": self.health_failures},
                "log": str(self.sup.manifest.log_path(self.service)), "updatedAt": time.time(), "supervisor": os.getpid()}


# ---------- supervisor ----------

class Supervisor:
    def __init__(self, manifest: Manifest, names: Optional[List[str]] = None, python: str = sys.executable,
                 poll: float = 0.2, out: Optional[Callable[[str], None]] = None):
        self.manifest = manifest
        self.services = manifest.select(names or [])
        self.python = python
        self.poll = poll
        self.out = out or (lambda line: (sys.stdout.write(line + "\n"), sys.stdout.flush()))
        self.stopping = threading.Event()
        self.pool = ThreadPoolExecutor(max_workers=4)
        self.runners = {s.name: Runner(self, s) for s in self.services}
        # Our own children that a deploy took over: reaped here so the deploy sees them exit.
        self.orphans: List[subprocess.Popen] = []

    def say(self, text: str) -> None:
        self.out(f"{iso(time.time())} {text}")

    def _signal(self, signum: int, _frame: Any) -> None:
        self.stopping.set()

    def install_signals(self) -> None:
        for name in ("SIGTERM", "SIGINT", "SIGHUP"):
            if hasattr(signal, name):
                signal.signal(getattr(signal, name), self._signal)

    def _claim(self) -> None:
        other = supervisor_info(self.manifest)
        if other is not None and int(other.get("pid") or 0) != os.getpid():
            raise Failure(f"a supervisor is already running (pid {other['pid']}); use `runtime restart` or `runtime down`",
                          code="RUNTIME_RUNNING")
        atomic_write_json(self.manifest.state_dir / "supervisor.json",
                          {"pid": os.getpid(), "startedAt": time.time(), "manifest": str(self.manifest.path),
                           "services": [s.name for s in self.services]})

    def _controls(self, now: float) -> None:
        folder = self.manifest.state_dir / "control"
        if not folder.is_dir():
            return
        for entry in sorted(folder.iterdir()):
            name, _, action = entry.name.rpartition(".")
            try:
                entry.unlink()
            except OSError:
                continue
            if name == "*":
                targets = list(self.runners.values())
            else:
                runner = self.runners.get(name)
                if runner is None and name in self.manifest.services:
                    runner = self.runners[name] = Runner(self, self.manifest.services[name])
                targets = [runner] if runner else []
            for runner in targets:
                if action in ("stop",):
                    runner.stop("stopped on request")
                elif action in ("restart", "start"):
                    if action == "restart" and runner.proc is not None:
                        runner.stop("restarting on request")
                    if runner.proc is None:
                        runner.recent = []
                        runner.start(now)

    def _write_states(self, force: bool = False) -> None:
        for runner in self.runners.values():
            if runner.dirty or force:
                runner.dirty = False
                atomic_write_json(service_state_path(self.manifest, runner.service.name), runner.snapshot())

    def run(self, install_signals: bool = True) -> int:
        self.manifest.state_dir.mkdir(parents=True, exist_ok=True)
        self._claim()
        if install_signals:
            self.install_signals()
        self.say(f"supervisor {os.getpid()} starting {', '.join(self.runners)}")
        now = time.time()
        for runner in self.runners.values():
            runner.start(now)
        self._write_states(force=True)
        last_full = time.monotonic()
        try:
            while not self.stopping.is_set():
                now = time.time()
                self._controls(now)
                for runner in list(self.runners.values()):
                    runner.tick(now)
                self.orphans = [p for p in self.orphans if p.poll() is None]
                force = time.monotonic() - last_full > 5
                self._write_states(force=force)
                if force:
                    last_full = time.monotonic()
                if not any(r.state in ACTIVE for r in self.runners.values()):
                    self.say("no service is running any more")
                    break
                self.stopping.wait(self.poll)
        finally:
            self.say("supervisor stopping")
            for runner in reversed(list(self.runners.values())):
                if runner.proc is not None or runner.state in ACTIVE:
                    runner.stop("supervisor stopped")
            self._write_states(force=True)
            self.pool.shutdown(wait=False)
            info = read_json(self.manifest.state_dir / "supervisor.json")
            if isinstance(info, dict) and info.get("pid") == os.getpid():
                try:
                    (self.manifest.state_dir / "supervisor.json").unlink()
                except OSError:
                    pass
        return 1 if any(r.state == "failed" for r in self.runners.values()) else 0


def start_background(manifest: Manifest, names: List[str], python: str = sys.executable, wait: float = 5.0) -> Dict[str, Any]:
    """Start `runtime up --foreground` detached, logging to <state>/supervisor.log; returns its supervisor.json."""
    manifest.state_dir.mkdir(parents=True, exist_ok=True)
    package_parent = str(Path(__file__).resolve().parents[2])
    env = dict(os.environ)
    env["PYTHONPATH"] = package_parent + (os.pathsep + env["PYTHONPATH"] if env.get("PYTHONPATH") else "")
    argv = [python, "-m", "gitrochi", "runtime", "up", "--foreground", "--manifest", str(manifest.path),
            "--state-dir", str(manifest.state_dir)] + names
    log = open(manifest.state_dir / "supervisor.log", "ab")
    try:
        popen = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, env=env,
                                 cwd=str(manifest.folder), **procs.detached_kwargs())
    finally:
        log.close()
    _DETACHED.append(popen)
    deadline = time.monotonic() + wait
    while time.monotonic() < deadline:
        info = read_json(manifest.state_dir / "supervisor.json")
        if isinstance(info, dict) and info.get("pid") == popen.pid:
            return info
        if popen.poll() is not None:
            break
        time.sleep(0.05)
    code = popen.poll()
    if code is not None:
        raise Failure(f"the supervisor exited at once (exit {code}); see {manifest.state_dir / 'supervisor.log'}", code="RUNTIME_START")
    return {"pid": popen.pid, "startedAt": time.time(), "manifest": str(manifest.path), "services": names}
