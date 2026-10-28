"""Collect a change with the system git and parse the unified diff into files, hunks and numbered lines."""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Set

from gitrochi import gitutil
from gitrochi.util import Failure, UsageError

_HUNK = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@ ?(.*)$")
MAX_UNTRACKED_BYTES = 1_000_000


@dataclass
class Line:
    kind: str  # '+', '-' or ' '
    old: Optional[int]
    new: Optional[int]
    text: str


@dataclass
class Hunk:
    old_start: int
    old_count: int
    new_start: int
    new_count: int
    section: str = ""
    lines: List[Line] = field(default_factory=list)

    def header(self) -> str:
        tail = f" {self.section}" if self.section else ""
        return f"@@ -{self.old_start},{self.old_count} +{self.new_start},{self.new_count} @@{tail}"

    def new_range(self) -> range:
        return range(self.new_start, self.new_start + max(self.new_count, 0))


@dataclass
class FileDiff:
    path: str
    old_path: Optional[str] = None
    status: str = "M"
    similarity: Optional[int] = None
    binary: bool = False
    mode_change: bool = False
    hunks: List[Hunk] = field(default_factory=list)

    @property
    def additions(self) -> int:
        return sum(1 for h in self.hunks for ln in h.lines if ln.kind == "+")

    @property
    def deletions(self) -> int:
        return sum(1 for h in self.hunks for ln in h.lines if ln.kind == "-")

    def added_lines(self) -> List[Line]:
        return [ln for h in self.hunks for ln in h.lines if ln.kind == "+"]

    def deleted_lines(self) -> List[Line]:
        return [ln for h in self.hunks for ln in h.lines if ln.kind == "-"]

    def new_side_lines(self) -> Set[int]:
        return {ln.new for h in self.hunks for ln in h.lines if ln.new is not None}

    def to_dict(self) -> Dict[str, object]:
        return {"path": self.path, "oldPath": self.old_path, "status": self.status, "similarity": self.similarity,
                "binary": self.binary, "additions": self.additions, "deletions": self.deletions}


@dataclass
class ChangeSet:
    mode: str  # range | staged | worktree
    base: Optional[str]
    head: Optional[str]
    base_ref: Optional[str]
    head_ref: Optional[str]
    merge_base: Optional[str]
    files: List[FileDiff]

    def range_dict(self) -> Dict[str, Optional[str]]:
        return {"mode": self.mode, "base": self.base, "baseRef": self.base_ref, "mergeBase": self.merge_base,
                "head": self.head, "headRef": self.head_ref}


def _split_header_paths(rest: str):
    """Paths from 'a/X b/Y' in a `diff --git` line (git quotes paths it cannot print plainly)."""
    if rest.startswith('"'):
        end = _quoted_end(rest)
        first = gitutil.unquote_path(rest[:end + 1])
        second = rest[end + 2:]
        return first, gitutil.unquote_path(second)
    if rest.endswith('"'):
        start = rest.rfind(' "')
        return rest[:start], gitutil.unquote_path(rest[start + 1:])
    # Without a rename both sides are the same path, so the split is in the middle.
    if (len(rest) - 1) % 2 == 0:
        half = (len(rest) - 1) // 2
        left, right = rest[:half], rest[half + 1:]
        if left[2:] == right[2:]:
            return left, right
    index = rest.find(" b/")
    if index > 0:
        return rest[:index], rest[index + 1:]
    return rest, rest


def _quoted_end(text: str) -> int:
    i = 1
    while i < len(text):
        if text[i] == "\\":
            i += 2
            continue
        if text[i] == '"':
            return i
        i += 1
    return len(text) - 1


def _strip_prefix(path: Optional[str], prefix: str) -> Optional[str]:
    if path is None:
        return None
    if path == "/dev/null":
        return None
    return path[len(prefix):] if path.startswith(prefix) else path


def parse_patch(text: str) -> List[FileDiff]:
    """Parse `git diff` output made with --src-prefix=a/ --dst-prefix=b/."""
    files: List[FileDiff] = []
    current: Optional[FileDiff] = None
    hunk: Optional[Hunk] = None
    old_left = new_left = 0
    old_no = new_no = 0
    header_old: Optional[str] = None
    header_new: Optional[str] = None
    minus: Optional[str] = None
    plus: Optional[str] = None
    rename_from: Optional[str] = None
    rename_to: Optional[str] = None

    def finish() -> None:
        if current is None:
            return
        new_path = _strip_prefix(plus, "b/") if plus is not None else None
        old_path = _strip_prefix(minus, "a/") if minus is not None else None
        if plus == "/dev/null":
            current.status = "D"
        if minus == "/dev/null":
            current.status = "A"
        new_path = new_path or rename_to or _strip_prefix(header_new, "b/")
        old_path = old_path or rename_from or _strip_prefix(header_old, "a/")
        if current.status == "D":
            current.path = old_path or new_path or ""
            current.old_path = None
        else:
            current.path = new_path or old_path or ""
            current.old_path = old_path if current.status in ("R", "C") and old_path != current.path else None

    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    for raw in lines:
        if hunk is not None and (old_left > 0 or new_left > 0):
            kind = raw[:1] if raw else " "
            body = raw[1:]
            if kind == " ":
                hunk.lines.append(Line(" ", old_no, new_no, body))
                old_no += 1
                new_no += 1
                old_left -= 1
                new_left -= 1
                continue
            if kind == "-":
                hunk.lines.append(Line("-", old_no, None, body))
                old_no += 1
                old_left -= 1
                continue
            if kind == "+":
                hunk.lines.append(Line("+", None, new_no, body))
                new_no += 1
                new_left -= 1
                continue
            if kind == "\\":
                continue
            hunk = None  # malformed: fall through to header handling
        if raw.startswith("\\"):
            continue
        if raw.startswith("diff --git "):
            finish()
            current = FileDiff(path="")
            files.append(current)
            hunk = None
            header_old, header_new = _split_header_paths(raw[len("diff --git "):])
            minus = plus = rename_from = rename_to = None
            continue
        if current is None:
            continue
        match = _HUNK.match(raw)
        if match:
            old_start = int(match.group(1))
            old_count = int(match.group(2)) if match.group(2) is not None else 1
            new_start = int(match.group(3))
            new_count = int(match.group(4)) if match.group(4) is not None else 1
            hunk = Hunk(old_start, old_count, new_start, new_count, match.group(5).strip())
            current.hunks.append(hunk)
            old_left, new_left = old_count, new_count
            old_no, new_no = old_start, new_start
            continue
        if raw.startswith("--- "):
            minus = gitutil.unquote_path(raw[4:].rstrip("\t"))
        elif raw.startswith("+++ "):
            plus = gitutil.unquote_path(raw[4:].rstrip("\t"))
        elif raw.startswith("rename from "):
            rename_from = gitutil.unquote_path(raw[len("rename from "):])
            current.status = "R"
        elif raw.startswith("rename to "):
            rename_to = gitutil.unquote_path(raw[len("rename to "):])
            current.status = "R"
        elif raw.startswith("copy from "):
            rename_from = gitutil.unquote_path(raw[len("copy from "):])
            current.status = "C"
        elif raw.startswith("copy to "):
            rename_to = gitutil.unquote_path(raw[len("copy to "):])
            current.status = "C"
        elif raw.startswith("new file mode"):
            current.status = "A"
        elif raw.startswith("deleted file mode"):
            current.status = "D"
        elif raw.startswith("similarity index "):
            try:
                current.similarity = int(raw[len("similarity index "):].rstrip("%"))
            except ValueError:
                pass
        elif raw.startswith("old mode") or raw.startswith("new mode"):
            current.mode_change = True
        elif raw.startswith("Binary files ") or raw == "GIT binary patch":
            current.binary = True
    finish()
    return [f for f in files if f.path]


DIFF_FLAGS = ["--no-ext-diff", "--no-color", "--no-textconv", "-M", "--src-prefix=a/", "--dst-prefix=b/",
              "--no-relative", "--submodule=short"]


def _check_ref(ref: Optional[str], name: str) -> None:
    if ref is not None and (not ref.strip() or ref.startswith("-")):
        raise UsageError(f"{name} must be a commit, not {ref!r}")


def collect(root: Path, base: Optional[str] = None, head: Optional[str] = None, staged: bool = False,
            worktree: bool = False, include_untracked: bool = True, context: int = 3) -> ChangeSet:
    """The change to review: base...head (default: merge-base with the default branch...HEAD), staged or worktree."""
    _check_ref(base, "--base")
    _check_ref(head, "--head")
    if staged and worktree:
        raise UsageError("use either --staged or --worktree")
    if (staged or worktree) and head:
        raise UsageError("--head cannot be combined with --staged or --worktree")
    flags = DIFF_FLAGS + [f"-U{max(0, int(context))}"]
    head_sha = gitutil.head(root)
    if staged:
        args = ["--cached"] + ([base] if base else [])
        if base and not gitutil.rev(root, base):
            raise Failure(f"unknown commit: {base}", code="UNKNOWN_REF")
        text = gitutil.git(root, "diff", *flags, *args, "--")
        files = parse_patch(text)
        return ChangeSet("staged", gitutil.rev(root, base) if base else head_sha, None, base or "HEAD", "index", None, files)
    if worktree:
        start = base or ("HEAD" if head_sha else gitutil.empty_tree(root))
        if base and not gitutil.rev(root, base):
            raise Failure(f"unknown commit: {base}", code="UNKNOWN_REF")
        text = gitutil.git(root, "diff", *flags, start, "--")
        files = parse_patch(text)
        if include_untracked:
            files += _untracked(root, flags)
        return ChangeSet("worktree", gitutil.rev(root, start) if head_sha or base else None, None, base or "HEAD",
                         "worktree", None, files)
    head_ref = head or "HEAD"
    head_resolved = gitutil.rev(root, head_ref)
    if not head_resolved:
        raise Failure(f"unknown commit: {head_ref}", code="UNKNOWN_REF")
    base_ref = base
    if base_ref is None:
        base_ref = gitutil.default_branch(root)
        if base_ref is None:
            raise Failure("could not find the default branch; pass --base REF", code="NO_BASE")
    base_resolved = gitutil.rev(root, base_ref)
    if not base_resolved:
        raise Failure(f"unknown commit: {base_ref}", code="UNKNOWN_REF")
    mb = gitutil.merge_base(root, base_resolved, head_resolved)
    if not mb:
        raise Failure(f"{base_ref} and {head_ref} have no common history", code="NO_MERGE_BASE")
    text = gitutil.git(root, "diff", *flags, mb, head_resolved, "--")
    return ChangeSet("range", base_resolved, head_resolved, base_ref, head_ref, mb, parse_patch(text))


def _untracked(root: Path, flags: Sequence[str]) -> List[FileDiff]:
    out: List[FileDiff] = []
    for path in gitutil.untracked_files(root)[:500]:
        full = Path(root) / path
        try:
            if not full.is_file() or full.stat().st_size > MAX_UNTRACKED_BYTES:
                continue
        except OSError:
            continue
        proc = gitutil.run_git(root, ["diff", "--no-index", *flags, "--", "/dev/null", path], check=True, ok_codes=(0, 1))
        parsed = parse_patch(proc.stdout.decode("utf-8", "replace"))
        for item in parsed:
            item.status = "A"
            item.path = path
            item.old_path = None
        out += parsed
    return out


def is_lock_file(path: str) -> bool:
    return path.rsplit("/", 1)[-1] in LOCK_FILES


LOCK_FILES = {
    "package-lock.json": "package.json", "npm-shrinkwrap.json": "package.json", "yarn.lock": "package.json",
    "pnpm-lock.yaml": "package.json", "bun.lockb": "package.json", "bun.lock": "package.json",
    "Cargo.lock": "Cargo.toml", "go.sum": "go.mod", "poetry.lock": "pyproject.toml", "uv.lock": "pyproject.toml",
    "Pipfile.lock": "Pipfile", "Gemfile.lock": "Gemfile", "composer.lock": "composer.json", "Podfile.lock": "Podfile",
    "Package.resolved": "Package.swift", "mix.lock": "mix.exs", "pubspec.lock": "pubspec.yaml", "flake.lock": "flake.nix",
    "packages.lock.json": "*.csproj", "gradle.lockfile": "build.gradle",
}


def manifest_for(lock_path: str) -> Optional[str]:
    name = lock_path.rsplit("/", 1)[-1]
    return LOCK_FILES.get(name)


_TEST_PATTERNS = [
    re.compile(r"(^|/)(tests?|__tests__|spec|specs|testing)/"),
    re.compile(r"(^|/)test_[^/]+\.py$"),
    re.compile(r"_test\.(py|go|rb|exs?)$"),
    re.compile(r"\.(test|spec)\.[cm]?[jt]sx?$"),
    re.compile(r"Tests?\.(swift|kt|java|cs)$"),
    re.compile(r"_spec\.rb$"),
    re.compile(r"(^|/)Tests/"),
]


def is_test_path(path: str) -> bool:
    return any(p.search(path) for p in _TEST_PATTERNS)


_GENERATED = re.compile(r"(\.min\.(js|css)$|\.map$|\.pb\.go$|_pb2\.pyi?$|\.generated\.|(^|/)(dist|build|vendor|node_modules|third_party)/|\.snap$)")


def is_generated(path: str) -> bool:
    return bool(_GENERATED.search(path))


def is_doc(path: str) -> bool:
    lower = path.lower()
    return lower.endswith((".md", ".rst", ".txt", ".adoc")) or lower.startswith("docs/") or "/docs/" in lower
