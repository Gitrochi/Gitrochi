"""Optional JSON configuration: the user's file, overlaid by the repository's `.gitrochi/gitrochi-py.json`.

A repository is not trusted to decide where API keys are sent: settings that choose a server (`baseUrl`)
are read from the user's file, the command line or the environment only. No file may hold a key or token.
"""

from __future__ import annotations

import json
import os
import re
from pathlib import Path
from typing import Any, Dict, List, Optional

from gitrochi.util import Failure

CONFIG_ENV = "GITROCHI_PY_CONFIG"
REPO_CONFIG = Path(".gitrochi") / "gitrochi-py.json"
# Settings a repository's file may not set (dotted paths).
USER_ONLY = {"review.baseUrl", "review.provider.baseUrl"}
_SECRET_KEY = re.compile(r"(?i)(api[_\-]?key|token|secret|passw(or)?d|credential)")


def user_config_path() -> Path:
    env = os.environ.get(CONFIG_ENV, "").strip()
    if env:
        return Path(env)
    if os.name == "nt":
        base = Path(os.environ.get("APPDATA") or Path.home() / "AppData" / "Roaming")
        return base / "Gitrochi" / "gitrochi-py.json"
    base = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
    return base / "gitrochi" / "gitrochi-py.json"


class Config:
    def __init__(self, data: Optional[Dict[str, Any]] = None, notes: Optional[List[str]] = None):
        self.data = data or {}
        self.notes = notes or []

    def section(self, name: str) -> Dict[str, Any]:
        value = self.data.get(name)
        return value if isinstance(value, dict) else {}

    def get(self, section: str, key: str, default: Any = None) -> Any:
        value = self.section(section).get(key)
        return default if value is None else value


def _read(path: Path) -> Dict[str, Any]:
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return {}
    except OSError as exc:
        raise Failure(f"cannot read {path}: {exc}", code="CONFIG")
    try:
        data = json.loads(text)
    except ValueError as exc:
        raise Failure(f"{path} is not valid JSON: {exc}", code="CONFIG")
    if not isinstance(data, dict):
        raise Failure(f"{path} must hold a JSON object", code="CONFIG")
    _reject_secrets(data, str(path))
    return data


def _reject_secrets(node: Any, where: str, prefix: str = "") -> None:
    if isinstance(node, dict):
        for key, value in node.items():
            dotted = f"{prefix}.{key}" if prefix else str(key)
            if _SECRET_KEY.search(str(key)) and isinstance(value, str) and value.strip() and not str(key).endswith("Env"):
                raise Failure(f"{where}: '{dotted}' looks like a secret; keys belong in the Keychain, the Credential Manager "
                              "or an environment variable", code="CONFIG_SECRET")
            _reject_secrets(value, where, dotted)
    elif isinstance(node, list):
        for item in node:
            _reject_secrets(item, where, prefix)


def _drop_user_only(data: Dict[str, Any], notes: List[str], where: str) -> None:
    for dotted in USER_ONLY:
        parts = dotted.split(".")
        node: Any = data
        for part in parts[:-1]:
            node = node.get(part) if isinstance(node, dict) else None
        if isinstance(node, dict) and parts[-1] in node:
            node.pop(parts[-1])
            notes.append(f"ignored '{dotted}' in {where}: only your own settings may choose the AI server")


def _merge(base: Dict[str, Any], over: Dict[str, Any]) -> Dict[str, Any]:
    out = dict(base)
    for key, value in over.items():
        if isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = _merge(out[key], value)
        else:
            out[key] = value
    return out


def load(repo_root: Optional[Path], explicit: Optional[str] = None) -> Config:
    notes: List[str] = []
    user = _read(Path(explicit)) if explicit else _read(user_config_path())
    repo: Dict[str, Any] = {}
    if repo_root is not None:
        path = Path(repo_root) / REPO_CONFIG
        repo = _read(path)
        _drop_user_only(repo, notes, str(REPO_CONFIG))
    return Config(_merge(user, repo), notes)
