"""Review findings: the model, tolerant JSON extraction from model output, validation and line mapping."""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass, field
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple

from gitrochi.review.diff import FileDiff

SEVERITIES = ("error", "warning", "info")
SEVERITY_RANK = {"error": 3, "warning": 2, "info": 1}
_SEVERITY_ALIASES = {
    "error": "error", "critical": "error", "blocker": "error", "high": "error", "severe": "error", "fatal": "error",
    "major": "error", "bug": "error", "security": "error",
    "warning": "warning", "warn": "warning", "medium": "warning", "moderate": "warning", "minor": "warning",
    "info": "info", "information": "info", "note": "info", "low": "info", "nit": "info", "nitpick": "info",
    "style": "info", "suggestion": "info", "hint": "info", "trivial": "info",
}
MAX_TEXT = 2000


@dataclass
class Finding:
    file: Optional[str]
    line: Optional[int]
    severity: str
    category: str
    message: str
    suggestion: str = ""
    source: str = "ai"
    rule: str = ""
    end_line: Optional[int] = None
    line_adjusted: bool = False
    id: str = ""
    extra: Dict[str, Any] = field(default_factory=dict)

    def key(self) -> Tuple[Any, ...]:
        return (self.file, self.line, self.category, _norm_text(self.message))

    def fingerprint(self) -> str:
        """Stable across runs for the same issue (SARIF partialFingerprints)."""
        basis = f"{self.file}|{self.rule or self.category}|{_norm_text(self.message)[:120]}"
        return hashlib.sha256(basis.encode("utf-8")).hexdigest()[:32]

    def to_dict(self) -> Dict[str, Any]:
        out: Dict[str, Any] = {
            "id": self.id, "file": self.file, "line": self.line, "endLine": self.end_line, "severity": self.severity,
            "category": self.category, "message": self.message, "suggestion": self.suggestion, "source": self.source,
            "rule": self.rule or f"{self.source}/{self.category}",
        }
        if self.line_adjusted:
            out["lineAdjusted"] = True
        if self.extra:
            out["details"] = self.extra
        return out


def _norm_text(text: str) -> str:
    return re.sub(r"\s+", " ", (text or "").strip().lower())


def normalize_severity(value: Any, default: str = "warning") -> str:
    text = str(value or "").strip().lower()
    return _SEVERITY_ALIASES.get(text, default)


def slug(value: Any, default: str = "general") -> str:
    text = re.sub(r"[^a-z0-9]+", "-", str(value or "").strip().lower()).strip("-")
    return text[:40] or default


def counts(findings: Iterable[Finding]) -> Dict[str, int]:
    out = {s: 0 for s in SEVERITIES}
    for f in findings:
        out[f.severity] = out.get(f.severity, 0) + 1
    return out


def sort_findings(findings: List[Finding]) -> List[Finding]:
    return sorted(findings, key=lambda f: (-SEVERITY_RANK.get(f.severity, 0), f.file or "", f.line or 0, f.message))


def dedupe(findings: Iterable[Finding]) -> List[Finding]:
    seen = set()
    out = []
    for f in findings:
        key = f.key()
        if key in seen:
            continue
        seen.add(key)
        out.append(f)
    return out


def assign_ids(findings: List[Finding]) -> None:
    for index, f in enumerate(findings, start=1):
        f.id = f"F{index}"


# ---------- JSON from model output ----------

_FENCE = re.compile(r"```(?:json|JSON)?\s*\n?([\s\S]*?)```")
_TRAILING_COMMA = re.compile(r",(\s*[\]}])")


_TOP_KEYS = ("findings", "issues", "comments", "results", "summary", "keep", "verdict")


def extract_json(text: str) -> Tuple[Any, bool]:
    """(value, repaired) from model text that should contain JSON. Raises ValueError when nothing can be recovered."""
    if text is None:
        raise ValueError("empty response")
    candidates: List[str] = [m.group(1) for m in _FENCE.finditer(text)] + [text]
    decoder = json.JSONDecoder()
    for candidate in candidates:
        stripped = candidate.strip()
        if not stripped:
            continue
        try:
            return json.loads(stripped), False
        except ValueError:
            pass
        openers = [i for i in (stripped.find("{"), stripped.find("[")) if i != -1]
        if not openers:
            continue
        first = min(openers)
        try:
            value, _ = decoder.raw_decode(stripped[first:])
            return value, first > 0
        except ValueError:
            pass
        fixed = _TRAILING_COMMA.sub(r"\1", stripped[first:])
        try:
            value, _ = decoder.raw_decode(fixed)
            return value, True
        except ValueError:
            pass
    salvaged = _salvage_array(text)
    if salvaged is not None:
        return {"findings": salvaged}, True
    # Last resort: a JSON object that appears later in prose, if it looks like a reply.
    start = text.find("{")
    while start != -1:
        try:
            value, _ = decoder.raw_decode(text[start:])
            if isinstance(value, dict) and any(k in value for k in _TOP_KEYS):
                return value, True
        except ValueError:
            pass
        start = text.find("{", start + 1)
    raise ValueError("no JSON object in the response")


def _salvage_array(text: str) -> Optional[List[Any]]:
    """Recover the complete objects of a findings array cut off mid-way (a response that hit max_tokens)."""
    match = re.search(r'"findings"\s*:\s*\[', text) or re.search(r"\[\s*\{", text)
    if not match:
        return None
    index = match.end() if text[match.end() - 1] == "[" else match.start() + 1
    decoder = json.JSONDecoder()
    items: List[Any] = []
    length = len(text)
    while index < length:
        while index < length and text[index] in " \t\r\n,":
            index += 1
        if index >= length or text[index] != "{":
            break
        try:
            value, end = decoder.raw_decode(text, index)
        except ValueError:
            break
        items.append(value)
        index = end
    return items or None


# ---------- validation ----------

def _first_int(value: Any) -> Tuple[Optional[int], Optional[int]]:
    if isinstance(value, bool):
        return None, None
    if isinstance(value, int):
        return (value if value > 0 else None), None
    if isinstance(value, float):
        return (int(value) if value > 0 else None), None
    numbers = re.findall(r"\d+", str(value or ""))
    if not numbers:
        return None, None
    first = int(numbers[0])
    second = int(numbers[1]) if len(numbers) > 1 else None
    return (first if first > 0 else None), second


class FileIndex:
    """The files of a change, for matching a model's path and line to the new side of the diff."""

    def __init__(self, files: Sequence[FileDiff]):
        self.files = {f.path: f for f in files}
        self.by_name: Dict[str, List[str]] = {}
        for path in self.files:
            self.by_name.setdefault(path.rsplit("/", 1)[-1], []).append(path)

    def resolve(self, raw: Any) -> Optional[str]:
        if not raw:
            return None
        text = str(raw).strip().strip("`'\"").replace("\\", "/")
        for prefix in ("a/", "b/", "./"):
            if text.startswith(prefix) and text[len(prefix):] in self.files:
                return text[len(prefix):]
        if text in self.files:
            return text
        suffix_matches = [p for p in self.files if p.endswith("/" + text) or text.endswith("/" + p)]
        if len(suffix_matches) == 1:
            return suffix_matches[0]
        name_matches = self.by_name.get(text.rsplit("/", 1)[-1], [])
        if len(name_matches) == 1:
            return name_matches[0]
        return None

    def map_line(self, path: str, line: Optional[int]) -> Tuple[Optional[int], bool]:
        """A line on the new side of the diff: kept when the diff shows it, else moved to the nearest changed line."""
        diff = self.files.get(path)
        if diff is None or diff.status == "D" or diff.binary:
            return None, line is not None
        visible = diff.new_side_lines()
        added = sorted(ln.new for ln in diff.added_lines() if ln.new is not None)
        if line is not None:
            if line in visible:
                return line, False
            if any(line in h.new_range() for h in diff.hunks):
                return line, False
        candidates = added or sorted(visible)
        if not candidates:
            return None, line is not None
        if line is None:
            return candidates[0], True
        nearest = min(candidates, key=lambda n: (abs(n - line), n))
        return nearest, True


def validate(raw: Any, files: FileIndex, source: str = "ai", allowed_files: Optional[Iterable[str]] = None) -> Tuple[List[Finding], int]:
    """Findings from a parsed model response, and how many items were dropped as unusable."""
    if isinstance(raw, dict):
        items = raw.get("findings")
        if items is None:
            items = raw.get("issues") or raw.get("comments") or raw.get("results")
        if items is None and ("message" in raw or "description" in raw):
            items = [raw]
    elif isinstance(raw, list):
        items = raw
    else:
        items = None
    if not isinstance(items, list):
        return [], 0
    allowed = set(allowed_files) if allowed_files is not None else None
    out: List[Finding] = []
    dropped = 0
    for item in items:
        if not isinstance(item, dict):
            dropped += 1
            continue
        message = item.get("message") or item.get("description") or item.get("issue") or item.get("title") or item.get("body")
        if not isinstance(message, str) or not message.strip():
            dropped += 1
            continue
        path = files.resolve(item.get("file") or item.get("path") or item.get("filename"))
        if path is None or (allowed is not None and path not in allowed):
            dropped += 1
            continue
        line, end = _first_int(item.get("line") if item.get("line") is not None else item.get("start_line", item.get("startLine")))
        explicit_end, _ = _first_int(item.get("endLine") or item.get("end_line"))
        end = explicit_end or end
        mapped, adjusted = files.map_line(path, line)
        suggestion = item.get("suggestion") or item.get("fix") or item.get("recommendation") or ""
        out.append(Finding(
            file=path,
            line=mapped,
            end_line=end if (mapped is not None and end and end >= mapped and not adjusted) else None,
            severity=normalize_severity(item.get("severity") or item.get("level") or item.get("priority")),
            category=slug(item.get("category") or item.get("type") or item.get("kind")),
            message=message.strip()[:MAX_TEXT],
            suggestion=(suggestion.strip() if isinstance(suggestion, str) else json.dumps(suggestion))[:MAX_TEXT],
            source=source,
            line_adjusted=adjusted,
        ))
    return out, dropped
