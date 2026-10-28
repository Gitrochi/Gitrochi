"""The runtime manifest (`gitrochi-runtime.json`): services, health checks, restart policies, logs and requirements.

Values never hold secrets: `env` is for plain settings, and `passEnv` names variables that are copied from the
supervisor's own environment. Strings may use ${PORT}, ${SERVICE}, ${VERSION}, ${RELEASE_DIR}, ${SLOT},
${STATE_DIR} and ${MANIFEST_DIR}.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shlex
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional

from gitrochi import gitutil, redact
from gitrochi.util import Failure

MANIFEST_NAME = "gitrochi-runtime.json"
VARIABLES = {"PORT", "SERVICE", "VERSION", "RELEASE_DIR", "SLOT", "STATE_DIR", "MANIFEST_DIR"}
POLICIES = ("always", "on-failure", "never")
_VAR = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")
_SECRET_NAME = re.compile(r"(?i)(token|secret|passw(or)?d|api[_\-]?key|private[_\-]?key|credential)")
_ENV_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
BASE_ENV = ("PATH", "HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE", "TZ", "TMPDIR", "TEMP", "TMP", "SHELL",
            "SYSTEMROOT", "SYSTEMDRIVE", "COMSPEC", "PATHEXT", "WINDIR", "APPDATA", "LOCALAPPDATA", "USERPROFILE", "PROGRAMDATA")


class ManifestError(Failure):
    def __init__(self, message: str):
        super().__init__(message, code="MANIFEST")


@dataclass
class Health:
    http: Optional[str] = None
    command: Optional[List[str]] = None
    tcp: Optional[str] = None
    interval: float = 10.0
    timeout: float = 5.0
    retries: int = 3
    start_period: float = 5.0

    def to_dict(self) -> Dict[str, Any]:
        return {"http": self.http, "command": self.command, "tcp": self.tcp, "interval": self.interval, "timeout": self.timeout,
                "retries": self.retries, "startPeriod": self.start_period}


@dataclass
class Restart:
    policy: str = "on-failure"
    max_restarts: int = 5
    window: float = 300.0
    initial: float = 1.0
    maximum: float = 60.0
    factor: float = 2.0

    def delay(self, attempt: int) -> float:
        """Backoff before restart number `attempt` (1-based)."""
        return min(self.maximum, self.initial * (self.factor ** max(0, attempt - 1)))


@dataclass
class Deploy:
    slots: Dict[str, int]
    release: Optional[str] = None
    health_timeout: float = 60.0


@dataclass
class Service:
    name: str
    command: List[str]
    cwd: str = "."
    env: Dict[str, str] = field(default_factory=dict)
    pass_env: List[str] = field(default_factory=list)
    port: Optional[int] = None
    health: Optional[Health] = None
    restart: Restart = field(default_factory=Restart)
    log_file: Optional[str] = None
    log_max_bytes: int = 10 * 1024 * 1024
    log_keep: int = 5
    stop_timeout: float = 10.0
    every: Optional[float] = None
    requires: Dict[str, str] = field(default_factory=dict)
    deploy: Optional[Deploy] = None


@dataclass
class Manifest:
    path: Path
    services: Dict[str, Service]
    requires: Dict[str, str]
    state_dir: Path

    @property
    def folder(self) -> Path:
        return self.path.parent

    def select(self, names: List[str]) -> List[Service]:
        if not names:
            return list(self.services.values())
        unknown = [n for n in names if n not in self.services]
        if unknown:
            raise ManifestError(f"unknown service(s): {', '.join(unknown)} (manifest has {', '.join(self.services) or 'none'})")
        return [self.services[n] for n in names]

    def variables(self, service: Service, port: Optional[int] = None, version: Optional[str] = None,
                  release_dir: Optional[str] = None, slot: Optional[str] = None) -> Dict[str, str]:
        values = {"SERVICE": service.name, "STATE_DIR": str(self.state_dir), "MANIFEST_DIR": str(self.folder)}
        chosen = port if port is not None else service.port
        if chosen is not None:
            values["PORT"] = str(chosen)
        if version is not None:
            values["VERSION"] = version
        if release_dir is not None:
            values["RELEASE_DIR"] = release_dir
        if slot is not None:
            values["SLOT"] = slot
        return values

    def log_path(self, service: Service) -> Path:
        name = service.log_file or f"logs/{service.name}.log"
        path = Path(expand(name, self.variables(service), strict=False))
        return path if path.is_absolute() else self.state_dir / path


def expand(text: str, values: Dict[str, str], strict: bool = True) -> str:
    def repl(match: "re.Match[str]") -> str:
        name = match.group(1)
        if name in values:
            return values[name]
        if strict:
            raise ManifestError(f"${{{name}}} has no value here" + ("" if name in VARIABLES else f" (known: {', '.join(sorted(VARIABLES))})"))
        return match.group(0)
    return _VAR.sub(repl, text)


def child_env(service: Service, values: Dict[str, str], source: Optional[Dict[str, str]] = None) -> Dict[str, str]:
    """The environment of a service: a small base, the manifest's plain values, the passEnv names, and PORT etc."""
    src = os.environ if source is None else source
    env = {k: src[k] for k in BASE_ENV if k in src}
    for name in service.pass_env:
        if name in src:
            env[name] = src[name]
    for key, value in service.env.items():
        env[key] = expand(value, values)
    for key in ("PORT", "SERVICE", "VERSION", "RELEASE_DIR", "SLOT"):
        if key in values:
            env[key if key != "SERVICE" else "GITROCHI_SERVICE"] = values[key]
    return env


def _number(data: Dict[str, Any], key: str, default: float, where: str, minimum: float = 0.0) -> float:
    value = data.get(key, default)
    if isinstance(value, bool) or not isinstance(value, (int, float)) or value < minimum:
        raise ManifestError(f"{where}.{key} must be a number >= {minimum}")
    return float(value)


def _check_vars(text: str, where: str) -> None:
    for name in _VAR.findall(text):
        if name not in VARIABLES:
            raise ManifestError(f"{where}: unknown variable ${{{name}}} (known: {', '.join(sorted(VARIABLES))})")


def _command(value: Any, where: str) -> List[str]:
    if isinstance(value, str):
        if not value.strip():
            raise ManifestError(f"{where} is empty")
        return shlex.split(value, posix=os.name != "nt")
    if isinstance(value, list) and value and all(isinstance(v, str) and v for v in value):
        return list(value)
    raise ManifestError(f"{where} must be a non-empty list of strings")


def _parse_service(name: str, data: Any) -> Service:
    where = f"services.{name}"
    if not re.match(r"^[A-Za-z0-9][A-Za-z0-9_.\-]{0,62}$", name):
        raise ManifestError(f"{where}: service names use letters, digits, '.', '_' and '-'")
    if not isinstance(data, dict):
        raise ManifestError(f"{where} must be an object")
    known = {"command", "cwd", "env", "passEnv", "envFrom", "port", "health", "restart", "log", "stopTimeout", "every",
             "requires", "deploy", "description"}
    extra = [k for k in data if k not in known and not k.startswith("x-")]
    if extra:
        raise ManifestError(f"{where}: unknown keys {', '.join(sorted(extra))}")
    command = _command(data.get("command"), f"{where}.command")
    for part in command:
        _check_vars(part, f"{where}.command")
    env_raw = data.get("env") or {}
    if not isinstance(env_raw, dict):
        raise ManifestError(f"{where}.env must be an object")
    env: Dict[str, str] = {}
    for key, value in env_raw.items():
        if not _ENV_NAME.match(str(key)):
            raise ManifestError(f"{where}.env: {key!r} is not a variable name")
        if not isinstance(value, (str, int, float)) or isinstance(value, bool):
            raise ManifestError(f"{where}.env.{key} must be a string or number")
        text = str(value)
        if _SECRET_NAME.search(str(key)) and text:
            raise ManifestError(f"{where}.env.{key}: secrets do not belong in the manifest; list the variable name in passEnv instead")
        if redact.find_secrets(text, entropy_check=False):
            raise ManifestError(f"{where}.env.{key} looks like a secret; list the variable name in passEnv instead")
        _check_vars(text, f"{where}.env.{key}")
        env[str(key)] = text
    pass_env = data.get("passEnv", data.get("envFrom", [])) or []
    if not isinstance(pass_env, list) or not all(isinstance(n, str) and _ENV_NAME.match(n) for n in pass_env):
        raise ManifestError(f"{where}.passEnv must be a list of variable names")
    port = data.get("port")
    if port is not None and (isinstance(port, bool) or not isinstance(port, int) or not 0 < port < 65536):
        raise ManifestError(f"{where}.port must be a TCP port")
    health = None
    if data.get("health") is not None:
        h = data["health"]
        if not isinstance(h, dict) or sum(1 for k in ("http", "command", "tcp") if h.get(k)) != 1:
            raise ManifestError(f"{where}.health needs exactly one of http, command or tcp")
        http = h.get("http")
        if http is not None:
            if not isinstance(http, str) or not re.match(r"^https?://", http):
                raise ManifestError(f"{where}.health.http must be an http(s) URL")
            _check_vars(http, f"{where}.health.http")
        tcp = h.get("tcp")
        if tcp is not None:
            if not isinstance(tcp, str) or ":" not in tcp:
                raise ManifestError(f"{where}.health.tcp must be host:port")
            _check_vars(tcp, f"{where}.health.tcp")
        hc = _command(h["command"], f"{where}.health.command") if h.get("command") else None
        health = Health(http=http, command=hc, tcp=tcp, interval=_number(h, "interval", 10.0, f"{where}.health", 0.05),
                        timeout=_number(h, "timeout", 5.0, f"{where}.health", 0.05),
                        retries=int(_number(h, "retries", 3, f"{where}.health", 1)),
                        start_period=_number(h, "startPeriod", 5.0, f"{where}.health"))
    r = data.get("restart") or {}
    if isinstance(r, str):
        r = {"policy": r}
    if not isinstance(r, dict):
        raise ManifestError(f"{where}.restart must be an object or a policy name")
    policy = r.get("policy", "on-failure")
    if policy not in POLICIES:
        raise ManifestError(f"{where}.restart.policy must be one of {', '.join(POLICIES)}")
    backoff = r.get("backoff") or {}
    if not isinstance(backoff, dict):
        raise ManifestError(f"{where}.restart.backoff must be an object")
    restart = Restart(policy=policy, max_restarts=int(_number(r, "maxRestarts", 5, f"{where}.restart")),
                      window=_number(r, "window", 300.0, f"{where}.restart", 1.0),
                      initial=_number(backoff, "initial", 1.0, f"{where}.restart.backoff", 0.0),
                      maximum=_number(backoff, "max", 60.0, f"{where}.restart.backoff", 0.0),
                      factor=_number(backoff, "factor", 2.0, f"{where}.restart.backoff", 1.0))
    log = data.get("log") or {}
    if isinstance(log, str):
        log = {"file": log}
    if not isinstance(log, dict):
        raise ManifestError(f"{where}.log must be an object or a file name")
    requires = data.get("requires") or {}
    if not isinstance(requires, dict) or not all(isinstance(v, str) for v in requires.values()):
        raise ManifestError(f"{where}.requires must map tool names to version requirements")
    deploy = None
    if data.get("deploy") is not None:
        d = data["deploy"]
        if not isinstance(d, dict):
            raise ManifestError(f"{where}.deploy must be an object")
        slots = d.get("slots")
        if isinstance(slots, list) and len(slots) == 2:
            slots = {"blue": slots[0], "green": slots[1]}
        if (not isinstance(slots, dict) or len(slots) != 2
                or not all(isinstance(p, int) and not isinstance(p, bool) and 0 < p < 65536 for p in slots.values())
                or len(set(slots.values())) != 2):
            raise ManifestError(f"{where}.deploy.slots needs two different ports, e.g. {{\"blue\": 8787, \"green\": 8788}}")
        release = d.get("release")
        if release is not None:
            if not isinstance(release, str) or not release:
                raise ManifestError(f"{where}.deploy.release must be a folder template such as releases/${{VERSION}}")
            _check_vars(release, f"{where}.deploy.release")
        deploy = Deploy(slots={str(k): int(v) for k, v in slots.items()}, release=release,
                        health_timeout=_number(d, "healthTimeout", 60.0, f"{where}.deploy", 1.0))
    every = data.get("every")
    if every is not None:
        every = _number(data, "every", 0, where, 0.1)
    cwd = data.get("cwd", ".")
    if not isinstance(cwd, str):
        raise ManifestError(f"{where}.cwd must be a string")
    _check_vars(cwd, f"{where}.cwd")
    return Service(name=name, command=command, cwd=cwd, env=env, pass_env=list(pass_env), port=port, health=health,
                   restart=restart, log_file=log.get("file"), log_max_bytes=int(_number(log, "maxBytes", 10 * 1024 * 1024, f"{where}.log", 1024)),
                   log_keep=int(_number(log, "keep", 5, f"{where}.log")), stop_timeout=_number(data, "stopTimeout", 10.0, where, 0.1),
                   every=every, requires={str(k): str(v) for k, v in requires.items()}, deploy=deploy)


def default_state_dir(manifest_path: Path) -> Path:
    digest = hashlib.sha256(str(manifest_path.resolve()).encode("utf-8")).hexdigest()[:12]
    root = gitutil.try_repo_root(manifest_path.parent)
    if root is not None:
        try:
            return gitutil.common_dir(root) / "gitrochi" / "runtime" / digest
        except Failure:
            pass
    return manifest_path.parent / ".gitrochi-runtime"


def find(path: Optional[str], repo: str = ".") -> Path:
    if path:
        candidate = Path(path)
        if not candidate.is_file():
            raise ManifestError(f"no manifest at {candidate}")
        return candidate.resolve()
    root = gitutil.try_repo_root(Path(repo)) or Path(repo)
    for folder in (Path(repo), root):
        candidate = Path(folder) / MANIFEST_NAME
        if candidate.is_file():
            return candidate.resolve()
    raise ManifestError(f"no {MANIFEST_NAME} in {Path(repo).resolve()} (pass --manifest FILE)")


def load(path: Path, state_dir: Optional[str] = None) -> Manifest:
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except OSError as exc:
        raise ManifestError(f"cannot read {path}: {exc}")
    except ValueError as exc:
        raise ManifestError(f"{path} is not valid JSON: {exc}")
    if not isinstance(data, dict):
        raise ManifestError(f"{path} must hold a JSON object")
    if data.get("version", 1) != 1:
        raise ManifestError(f"{path}: manifest version {data.get('version')} is not supported (expected 1)")
    extra = [k for k in data if k not in ("version", "services", "requires", "stateDir", "description") and not k.startswith("x-")]
    if extra:
        raise ManifestError(f"{path}: unknown keys {', '.join(sorted(extra))}")
    services_raw = data.get("services") or {}
    if not isinstance(services_raw, dict) or not services_raw:
        raise ManifestError(f"{path}: 'services' must name at least one service")
    services = {name: _parse_service(name, value) for name, value in services_raw.items()}
    requires = data.get("requires") or {}
    if not isinstance(requires, dict) or not all(isinstance(v, str) for v in requires.values()):
        raise ManifestError(f"{path}: 'requires' must map tool names to version requirements")
    path = Path(path).resolve()
    if state_dir:
        state = Path(state_dir)
    elif data.get("stateDir"):
        state = Path(str(data["stateDir"]))
        state = state if state.is_absolute() else path.parent / state
    else:
        state = default_state_dir(path)
    return Manifest(path=path, services=services, requires={str(k): str(v) for k, v in requires.items()}, state_dir=state.resolve())
