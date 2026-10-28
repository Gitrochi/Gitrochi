"""`runtime check`: installed tool versions against the manifest's requirements (`>=1.22`, `^20`, `>=3.9,<4`)."""

from __future__ import annotations

import os
import re
import shutil
import subprocess
from typing import Any, Dict, List, Optional, Sequence, Tuple

Version = Tuple[int, int, int]
# How each tool reports its version; any other tool is asked with --version.
VERSION_ARGS = {"go": ["version"], "docker": ["--version"], "java": ["-version"]}
ALIASES = {"python3": ("python3", "python", "py") if os.name == "nt" else ("python3",), "python": ("python", "python3")}
_NUMBER = re.compile(r"(\d+)\.(\d+)(?:\.(\d+))?")


def parse_version(text: str) -> Optional[Version]:
    match = _NUMBER.search(text or "")
    if not match:
        single = re.search(r"\bv?(\d+)\b", text or "")
        return (int(single.group(1)), 0, 0) if single else None
    return int(match.group(1)), int(match.group(2)), int(match.group(3) or 0)


def _clause(text: str) -> List[Tuple[str, Version]]:
    text = text.strip()
    if not text or text == "*":
        return []
    if text.startswith("^"):
        v = parse_version(text[1:])
        if v is None:
            raise ValueError(text)
        upper = (v[0] + 1, 0, 0) if v[0] > 0 else (0, v[1] + 1, 0)
        return [(">=", v), ("<", upper)]
    if text.startswith("~"):
        v = parse_version(text[1:])
        if v is None:
            raise ValueError(text)
        return [(">=", v), ("<", (v[0], v[1] + 1, 0))]
    match = re.match(r"^(>=|<=|==|!=|>|<|=)?\s*v?(\d+(?:\.\d+){0,2})$", text)
    if not match:
        raise ValueError(text)
    op = match.group(1) or ">="
    parts = [int(p) for p in match.group(2).split(".")] + [0, 0]
    return [("==" if op == "=" else op, (parts[0], parts[1], parts[2]))]


def parse_requirement(spec: str) -> List[Tuple[str, Version]]:
    """'>=1.22', '>=3.9,<4', '^20', '~1.2', '1.75' (meaning >=1.75)."""
    out: List[Tuple[str, Version]] = []
    for part in spec.split(","):
        out += _clause(part)
    return out


def satisfies(version: Version, spec: str) -> bool:
    for op, target in parse_requirement(spec):
        if op == ">=" and not version >= target:
            return False
        if op == ">" and not version > target:
            return False
        if op == "<=" and not version <= target:
            return False
        if op == "<" and not version < target:
            return False
        if op == "==" and version != target:
            return False
        if op == "!=" and version == target:
            return False
    return True


def detect(tool: str, path: Optional[str] = None, timeout: float = 20) -> Dict[str, Any]:
    """{"tool", "path", "version", "raw", "error"} for one tool on PATH."""
    found = None
    for name in ALIASES.get(tool, (tool,)):
        found = shutil.which(name, path=path)
        if found:
            break
    if not found:
        return {"tool": tool, "path": None, "version": None, "raw": None, "error": "not found on PATH"}
    try:
        proc = subprocess.run([found] + VERSION_ARGS.get(tool, ["--version"]), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              stdin=subprocess.DEVNULL, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {"tool": tool, "path": found, "version": None, "raw": None, "error": f"cannot run it: {exc}"}
    raw = proc.stdout.decode("utf-8", "replace").strip().splitlines()
    first = next((line for line in raw if _NUMBER.search(line)), raw[0] if raw else "")
    version = parse_version(first)
    return {"tool": tool, "path": found, "version": ".".join(str(n) for n in version) if version else None,
            "raw": first[:200], "error": None if version else "could not read a version"}


def check(requirements: Dict[str, List[Tuple[str, str]]], path: Optional[str] = None) -> List[Dict[str, Any]]:
    """requirements: tool -> [(spec, who needs it)]. One result per tool."""
    results = []
    for tool in sorted(requirements):
        info = detect(tool, path)
        specs = requirements[tool]
        problems = []
        ok = info["version"] is not None
        for spec, _ in specs:
            try:
                parse_requirement(spec)
            except ValueError:
                problems.append(f"bad requirement {spec!r}")
                ok = False
                continue
            if info["version"] is not None and not satisfies(parse_version(info["version"]) or (0, 0, 0), spec):
                ok = False
                problems.append(f"needs {spec}")
        results.append({"tool": tool, "required": ",".join(s for s, _ in specs), "neededBy": sorted({w for _, w in specs}),
                        "found": info["path"] is not None, "path": info["path"], "version": info["version"], "ok": ok,
                        "error": info["error"] or ("; ".join(problems) if problems else None)})
    return results


def merge(manifest_requires: Dict[str, str], services: Sequence[Any]) -> Dict[str, List[Tuple[str, str]]]:
    out: Dict[str, List[Tuple[str, str]]] = {}
    for tool, spec in manifest_requires.items():
        out.setdefault(tool, []).append((spec, "manifest"))
    for service in services:
        for tool, spec in service.requires.items():
            out.setdefault(tool, []).append((spec, service.name))
    return out
