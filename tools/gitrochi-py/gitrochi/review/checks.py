"""Deterministic local checks. They need no AI and run with --no-ai too."""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Sequence

from gitrochi import redact
from gitrochi.review import diff as diffmod
from gitrochi.review.diff import FileDiff
from gitrochi.review.findings import Finding


@dataclass
class CheckOptions:
    large_total_lines: int = 1500
    large_file_lines: int = 800
    large_files: int = 60
    min_cochange_confidence: float = 0.5
    max_cochange_findings: int = 10


_TODO = re.compile(r"\b(TODO|FIXME|XXX|HACK)\b")
_CONFLICT = re.compile(r"^(<{7}|={7}|>{7})(\s|$)")
# (pattern, languages by extension, severity, what it is)
_DEBUG_RULES = [
    (re.compile(r"\bdebugger\s*;?\s*$"), (".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs", ".vue", ".svelte"), "warning", "debugger statement"),
    (re.compile(r"\bconsole\.(log|debug|trace|dir)\s*\("), (".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs", ".vue", ".svelte"), "info", "console logging"),
    (re.compile(r"\b(breakpoint\s*\(\s*\)|pdb\.set_trace\s*\(|ipdb\.set_trace\s*\(|import\s+pdb\b)"), (".py",), "warning", "debugger breakpoint"),
    (re.compile(r"\bdbg!\s*\("), (".rs",), "warning", "dbg! macro"),
    (re.compile(r"\b(binding\.pry|byebug|binding\.irb)\b"), (".rb",), "warning", "debugger breakpoint"),
    (re.compile(r"\b(var_dump|print_r|dd)\s*\("), (".php",), "info", "debug dump"),
    (re.compile(r"\b(debugPrint|dump)\s*\("), (".swift",), "info", "debug print"),
    (re.compile(r"\bspew\.Dump\s*\("), (".go",), "info", "debug dump"),
]


def _ext(path: str) -> str:
    name = path.rsplit("/", 1)[-1]
    return "." + name.rsplit(".", 1)[-1].lower() if "." in name else ""


def run(files: Sequence[FileDiff], impact: Optional[Dict[str, Any]] = None, options: Optional[CheckOptions] = None) -> List[Finding]:
    opts = options or CheckOptions()
    findings: List[Finding] = []
    findings += _cochange(files, impact, opts)
    findings += _size(files, opts)
    for f in files:
        if f.binary:
            findings.append(Finding(f.path, None, "info", "binary", f"Binary file {_verb(f.status)}; it was not reviewed line by line.",
                                    "Make sure the file belongs in the repository (Git LFS for large assets).", "local", "binary-file"))
        if f.status == "D" and diffmod.is_test_path(f.path):
            findings.append(Finding(f.path, None, "warning", "tests", "A test file was deleted.",
                                    "Confirm the behaviour it covered is tested elsewhere or was removed on purpose.", "local", "test-deleted"))
        if f.binary or f.status == "D":
            continue
        findings += _added_line_checks(f)
    findings += _lock_files(files)
    return findings


def _verb(status: str) -> str:
    return {"A": "added", "D": "deleted", "R": "renamed", "C": "copied"}.get(status, "changed")


def _cochange(files: Sequence[FileDiff], impact: Optional[Dict[str, Any]], opts: CheckOptions) -> List[Finding]:
    if not impact:
        return []
    out = []
    changed = {f.path for f in files} | {f.old_path for f in files if f.old_path}
    for suggestion in impact.get("suggestions") or []:
        path = suggestion.get("path")
        because = [b for b in suggestion.get("because") or [] if isinstance(b, dict)]
        if not path or path in changed or not because:
            continue
        best = max(because, key=lambda b: (float(b.get("confidence") or 0), int(b.get("commits") or 0)))
        confidence = float(best.get("confidence") or 0)
        if confidence < opts.min_cochange_confidence:
            continue
        anchor = best.get("path")
        others = ", ".join(sorted({str(b.get("path")) for b in because if b.get("path") != anchor}))
        message = (f"{path} usually changes together with {anchor} ({int(best.get('commits') or 0)} shared commits, "
                   f"confidence {confidence:.0%}) but is not part of this change.")
        if others:
            message += f" Also coupled with: {others}."
        out.append(Finding(anchor if anchor in changed else None, None, "warning", "cochange", message,
                           f"Check whether {path} needs a matching update.", "local", "cochange-missing",
                           extra={"partner": path, "commits": best.get("commits"), "confidence": confidence}))
        if len(out) >= opts.max_cochange_findings:
            break
    return out


def _size(files: Sequence[FileDiff], opts: CheckOptions) -> List[Finding]:
    out = []
    total = sum(f.additions + f.deletions for f in files)
    if total > opts.large_total_lines or len(files) > opts.large_files:
        out.append(Finding(None, None, "warning", "size",
                           f"Very large change: {len(files)} files, {total} changed lines. Large changes are hard to review well.",
                           "Split it into smaller pull requests that can be reviewed and reverted on their own.", "local", "large-diff",
                           extra={"files": len(files), "lines": total}))
    for f in files:
        lines = f.additions + f.deletions
        if lines > opts.large_file_lines and not diffmod.is_lock_file(f.path) and not diffmod.is_generated(f.path):
            out.append(Finding(f.path, None, "info", "size", f"{f.path} changes {lines} lines.",
                               "Consider splitting mechanical changes (moves, formatting) from behaviour changes.", "local", "large-file"))
    return out


def _added_line_checks(f: FileDiff) -> List[Finding]:
    out: List[Finding] = []
    ext = _ext(f.path)
    test_file = diffmod.is_test_path(f.path)
    todo_lines: List[int] = []
    for ln in f.added_lines():
        text = ln.text
        if _CONFLICT.match(text):
            out.append(Finding(f.path, ln.new, "error", "merge", "Merge conflict marker added.",
                               "Resolve the conflict and remove the marker.", "local", "conflict-marker"))
            continue
        secrets = redact.find_secrets(text, entropy_check=False)
        if secrets:
            kinds = ", ".join(sorted({kind for kind, _, _ in secrets}))
            out.append(Finding(f.path, ln.new, "error", "security", f"Possible secret added ({kinds}).",
                               "Remove it, rotate the credential, and load it from the environment or a secret store.",
                               "local", "secret-added"))
        if _TODO.search(text):
            todo_lines.append(ln.new or 0)
        if not test_file:
            for pattern, exts, severity, what in _DEBUG_RULES:
                if ext in exts and pattern.search(text) and not text.lstrip().startswith(("//", "#", "*")):
                    out.append(Finding(f.path, ln.new, severity, "debug", f"Added {what}.",
                                       "Remove it or use the project's logger before merging.", "local", "debug-statement"))
                    break
    if todo_lines:
        first = todo_lines[0]
        extra = f" (and {len(todo_lines) - 1} more)" if len(todo_lines) > 1 else ""
        out.append(Finding(f.path, first or None, "info", "todo", f"Added TODO/FIXME marker{extra}.",
                           "Track the follow-up in an issue so it is not forgotten.", "local", "todo-added",
                           extra={"lines": todo_lines}))
    return out


def _lock_files(files: Sequence[FileDiff]) -> List[Finding]:
    if not files:
        return []
    locks = [f for f in files if diffmod.is_lock_file(f.path)]
    if not locks:
        return []
    if len(locks) == len(files):
        names = ", ".join(f.path for f in locks)
        return [Finding(locks[0].path, None, "warning", "dependencies", f"Only lock files changed ({names}).",
                        "Make sure the dependency update is intended and was produced by the package manager.", "local", "lockfile-only")]
    out = []
    changed = {f.path for f in files}
    for lock in locks:
        manifest = diffmod.manifest_for(lock.path)
        if not manifest or "*" in manifest:
            continue
        folder = lock.path.rsplit("/", 1)[0] + "/" if "/" in lock.path else ""
        if folder + manifest not in changed:
            out.append(Finding(lock.path, None, "info", "dependencies",
                               f"{lock.path} changed without {folder + manifest}.",
                               "Check that the resolved versions changed on purpose.", "local", "lockfile-without-manifest"))
    return out
