"""`gitrochi-py runtime check|up|down|status|restart|logs|deploy`."""

from __future__ import annotations

import argparse
import os
import shutil
import signal
import sys
import time
from pathlib import Path
from typing import Any, Dict, List

from gitrochi import procs
from gitrochi.runtime import manifest as mf
from gitrochi.runtime import supervisor as sv
from gitrochi.runtime import versions
from gitrochi.runtime.deploy import Deployer
from gitrochi.util import Failure, UsageError, age_text, atomic_write_json, dumps, emit, envelope, read_json, table


def register(sub: Any, common: argparse.ArgumentParser) -> None:
    p = sub.add_parser("runtime", help="run and watch services from gitrochi-runtime.json",
                       description="Supervise services from a JSON manifest: health checks, restart policies with backoff, "
                                   "rotated logs, runtime version checks and blue/green deploys.")
    rsub = p.add_subparsers(dest="runtime_command", metavar="<subcommand>", parser_class=type(p))
    rsub.required = True
    opts = argparse.ArgumentParser(add_help=False)
    opts.add_argument("--manifest", metavar="FILE", help=f"manifest (default: {mf.MANIFEST_NAME} in --repo or the repository root)")
    opts.add_argument("--state-dir", metavar="DIR", help="state folder (default: <git common dir>/gitrochi/runtime/<id>)")

    c = rsub.add_parser("check", parents=[common, opts], help="installed runtimes against the requirements")
    c.set_defaults(func=run_check)
    u = rsub.add_parser("up", parents=[common, opts], help="start the supervisor (in the background unless --foreground)")
    u.add_argument("services", nargs="*")
    u.add_argument("--foreground", action="store_true", help="supervise in this process until SIGTERM / Ctrl-C")
    u.set_defaults(func=run_up)
    d = rsub.add_parser("down", parents=[common, opts], help="stop services (all of them stops the supervisor)")
    d.add_argument("services", nargs="*")
    d.set_defaults(func=run_down)
    s = rsub.add_parser("status", parents=[common, opts], help="state of the supervisor and services")
    s.add_argument("services", nargs="*")
    s.set_defaults(func=run_status)
    r = rsub.add_parser("restart", parents=[common, opts], help="restart services under the running supervisor")
    r.add_argument("services", nargs="*")
    r.set_defaults(func=run_restart)
    lg = rsub.add_parser("logs", parents=[common, opts], help="show a service's log")
    lg.add_argument("service", nargs="?")
    lg.add_argument("--lines", "-n", type=int, default=50)
    lg.add_argument("--follow", "-f", action="store_true", help="keep printing new lines (Ctrl-C to stop)")
    lg.set_defaults(func=run_logs)
    dp = rsub.add_parser("deploy", parents=[common, opts], help="blue/green deploy of a service release")
    dp.add_argument("service")
    dp.add_argument("--version", required=True, help="release to deploy (fills ${VERSION})")
    dp.add_argument("--health-timeout", type=float, help="seconds to wait for the new release to be healthy")
    dp.set_defaults(func=run_deploy)


def _manifest(args: argparse.Namespace) -> mf.Manifest:
    return mf.load(mf.find(args.manifest, args.repo), args.state_dir)


# ---------- check ----------

def run_check(args: argparse.Namespace) -> int:
    manifest = _manifest(args)
    results = versions.check(versions.merge(manifest.requires, list(manifest.services.values())))
    commands = []
    for service in manifest.services.values():
        exe = service.command[0]
        if "${" in exe:
            commands.append({"service": service.name, "executable": exe, "found": None, "path": None})
            continue
        values = manifest.variables(service, port=service.port or 0)
        cwd = None
        if "${" not in service.cwd:
            cwd = sv.resolve_cwd(manifest, service, values)
        path = None
        if os.sep in exe or "/" in exe:
            candidate = Path(exe) if Path(exe).is_absolute() else (cwd or manifest.folder) / exe
            path = str(candidate) if candidate.is_file() else None
        else:
            path = shutil.which(exe)
        commands.append({"service": service.name, "executable": exe, "found": path is not None, "path": path})
    ok = all(r["ok"] for r in results) and all(c["found"] is not False for c in commands)
    doc = envelope("runtime check", manifest=str(manifest.path), ok=ok, requirements=results, commands=commands)
    if args.json:
        emit(dumps(doc))
        return 0 if ok else 1
    rows = [(r["tool"], r["required"], r["version"] or "-", "ok" if r["ok"] else "FAIL", r["error"] or "") for r in results]
    lines = [table(rows, ["tool", "required", "found", "", "problem"]) if rows else "no runtime requirements"]
    missing = [c for c in commands if c["found"] is False]
    for c in missing:
        lines.append(f"FAIL {c['service']}: {c['executable']} not found")
    lines.append("All requirements are met." if ok else "Some requirements are not met.")
    emit("\n".join(lines))
    return 0 if ok else 1


# ---------- status ----------

def _status(manifest: mf.Manifest, names: List[str]) -> Dict[str, Any]:
    info = sv.supervisor_info(manifest)
    services = []
    for service in manifest.select(names):
        state = read_json(sv.service_state_path(manifest, service.name), {}) or {}
        entry = {"name": service.name, "state": state.get("state") or "stopped", "message": state.get("message") or "",
                 "pid": state.get("pid"), "port": state.get("port"), "restarts": state.get("restarts", 0),
                 "lastExit": state.get("lastExit"), "health": state.get("health"), "startedAt": state.get("startedAt"),
                 "log": str(manifest.log_path(service)), "slot": state.get("slot"), "version": state.get("version")}
        if entry["state"] in sv.ACTIVE and (info is None or not procs.pid_alive(int(state.get("supervisor") or 0))):
            alive = procs.group_alive(int(state.get("pgid") or 0))
            entry["state"] = "orphaned" if alive else "dead"
            entry["message"] = "the supervisor is gone" + ("; the process still runs" if alive else "")
        if service.deploy is not None:
            dep = sv.read_deploy(manifest, service.name)
            current = dep.get("current") or None
            entry["deploy"] = {
                "current": {k: current.get(k) for k in ("version", "slot", "port", "pid")} if current else None,
                "previous": {k: (dep.get("previous") or {}).get(k) for k in ("version", "slot", "port")} if dep.get("previous") else None,
                "running": bool(current and procs.group_alive(int(current.get("pgid") or 0))),
                "last": (dep.get("history") or [None])[-1],
            }
        services.append(entry)
    return {"supervisor": {"running": info is not None, "pid": info.get("pid") if info else None,
                           "startedAt": info.get("startedAt") if info else None},
            "stateDir": str(manifest.state_dir), "services": services}


def _print_status(args: argparse.Namespace, command: str, data: Dict[str, Any], code: int = 0) -> int:
    doc = envelope(command, **data)
    if args.json:
        emit(dumps(doc))
        return code
    sup = data["supervisor"]
    now = time.time()
    lines = [f"supervisor: {'running (pid ' + str(sup['pid']) + ')' if sup['running'] else 'not running'}"]
    rows = []
    for s in data["services"]:
        health = s.get("health") or {}
        hp = "-" if health.get("ok") is None else ("ok" if health.get("ok") else "failing")
        since = age_text(now - s["startedAt"]) if s.get("startedAt") else "-"
        dep = s.get("deploy") or {}
        cur = dep.get("current") or {}
        release = f"{cur.get('version')}@{cur.get('slot')}" if cur else "-"
        rows.append((s["name"], s["state"], s.get("pid") or "-", s.get("port") or "-", hp, s.get("restarts", 0), since, release, s.get("message") or ""))
    lines.append(table(rows, ["service", "state", "pid", "port", "health", "restarts", "up", "release", "note"], "llrrlrrll"))
    for note in data.get("notes") or []:
        lines.append(f"Note: {note}")
    emit("\n".join(lines))
    return code


def run_status(args: argparse.Namespace) -> int:
    manifest = _manifest(args)
    return _print_status(args, "runtime status", _status(manifest, args.services))


# ---------- up / down / restart ----------

def _wait_states(manifest: mf.Manifest, names: List[str], pid: int, timeout: float) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        ready = True
        for name in names:
            state = read_json(sv.service_state_path(manifest, name), {}) or {}
            if state.get("supervisor") != pid or state.get("state") in (None, "stopped"):
                ready = False
        if ready:
            return
        time.sleep(0.1)


def run_up(args: argparse.Namespace) -> int:
    manifest = _manifest(args)
    names = [s.name for s in manifest.select(args.services)]
    if args.foreground:
        return sv.Supervisor(manifest, names).run()
    info = sv.supervisor_info(manifest)
    notes = []
    if info is not None:
        for name in names:
            sv.request(manifest, name, "start")
        notes.append(f"the supervisor was already running (pid {info['pid']}); asked it to start {', '.join(names)}")
        time.sleep(0.5)
    else:
        info = sv.start_background(manifest, names)
        _wait_states(manifest, names, int(info["pid"]), 5.0)
        notes.append(f"supervisor log: {manifest.state_dir / 'supervisor.log'}")
    data = _status(manifest, names)
    data["notes"] = notes
    return _print_status(args, "runtime up", data)


def run_down(args: argparse.Namespace) -> int:
    manifest = _manifest(args)
    names = [s.name for s in manifest.select(args.services)]
    info = sv.supervisor_info(manifest)
    notes: List[str] = []
    grace = max([s.stop_timeout for s in manifest.select(args.services)] + [1.0]) + 5
    if info is not None and args.services:
        for name in names:
            sv.request(manifest, name, "stop")
        deadline = time.monotonic() + grace
        while time.monotonic() < deadline:
            states = [(read_json(sv.service_state_path(manifest, n), {}) or {}).get("state") for n in names]
            if all(s in ("stopped", None) for s in states) or not procs.pid_alive(int(info["pid"])):
                break
            time.sleep(0.1)
    elif info is not None:
        pid = int(info["pid"])
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
        deadline = time.monotonic() + grace
        while time.monotonic() < deadline and procs.pid_alive(pid):
            time.sleep(0.1)
        if procs.pid_alive(pid):
            notes.append(f"the supervisor (pid {pid}) did not stop within {grace:g}s")
    else:
        stopped = 0
        for service in manifest.select(args.services):
            state = read_json(sv.service_state_path(manifest, service.name), {}) or {}
            groups = {int(state.get("pgid") or 0)}
            if service.deploy is not None:
                current = sv.read_deploy(manifest, service.name).get("current") or {}
                groups.add(int(current.get("pgid") or 0))
            for pgid in groups:
                if pgid and procs.group_alive(pgid):
                    procs.stop_group(pgid, grace=service.stop_timeout)
                    stopped += 1
            if state:
                state.update({"state": "stopped", "message": "stopped without a supervisor", "pid": None, "pgid": None})
                atomic_write_json(sv.service_state_path(manifest, service.name), state)
        notes.append(f"no supervisor was running; stopped {stopped} process group(s) left behind" if stopped else "nothing was running")
    sv.prune_detached()
    data = _status(manifest, names)
    data["notes"] = notes
    still = [s["name"] for s in data["services"] if s["state"] in sv.ACTIVE or s["state"] == "orphaned"]
    return _print_status(args, "runtime down", data, 1 if still else 0)


def run_restart(args: argparse.Namespace) -> int:
    manifest = _manifest(args)
    names = [s.name for s in manifest.select(args.services)]
    info = sv.supervisor_info(manifest)
    if info is None:
        raise Failure("the supervisor is not running (start it with `runtime up`)", code="RUNTIME_NOT_RUNNING")
    before = {n: (read_json(sv.service_state_path(manifest, n), {}) or {}).get("startedAt") for n in names}
    for name in names:
        sv.request(manifest, name, "restart")
    deadline = time.monotonic() + max([s.stop_timeout for s in manifest.select(args.services)] + [1.0]) + 5
    while time.monotonic() < deadline:
        now_states = {n: read_json(sv.service_state_path(manifest, n), {}) or {} for n in names}
        if all(s.get("startedAt") and s.get("startedAt") != before[n] for n, s in now_states.items()):
            break
        time.sleep(0.1)
    return _print_status(args, "runtime restart", _status(manifest, names))


# ---------- logs ----------

def _tail(path: Path, lines: int) -> List[str]:
    try:
        with open(path, "rb") as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            block = 65536
            data = b""
            while size > 0 and data.count(b"\n") <= lines:
                step = min(block, size)
                size -= step
                handle.seek(size)
                data = handle.read(step) + data
    except OSError:
        return []
    return data.decode("utf-8", "replace").splitlines()[-lines:] if lines > 0 else []


def run_logs(args: argparse.Namespace) -> int:
    manifest = _manifest(args)
    services = manifest.select([args.service] if args.service else [])
    if args.follow and len(services) != 1:
        raise UsageError("--follow needs one service")
    if args.json:
        doc = envelope("runtime logs", services=[{"name": s.name, "file": str(manifest.log_path(s)),
                                                  "lines": _tail(manifest.log_path(s), args.lines)} for s in services])
        emit(dumps(doc))
        return 0
    out = []
    for service in services:
        path = manifest.log_path(service)
        if len(services) > 1:
            out.append(f"==> {service.name} ({path}) <==")
        out += _tail(path, args.lines)
    if out:
        emit("\n".join(out))
    if args.follow:
        _follow(manifest.log_path(services[0]))
    return 0


def _follow(path: Path) -> None:
    """Print what is appended to the log; after a rotation, finish the old file and continue in the new one."""
    handle = None
    inode = None

    def write(data: bytes) -> None:
        sys.stdout.write(data.decode("utf-8", "replace"))
        sys.stdout.flush()

    try:
        while True:
            try:
                stat = path.stat()
            except OSError:
                time.sleep(0.5)
                continue
            if handle is None:
                handle = open(path, "rb")
                handle.seek(0, os.SEEK_END)
                inode = stat.st_ino
            elif stat.st_ino != inode or stat.st_size < handle.tell():
                rest = handle.read()
                if rest:
                    write(rest)
                handle.close()
                handle = open(path, "rb")
                inode = stat.st_ino
            chunk = handle.read()
            if chunk:
                write(chunk)
            else:
                time.sleep(0.25)
    except KeyboardInterrupt:
        pass
    finally:
        if handle is not None:
            handle.close()


# ---------- deploy ----------

def run_deploy(args: argparse.Namespace) -> int:
    manifest = _manifest(args)
    lines: List[str] = []
    printer = (lambda line: None) if args.json else (lambda line: (print(line), sys.stdout.flush()))
    result = Deployer(manifest, args.service, out=printer).run(args.version, args.health_timeout)
    if not result.get("supervisor") and result["result"] == "deployed":
        result.setdefault("notes", []).append("no supervisor is running: the new release is not restarted if it stops (run `runtime up`)")
    doc = envelope("runtime deploy", **result)
    if args.json:
        emit(dumps(doc))
    else:
        lines.append(f"{args.service} {args.version}: {result['result']}")
        for note in result.get("notes") or []:
            lines.append(f"Note: {note}")
        emit("\n".join(lines))
    return 0 if result["result"] == "deployed" else 1
