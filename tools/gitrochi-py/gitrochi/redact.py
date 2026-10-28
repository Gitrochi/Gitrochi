"""Find and mask things that look like secrets before text leaves the machine or reaches a log."""

from __future__ import annotations

import math
import re
from typing import Iterable, List, Optional, Tuple

# (kind, pattern). Group 1, when present, is the secret part; otherwise the whole match is.
_PATTERNS: List[Tuple[str, "re.Pattern[str]"]] = [
    ("private-key", re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|\Z)")),
    ("anthropic-key", re.compile(r"\bsk-ant-[A-Za-z0-9_\-]{16,}")),
    ("openai-key", re.compile(r"\bsk-(?:proj-|svcacct-|admin-)?[A-Za-z0-9_\-]{20,}")),
    ("github-token", re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})")),
    ("gitlab-token", re.compile(r"\bglpat-[A-Za-z0-9_\-]{20,}")),
    ("slack-token", re.compile(r"\bxox[abprs]-[A-Za-z0-9\-]{10,}")),
    ("aws-access-key", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b")),
    ("google-api-key", re.compile(r"\bAIza[0-9A-Za-z_\-]{35}")),
    ("stripe-key", re.compile(r"\b(?:sk|rk)_(?:live|test)_[0-9A-Za-z]{16,}")),
    ("jwt", re.compile(r"\beyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}")),
    ("url-credentials", re.compile(r"(?<=://)([^/\s:@'\"]+:[^/\s@'\"]+)(?=@)")),
    ("bearer-token", re.compile(r"(?i)\bbearer\s+([A-Za-z0-9_\-.=]{16,})")),
    ("assignment", re.compile(
        r"(?i)\b(?:[A-Za-z0-9_]*(?:password|passwd|pwd|secret|token|api[_\-]?key|access[_\-]?key|private[_\-]?key|"
        r"client[_\-]?secret|auth))[A-Za-z0-9_]*[\"']?\s*(?:=|:|=>)\s*[\"']([^\"'\s]{8,})[\"']")),
]

_HIGH_ENTROPY = re.compile(r"(?<![A-Za-z0-9+/=_\-])([A-Za-z0-9+/_\-]{32,}={0,2})(?![A-Za-z0-9+/=_\-])")
_HEX_ONLY = re.compile(r"^[0-9a-fA-F]+$")


def entropy(text: str) -> float:
    if not text:
        return 0.0
    counts: dict = {}
    for ch in text:
        counts[ch] = counts.get(ch, 0) + 1
    total = float(len(text))
    return -sum((n / total) * math.log2(n / total) for n in counts.values())


def _looks_random(token: str) -> bool:
    # Hex strings are commit SHAs and checksums far more often than secrets; leave them alone.
    if _HEX_ONLY.match(token):
        return False
    if token.count("/") > 2:
        return False  # a path, not a key
    classes = sum(1 for test in (str.islower, str.isupper, str.isdigit) if any(test(c) for c in token))
    return classes >= 3 and entropy(token) >= 4.2


_PLACEHOLDER = re.compile(r"(?i)^(?:\$\{?[A-Z0-9_]+\}?|<[^>]*>|%[^%]+%|\{\{[^}]*\}\}|x{4,}|\*{4,}|changeme|example\S*|placeholder\S*|dummy\S*|your[_\-]\S*)$")


def find_secrets(text: str, extra: Iterable[str] = (), entropy_check: bool = True) -> List[Tuple[str, int, int]]:
    """Spans (kind, start, end) of probable secrets in text.

    entropy_check=False keeps only recognizable token formats, for checks that report findings.
    """
    spans: List[Tuple[str, int, int]] = []
    for value in extra:
        if value and len(value) >= 6:
            start = text.find(value)
            while start != -1:
                spans.append(("known-secret", start, start + len(value)))
                start = text.find(value, start + len(value))
    for kind, pattern in _PATTERNS:
        for match in pattern.finditer(text):
            if match.groups() and match.group(1) is not None:
                if kind == "assignment" and _PLACEHOLDER.match(match.group(1)):
                    continue
                spans.append((kind, match.start(1), match.end(1)))
            else:
                spans.append((kind, match.start(), match.end()))
    if entropy_check:
        for match in _HIGH_ENTROPY.finditer(text):
            if _looks_random(match.group(1)):
                spans.append(("high-entropy", match.start(1), match.end(1)))
    return _merge(spans)


def _merge(spans: List[Tuple[str, int, int]]) -> List[Tuple[str, int, int]]:
    spans.sort(key=lambda s: (s[1], -(s[2] - s[1])))
    merged: List[Tuple[str, int, int]] = []
    for kind, start, end in spans:
        if merged and start < merged[-1][2]:
            prev_kind, prev_start, prev_end = merged[-1]
            merged[-1] = (prev_kind, prev_start, max(prev_end, end))
        else:
            merged.append((kind, start, end))
    return merged


def redact(text: Optional[str], extra: Iterable[str] = ()) -> str:
    """Replace probable secrets with [REDACTED:<kind>]."""
    if not text:
        return text or ""
    spans = find_secrets(text, extra)
    if not spans:
        return text
    out = []
    last = 0
    for kind, start, end in spans:
        out.append(text[last:start])
        out.append(f"[REDACTED:{kind}]")
        last = end
    out.append(text[last:])
    return "".join(out)


def mask(text: Optional[str], secrets: Iterable[Optional[str]]) -> str:
    """Remove exact secret values (an API key in use) from a message, then any other probable secret."""
    return redact(text or "", [s for s in secrets if s])
