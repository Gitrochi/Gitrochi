"""Shared helpers: errors with exit codes, JSON output, time parsing, atomic files and small text tables."""

from __future__ import annotations

import calendar
import datetime as _dt
import json
import os
import re
import shutil
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence

from gitrochi import __version__

SCHEMA_VERSION = 1
TOOL = "gitrochi-py"


class UsageError(Exception):
    """A bad command line; the process exits with 2."""


class Failure(Exception):
    """An expected failure with a stable code; the process exits with 1."""

    def __init__(self, message: str, code: str = "FAILED", details: Any = None):
        super().__init__(message)
        self.message = message
        self.code = code
        self.details = details


def envelope(command: str, **fields: Any) -> Dict[str, Any]:
    """The common head of every JSON document this tool prints."""
    doc: Dict[str, Any] = {"schemaVersion": SCHEMA_VERSION, "tool": TOOL, "version": __version__, "command": command}
    doc.update(fields)
    return doc


def dumps(obj: Any) -> str:
    return json.dumps(obj, indent=2, ensure_ascii=False, default=_json_default)


def _json_default(value: Any) -> Any:
    if isinstance(value, Path):
        return str(value)
    if isinstance(value, (set, frozenset)):
        return sorted(value)
    raise TypeError(f"not JSON serializable: {type(value).__name__}")


def emit(text: str, out: Optional[str] = None) -> None:
    """Print to stdout, or write the file named by --out."""
    if out and out != "-":
        Path(out).parent.mkdir(parents=True, exist_ok=True)
        atomic_write_text(Path(out), text if text.endswith("\n") else text + "\n")
        return
    stream = sys.stdout
    try:
        stream.write(text if text.endswith("\n") else text + "\n")
        stream.flush()
    except BrokenPipeError:
        # A closed pipe (`| head`) is not an error worth a traceback.
        try:
            sys.stdout = open(os.devnull, "w")
        except OSError:
            pass


def eprint(*parts: Any) -> None:
    print(*parts, file=sys.stderr)


# ---------- time ----------

_RELATIVE = re.compile(r"^(\d+(?:\.\d+)?)\s*(s|m|h|d|w|mo|y)$", re.IGNORECASE)
_UNIT_SECONDS = {"s": 1, "m": 60, "h": 3600, "d": 86400, "w": 7 * 86400, "mo": 30 * 86400, "y": 365 * 86400}


def parse_time(value: Optional[str], now: Optional[float] = None) -> Optional[int]:
    """Unix seconds from '1700000000', '2026-01-31', '2026-01-31T10:00:00Z' or a relative age ('90d', '12w', '6mo', '1y').

    A bare 'm' means minutes; months are 'mo'.
    """
    if value is None or str(value).strip() == "":
        return None
    text = str(value).strip()
    if re.fullmatch(r"\d{9,}", text):
        return int(text)
    match = _RELATIVE.match(text)
    if match:
        amount = float(match.group(1))
        unit = match.group(2).lower()
        base = time.time() if now is None else now
        return int(base - amount * _UNIT_SECONDS[unit])
    try:
        if re.fullmatch(r"\d{4}-\d{2}-\d{2}", text):
            moment = _dt.datetime.strptime(text, "%Y-%m-%d").replace(tzinfo=_dt.timezone.utc)
        else:
            iso_text = text[:-1] + "+00:00" if text.endswith(("Z", "z")) else text
            moment = _dt.datetime.fromisoformat(iso_text)
            if moment.tzinfo is None:
                moment = moment.replace(tzinfo=_dt.timezone.utc)
    except ValueError:
        raise UsageError(f"not a time: {value!r} (use Unix seconds, YYYY-MM-DD, an ISO time or an age such as 90d)")
    return int(moment.timestamp())


def iso(ts: Optional[float]) -> Optional[str]:
    if ts is None:
        return None
    return _dt.datetime.fromtimestamp(float(ts), _dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def day(ts: Optional[float]) -> str:
    if ts is None:
        return "-"
    return _dt.datetime.fromtimestamp(float(ts), _dt.timezone.utc).strftime("%Y-%m-%d")


def iso_week(ts: float) -> str:
    year, week, _ = _dt.datetime.fromtimestamp(float(ts), _dt.timezone.utc).isocalendar()
    return f"{year}-W{week:02d}"


def week_start(ts: float) -> int:
    """Monday 00:00 UTC of the week containing ts."""
    moment = _dt.datetime.fromtimestamp(float(ts), _dt.timezone.utc)
    monday = (moment - _dt.timedelta(days=moment.weekday())).replace(hour=0, minute=0, second=0, microsecond=0)
    return calendar.timegm(monday.utctimetuple())


def age_text(seconds: float) -> str:
    seconds = max(0, int(seconds))
    if seconds < 3600:
        return f"{seconds // 60}m"
    if seconds < 86400:
        return f"{seconds // 3600}h"
    days = seconds // 86400
    if days < 60:
        return f"{days}d"
    if days < 730:
        return f"{days // 30}mo"
    return f"{days // 365}y"


def now_ms() -> int:
    return int(time.time() * 1000)


# ---------- files ----------

def atomic_write_text(path: Path, text: str) -> None:
    """Write through a temporary file in the same folder so readers never see half a file."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix="." + path.name + ".", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
        os.replace(tmp, str(path))
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def atomic_write_json(path: Path, obj: Any) -> None:
    atomic_write_text(path, dumps(obj) + "\n")


def read_json(path: Path, default: Any = None) -> Any:
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return default


def which(name: str, path: Optional[str] = None) -> Optional[str]:
    return shutil.which(name, path=path)


def is_executable(path: Optional[str]) -> bool:
    return bool(path) and os.path.isfile(str(path)) and os.access(str(path), os.X_OK)


# ---------- text output ----------

def table(rows: Sequence[Sequence[Any]], headers: Sequence[str], aligns: Optional[str] = None) -> str:
    """A plain fixed-width table. aligns is a string of 'l'/'r' per column."""
    cells = [[str(h) for h in headers]] + [["" if c is None else str(c) for c in row] for row in rows]
    widths = [max(len(row[i]) for row in cells) for i in range(len(headers))]
    aligns = aligns or "l" * len(headers)
    lines = []
    for index, row in enumerate(cells):
        parts = []
        for i, cell in enumerate(row):
            parts.append(cell.rjust(widths[i]) if aligns[i] == "r" else cell.ljust(widths[i]))
        lines.append("  ".join(parts).rstrip())
        if index == 0:
            lines.append("  ".join("-" * w for w in widths))
    return "\n".join(lines)


def md_escape(value: Any) -> str:
    text = "" if value is None else str(value)
    return text.replace("\\", "\\\\").replace("|", "\\|").replace("\n", " ").replace("`", "\\`")


def plural(count: int, word: str, many: Optional[str] = None) -> str:
    return f"{count} {word if count == 1 else (many or word + 's')}"


def truncate(text: str, limit: int) -> str:
    text = text or ""
    return text if len(text) <= limit else text[: max(0, limit - 1)] + "\u2026"


def unique(items: Iterable[Any]) -> List[Any]:
    seen = set()
    out = []
    for item in items:
        if item not in seen:
            seen.add(item)
            out.append(item)
    return out


def glob_match(path: str, pattern: str) -> bool:
    """Gitignore-like glob: '**' crosses folders, '*' does not.

    A pattern without '/' matches the base name; 'name/' matches a folder of that name at any depth.
    """
    pattern = pattern.strip()
    if not pattern:
        return False
    if pattern.endswith("/"):
        name = pattern.rstrip("/")
        if "/" in name:
            return _glob_regex(name.lstrip("/") + "/**").fullmatch(path) is not None
        return any(_glob_regex(name).fullmatch(part) for part in path.split("/")[:-1])
    if "/" not in pattern:
        return _glob_regex(pattern).fullmatch(path.rsplit("/", 1)[-1]) is not None
    return _glob_regex(pattern.lstrip("/")).fullmatch(path) is not None


_GLOB_CACHE: Dict[str, "re.Pattern[str]"] = {}


def _glob_regex(pattern: str) -> "re.Pattern[str]":
    cached = _GLOB_CACHE.get(pattern)
    if cached is not None:
        return cached
    out = []
    i = 0
    while i < len(pattern):
        c = pattern[i]
        if c == "*":
            if pattern[i:i + 3] == "**/":
                out.append("(?:.*/)?")
                i += 3
                continue
            if pattern[i:i + 2] == "**":
                out.append(".*")
                i += 2
                continue
            out.append("[^/]*")
        elif c == "?":
            out.append("[^/]")
        else:
            out.append(re.escape(c))
        i += 1
    compiled = re.compile("".join(out))
    _GLOB_CACHE[pattern] = compiled
    return compiled


def env_flag(name: str) -> bool:
    return os.environ.get(name, "").strip().lower() in ("1", "true", "yes", "on")
