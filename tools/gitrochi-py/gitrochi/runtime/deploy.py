"""Blue/green deploys on one host: start the new release on the other slot, wait until healthy, switch, stop the old.

If the new release never becomes healthy it is stopped and the old one keeps serving (rollback). If it fails
the check right after the switch, the old release is started again on its slot and the switch is undone.
deploy/<service>.json is the source of truth; a running supervisor follows its `current` entry.
"""

from __future__ import annotations

import os
import socket
import sys
import time
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

from gitrochi.runtime import health as healthmod
from gitrochi.runtime import manifest as mf
from gitrochi.runtime.manifest import Manifest, Service
from gitrochi.runtime.supervisor import (FileLock, Proc, deploy_state_path, prune_detached, read_deploy, resolve_cwd, spawn,
                                         supervisor_info)
from gitrochi.util import Failure, atomic_write_json, iso

HISTORY = 20


def port_busy(port: int, host: str = "127.0.0.1") -> bool:
    try:
        with socket.create_connection((host, port), timeout=0.3):
            return True
    except OSError:
        return False


def release_dir(manifest: Manifest, service: Service, version: str) -> Optional[Path]:
    assert service.deploy is not None
    if not service.deploy.release:
        return None
    path = Path(mf.expand(service.deploy.release, {"VERSION": version, "SERVICE": service.name}))
    return path if path.is_absolute() else (manifest.folder / path).resolve()


def switch_link(manifest: Manifest, service: Service, target: Optional[Path]) -> Optional[str]:
    """Point <state>/deploy/<service>/current at the release folder (a text file where symlinks are not allowed)."""
    if target is None:
        return None
    folder = manifest.state_dir / "deploy" / service.name
    folder.mkdir(parents=True, exist_ok=True)
    link = folder / "current"
    tmp = folder / f".current.{os.getpid()}"
    try:
        if tmp.is_symlink() or tmp.exists():
            tmp.unlink()
        os.symlink(str(target), str(tmp), target_is_directory=True)
        os.replace(str(tmp), str(link))
        return str(link)
    except (OSError, NotImplementedError):  # pragma: no cover - Windows without symlink rights
        (folder / "current.txt").write_text(str(target) + "\n", encoding="utf-8")
        return str(folder / "current.txt")


class Deployer:
    def __init__(self, manifest: Manifest, service_name: str, python: str = sys.executable,
                 out: Optional[Callable[[str], None]] = None):
        if service_name not in manifest.services:
            raise Failure(f"unknown service {service_name!r}", code="MANIFEST")
        self.manifest = manifest
        self.service = manifest.services[service_name]
        if self.service.deploy is None:
            raise Failure(f"{service_name} has no deploy section (slots and release) in the manifest", code="NOT_DEPLOYABLE")
        self.python = python
        self.out = out or (lambda line: None)
        self.steps: List[Dict[str, Any]] = []

    def step(self, name: str, ok: bool, detail: str = "") -> None:
        self.steps.append({"step": name, "ok": ok, "detail": detail, "at": iso(time.time())})
        self.out(f"{'ok  ' if ok else 'FAIL'} {name}{': ' + detail if detail else ''}")

    def _values(self, slot: str, version: Optional[str], rel: Optional[Path]) -> Dict[str, str]:
        dep = self.service.deploy
        assert dep is not None
        return self.manifest.variables(self.service, port=dep.slots[slot], version=version,
                                       release_dir=str(rel) if rel else None, slot=slot)

    def _start(self, slot: str, version: Optional[str], rel: Optional[Path], timeout: float):
        values = self._values(slot, version, rel)
        proc = spawn(self.manifest, self.service, values, detached=True, python=self.python)
        env = mf.child_env(self.service, values)
        cwd = str(resolve_cwd(self.manifest, self.service, values))
        ok, detail, attempts = healthmod.wait_healthy(self.service.health, values, time.monotonic() + timeout, proc.alive, env, cwd)
        return proc, values, ok, detail, attempts

    def _verify(self, values: Dict[str, str], proc: Proc, tries: int = 3) -> Tuple[bool, str]:
        if self.service.health is None:
            return proc.alive(), "process is running" if proc.alive() else "process exited"
        detail = ""
        env = mf.child_env(self.service, values)
        cwd = str(resolve_cwd(self.manifest, self.service, values))
        for _ in range(tries):
            if not proc.alive():
                return False, "the new release exited after the switch"
            ok, detail = healthmod.check(self.service.health, values, env, cwd)
            if ok:
                return True, detail
            time.sleep(0.3)
        return False, detail

    def run(self, version: str, health_timeout: Optional[float] = None) -> Dict[str, Any]:
        dep = self.service.deploy
        assert dep is not None
        if not version or "/" in version or "\\" in version or version.startswith("."):
            raise Failure(f"bad version {version!r}", code="USAGE")
        lock = FileLock(deploy_state_path(self.manifest, self.service.name).with_suffix(".lock"))
        if not lock.acquire(timeout=30):
            raise Failure(f"another deploy of {self.service.name} is running", code="DEPLOY_LOCKED")
        try:
            return self._run(version, health_timeout or dep.health_timeout)
        finally:
            lock.release()
            prune_detached()

    def _run(self, version: str, timeout: float) -> Dict[str, Any]:
        dep = self.service.deploy
        assert dep is not None
        state = read_deploy(self.manifest, self.service.name)
        state["service"] = self.service.name
        current = state.get("current") if isinstance(state.get("current"), dict) else None
        old_proc = Proc.from_dict(current) if current else None
        old_alive = bool(old_proc and old_proc.alive())
        slots = list(dep.slots)
        old_slot = current.get("slot") if current and current.get("slot") in dep.slots else None
        new_slot = (slots[1] if old_slot == slots[0] else slots[0]) if old_slot else slots[0]
        if old_slot and not old_alive:
            new_slot = old_slot if not port_busy(dep.slots[old_slot]) else new_slot
        rel = release_dir(self.manifest, self.service, version)
        result: Dict[str, Any] = {"service": self.service.name, "version": version, "result": "failed",
                                  "from": _brief(current) if current else None, "to": None, "health": None, "steps": self.steps,
                                  "symlink": None, "supervisor": bool(supervisor_info(self.manifest))}
        if rel is not None and not rel.is_dir():
            self.step("find release", False, f"{rel} does not exist")
            self._history(state, version, new_slot, "failed", f"release folder {rel} does not exist")
            return result
        self.step("find release", True, str(rel) if rel else "no release folder (same command, new slot)")
        port = dep.slots[new_slot]
        if port_busy(port) and not (old_alive and new_slot == old_slot):
            self.step("check port", False, f"port {port} for slot {new_slot} is already in use")
            self._history(state, version, new_slot, "failed", f"port {port} in use")
            return result
        self.step("check port", True, f"slot {new_slot} on port {port}")
        try:
            new_proc, values, ok, detail, attempts = self._start(new_slot, version, rel, timeout)
        except Failure as exc:
            self.step("start new release", False, exc.message)
            self._history(state, version, new_slot, "failed", exc.message)
            return result
        result["to"] = {"version": version, "slot": new_slot, "port": port, "pid": new_proc.pid}
        result["health"] = {"ok": ok, "detail": detail, "attempts": attempts}
        if not ok:
            self.step("health check", False, detail)
            new_proc.stop(self.service.stop_timeout)
            self.step("roll back", True, "stopped the new release; " + (f"{current.get('version')} keeps serving" if old_alive and current else "nothing was serving before"))
            result["result"] = "rolled_back"
            self._history(state, version, new_slot, "rolled_back", detail)
            return result
        self.step("health check", True, f"{detail} after {attempts} check(s)")
        new_current = {"version": version, "slot": new_slot, "port": port, "releaseDir": str(rel) if rel else None,
                       "deployedAt": time.time()}
        new_current.update(new_proc.to_dict())
        previous = dict(current) if current else None
        state["previous"] = previous
        state["current"] = new_current
        atomic_write_json(deploy_state_path(self.manifest, self.service.name), state)
        result["symlink"] = switch_link(self.manifest, self.service, rel)
        self.step("switch", True, f"current -> {version} (slot {new_slot}, port {port})")
        if old_alive and old_proc is not None and old_proc.pgid != new_proc.pgid:
            old_proc.stop(self.service.stop_timeout)
            self.step("stop old release", True, f"{previous.get('version') if previous else '?'} (pid {old_proc.pid})")
        ok_after, detail_after = self._verify(values, new_proc)
        if ok_after:
            self.step("verify", True, detail_after)
            result["result"] = "deployed"
            self._history(state, version, new_slot, "deployed", detail_after)
            return result
        self.step("verify", False, detail_after)
        return self._undo(state, result, previous, new_proc, version, new_slot, detail_after)

    def _undo(self, state: Dict[str, Any], result: Dict[str, Any], previous: Optional[Dict[str, Any]], new_proc: Proc,
              version: str, new_slot: str, why: str) -> Dict[str, Any]:
        dep = self.service.deploy
        assert dep is not None
        if not previous or not previous.get("slot") or (dep.release and not previous.get("version")):
            self.step("roll back", False, "there is no earlier release to go back to; the new release keeps running")
            self._history(state, version, new_slot, "failed", why)
            return result
        old_version = previous.get("version")
        old_rel = Path(previous["releaseDir"]) if previous.get("releaseDir") else None
        new_proc.stop(self.service.stop_timeout)
        try:
            proc, _values, ok, detail, _ = self._start(previous["slot"], old_version, old_rel, dep.health_timeout)
        except Failure as exc:
            ok, detail, proc = False, exc.message, None
        if not ok or proc is None:
            if proc is not None:
                proc.stop(self.service.stop_timeout)
            self.step("roll back", False, f"{old_version} did not come back: {detail}")
            state["current"] = None
            self._history(state, version, new_slot, "failed", f"{why}; rollback failed: {detail}")
            return result
        restored = dict(previous)
        restored.update(proc.to_dict())
        state["current"] = restored
        state["previous"] = {k: v for k, v in (result.get("to") or {}).items() if k != "pid"}
        atomic_write_json(deploy_state_path(self.manifest, self.service.name), state)
        result["symlink"] = switch_link(self.manifest, self.service, old_rel)
        self.step("roll back", True, f"{old_version} serves again on slot {previous['slot']}")
        result["result"] = "rolled_back"
        self._history(state, version, new_slot, "rolled_back", why)
        return result

    def _history(self, state: Dict[str, Any], version: str, slot: str, outcome: str, detail: str) -> None:
        history = state.get("history") if isinstance(state.get("history"), list) else []
        history.append({"at": time.time(), "version": version, "slot": slot, "result": outcome, "detail": detail[:500]})
        state["history"] = history[-HISTORY:]
        atomic_write_json(deploy_state_path(self.manifest, self.service.name), state)


def _brief(entry: Dict[str, Any]) -> Dict[str, Any]:
    return {"version": entry.get("version"), "slot": entry.get("slot"), "port": entry.get("port"), "pid": entry.get("pid")}
