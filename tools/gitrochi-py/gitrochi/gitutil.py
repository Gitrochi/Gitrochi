"""The system git, run with machine-readable output. Nothing here writes refs or objects."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path
from typing import Dict, List, Optional, Sequence

from gitrochi.util import Failure

DEFAULT_BRANCH_CANDIDATES = ("origin/main", "origin/master", "main", "master", "origin/trunk", "trunk", "origin/develop", "develop")


class GitError(Failure):
    def __init__(self, message: str, details: Optional[dict] = None):
        super().__init__(message, code="GIT_FAILED", details=details)


def git_env(extra: Optional[Dict[str, str]] = None) -> Dict[str, str]:
    env = dict(os.environ)
    # Never block on a credential prompt, never take optional locks the user's own git might be waiting for.
    env.setdefault("GIT_TERMINAL_PROMPT", "0")
    env["GIT_OPTIONAL_LOCKS"] = "0"
    env.setdefault("GIT_PAGER", "cat")
    if extra:
        env.update(extra)
    return env


def run_git(repo: Path, args: Sequence[str], check: bool = True, input_text: Optional[str] = None,
            timeout: float = 300, ok_codes: Sequence[int] = (0,)) -> subprocess.CompletedProcess:
    cmd = ["git", "-C", str(repo)] + list(args)
    try:
        proc = subprocess.run(cmd, input=input_text.encode("utf-8") if input_text is not None else None,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=git_env(), timeout=timeout)
    except FileNotFoundError:
        raise GitError("git is not installed or not on PATH")
    except subprocess.TimeoutExpired:
        raise GitError(f"git {args[0] if args else ''} timed out after {int(timeout)}s")
    if check and proc.returncode not in ok_codes:
        err = proc.stderr.decode("utf-8", "replace").strip().splitlines()
        raise GitError(f"git {' '.join(list(args)[:3])} failed: {err[-1] if err else 'exit ' + str(proc.returncode)}",
                       details={"exitCode": proc.returncode})
    return proc


def git(repo: Path, *args: str, check: bool = True, timeout: float = 300, ok_codes: Sequence[int] = (0,)) -> str:
    proc = run_git(repo, args, check=check, timeout=timeout, ok_codes=ok_codes)
    return proc.stdout.decode("utf-8", "replace")


def git_ok(repo: Path, *args: str) -> Optional[str]:
    """Output of a git command, or None when it fails."""
    try:
        proc = run_git(repo, args, check=False, timeout=60)
    except GitError:
        return None
    if proc.returncode != 0:
        return None
    return proc.stdout.decode("utf-8", "replace").strip()


def repo_root(start: Path) -> Path:
    out = git_ok(Path(start), "rev-parse", "--show-toplevel")
    if not out:
        raise Failure(f"not a git repository: {start}", code="NOT_A_REPOSITORY")
    return Path(out)


def try_repo_root(start: Path) -> Optional[Path]:
    out = git_ok(Path(start), "rev-parse", "--show-toplevel")
    return Path(out) if out else None


def common_dir(root: Path) -> Path:
    out = git_ok(root, "rev-parse", "--path-format=absolute", "--git-common-dir")
    if not out:
        # git older than 2.31 has no --path-format; the plain answer may be relative to the root.
        out = git_ok(root, "rev-parse", "--git-common-dir")
        if not out:
            raise Failure(f"not a git repository: {root}", code="NOT_A_REPOSITORY")
        path = Path(out)
        return path if path.is_absolute() else (Path(root) / path).resolve()
    return Path(out)


def rev(root: Path, ref: str) -> Optional[str]:
    # A leading '-' would be read as an option; no ref name starts with one.
    if not ref or ref.startswith("-"):
        return None
    return git_ok(root, "rev-parse", "--verify", "--quiet", ref + "^{commit}") or None


def head(root: Path) -> Optional[str]:
    return rev(root, "HEAD")


def tree_of(root: Path, ref: str) -> Optional[str]:
    if not ref or ref.startswith("-"):
        return None
    return git_ok(root, "rev-parse", "--verify", "--quiet", ref + "^{tree}") or None


def empty_tree(root: Path) -> str:
    out = git_ok(root, "hash-object", "-t", "tree", os.devnull)
    return out or "4b825dc642cb6eb9a060e54bf8d69288fbee4904"


def current_branch(root: Path) -> Optional[str]:
    return git_ok(root, "symbolic-ref", "--quiet", "--short", "HEAD") or None


def default_branch(root: Path) -> Optional[str]:
    origin_head = git_ok(root, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD")
    if origin_head and rev(root, origin_head):
        return origin_head
    for candidate in DEFAULT_BRANCH_CANDIDATES:
        if rev(root, candidate):
            return candidate
    return None


def merge_base(root: Path, a: str, b: str) -> Optional[str]:
    return git_ok(root, "merge-base", a, b) or None


def ls_files(root: Path) -> List[str]:
    out = git(root, "ls-files", "-z", "--full-name")
    return [p for p in out.split("\0") if p]


def ls_tree(root: Path, rev_: str) -> List[str]:
    """Files in a commit's tree."""
    out = git(root, "ls-tree", "-r", "-z", "--name-only", "--full-tree", rev_)
    return [p for p in out.split("\0") if p]


def untracked_files(root: Path) -> List[str]:
    out = git(root, "ls-files", "-z", "--others", "--exclude-standard", "--full-name")
    return [p for p in out.split("\0") if p]


def is_dirty(root: Path) -> bool:
    out = git(root, "status", "--porcelain=v1", "-z", "--untracked-files=normal")
    return bool(out.strip("\0").strip())


def name_status(root: Path, args: Sequence[str]) -> List[Dict[str, Optional[str]]]:
    """Changed paths from `git diff --name-status -z -M <args>`: [{"path", "oldPath", "status"}]."""
    out = git(root, "diff", "--name-status", "-z", "-M", "--no-ext-diff", "--no-relative", *args)
    parts = out.split("\0")
    items: List[Dict[str, Optional[str]]] = []
    i = 0
    while i < len(parts):
        code = parts[i]
        if not code:
            i += 1
            continue
        letter = code[0]
        if letter in ("R", "C") and i + 2 < len(parts):
            items.append({"status": letter, "oldPath": parts[i + 1], "path": parts[i + 2]})
            i += 3
        elif i + 1 < len(parts):
            items.append({"status": letter, "oldPath": None, "path": parts[i + 1]})
            i += 2
        else:
            break
    return items


def unquote_path(text: str) -> str:
    """Undo git's C-style path quoting ("a\\tb", octal escapes for non-ASCII bytes)."""
    if len(text) < 2 or not (text.startswith('"') and text.endswith('"')):
        return text
    body = text[1:-1]
    out = bytearray()
    i = 0
    simple = {"a": 7, "b": 8, "t": 9, "n": 10, "v": 11, "f": 12, "r": 13, '"': 34, "\\": 92}
    while i < len(body):
        c = body[i]
        if c == "\\" and i + 1 < len(body):
            nxt = body[i + 1]
            if nxt in simple:
                out.append(simple[nxt])
                i += 2
                continue
            if nxt in "01234567" and i + 3 < len(body) + 1:
                digits = body[i + 1:i + 4]
                try:
                    out.append(int(digits, 8) & 0xFF)
                    i += 4
                    continue
                except ValueError:
                    pass
        out.extend(c.encode("utf-8"))
        i += 1
    return out.decode("utf-8", "replace")
