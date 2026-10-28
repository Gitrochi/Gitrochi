"""Access to the repository index written by crates/gitrochi-index (Rust).

Two ways in, matching crates/gitrochi-index/README.md:
- the `gitrochi-index` executable (one JSON document per command), authoritative when it is installed;
- the SQLite file itself, opened read-only (`?mode=ro`) after checking `PRAGMA user_version`.
Every query degrades to None (with a note) when neither is available, so callers keep working without an index.
Python never writes this database.
"""

from __future__ import annotations

import json
import os
import shutil
import sqlite3
import subprocess
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple

from gitrochi import gitutil
from gitrochi.util import Failure, is_executable

SCHEMA_VERSION = 1
BIN_ENV = "GITROCHI_INDEX_BIN"
DB_ENV = "GITROCHI_INDEX_DB"
# The apps' switch: GITROCHI_INDEX=0 turns the repository index off.
SWITCH_ENV = "GITROCHI_INDEX"
EXE = "gitrochi-index.exe" if os.name == "nt" else "gitrochi-index"
# tools/gitrochi-py/gitrochi/index.py -> the Gitrochi checkout this package lives in.
PACKAGE_REPO_ROOT = Path(__file__).resolve().parents[3]


def switched_off() -> bool:
    return os.environ.get(SWITCH_ENV, "").strip().lower() in ("0", "false", "off", "no")


def find_binary(explicit: Optional[str] = None, repo_root: Optional[Path] = None) -> Tuple[Optional[str], str]:
    """(path, how it was found) or (None, why not). An explicit setting that points nowhere is not overridden."""
    if explicit:
        return (explicit if is_executable(explicit) else None), "--index-bin"
    env = os.environ.get(BIN_ENV, "").strip()
    if env:
        return (env if is_executable(env) else None), BIN_ENV
    found = shutil.which("gitrochi-index")
    if found:
        return found, "PATH"
    for base in (repo_root, PACKAGE_REPO_ROOT):
        if base is None:
            continue
        candidate = Path(base) / "crates" / "target" / "release" / EXE
        if is_executable(str(candidate)):
            return str(candidate), "crates/target/release"
    return None, "not found"


def default_db_path(repo_root: Optional[Path]) -> Optional[Path]:
    env = os.environ.get(DB_ENV, "").strip()
    if env:
        return Path(env)
    if repo_root is None:
        return None
    try:
        return gitutil.common_dir(repo_root) / "gitrochi" / "index.sqlite3"
    except Failure:
        return None


def open_readonly(path: Path) -> sqlite3.Connection:
    """Open an index database read-only and check its schema version."""
    if not Path(path).is_file():
        raise Failure(f"no index database at {path} (run `gitrochi-index sync` or pass --sync)", code="INDEX_MISSING")
    uri = Path(path).resolve().as_uri() + "?mode=ro"
    try:
        conn = sqlite3.connect(uri, uri=True, timeout=5)
        version = conn.execute("PRAGMA user_version").fetchone()[0]
    except sqlite3.Error as exc:
        raise Failure(f"cannot read the index database: {exc}", code="DATABASE")
    if version != SCHEMA_VERSION:
        conn.close()
        raise Failure(f"index schema {version} is not supported (expected {SCHEMA_VERSION})", code="SCHEMA_MISMATCH")
    conn.row_factory = sqlite3.Row
    return conn


class Index:
    """The index of one repository; see the module docstring for how it is reached."""

    def __init__(self, repo_root: Optional[Path], binary: Optional[str] = None, db: Optional[str] = None,
                 use_binary: bool = True, enabled: bool = True, timeout: float = 60):
        self.root = Path(repo_root) if repo_root else None
        self.notes: List[str] = []
        # Explicit --index-bin / --index-db win over the environment switch.
        self.switched_off = enabled and switched_off() and not binary and not db
        if self.switched_off:
            enabled = False
            self.notes.append(f"the repository index is turned off ({SWITCH_ENV}=0)")
        self.enabled = enabled
        self.explicit_db = db
        self.timeout = timeout
        if enabled and use_binary:
            self.binary, self.binary_source = find_binary(binary, self.root)
            if self.binary is None and self.binary_source != "not found":
                self.notes.append(f"gitrochi-index from {self.binary_source} is not an executable file; using the database directly")
        else:
            self.binary, self.binary_source = None, "disabled"
        self.db_path: Optional[Path] = Path(db) if db else (default_db_path(self.root) if enabled else None)
        self._conn: Optional[sqlite3.Connection] = None
        self._conn_failed = False
        self._coupling_col = "coupling_commits"

    # ---------- plumbing ----------

    @property
    def db_exists(self) -> bool:
        return bool(self.db_path) and Path(self.db_path).is_file()

    @property
    def source(self) -> str:
        if not self.enabled:
            return "disabled"
        if self.binary and self.db_exists:
            return "binary"
        if self.connection() is not None:
            return "sqlite"
        return "none"

    def describe(self) -> Dict[str, Any]:
        return {"source": self.source, "binary": self.binary, "database": str(self.db_path) if self.db_path else None,
                "notes": list(self.notes)}

    def run(self, command: str, *args: str, timeout: Optional[float] = None) -> Dict[str, Any]:
        """Run one gitrochi-index command and return its JSON document."""
        if not self.binary:
            raise Failure("gitrochi-index is not installed (set GITROCHI_INDEX_BIN or build crates/gitrochi-index)", code="INDEX_UNAVAILABLE")
        cmd = [self.binary]
        if self.root:
            cmd += ["--repo", str(self.root)]
        if self.explicit_db or os.environ.get(DB_ENV):
            cmd += ["--db", str(self.db_path)]
        cmd += [command] + [str(a) for a in args]
        try:
            proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout or self.timeout)
        except subprocess.TimeoutExpired:
            raise Failure(f"gitrochi-index {command} timed out", code="INDEX_TIMEOUT")
        except OSError as exc:
            raise Failure(f"cannot run gitrochi-index: {exc}", code="INDEX_UNAVAILABLE")
        text = proc.stdout.decode("utf-8", "replace").strip()
        try:
            doc = json.loads(text) if text else {}
        except ValueError:
            raise Failure(f"gitrochi-index {command} printed something that is not JSON", code="INDEX_PROTOCOL")
        if proc.returncode != 0:
            err = doc.get("error") if isinstance(doc, dict) else None
            message = err.get("message") if isinstance(err, dict) else proc.stderr.decode("utf-8", "replace").strip()[-300:]
            code = err.get("code") if isinstance(err, dict) else "INDEX_FAILED"
            raise Failure(f"gitrochi-index {command}: {message or 'exit ' + str(proc.returncode)}", code=str(code))
        if not isinstance(doc, dict):
            raise Failure(f"gitrochi-index {command} returned an unexpected document", code="INDEX_PROTOCOL")
        return doc

    def connection(self) -> Optional[sqlite3.Connection]:
        if self._conn is not None or self._conn_failed or not self.enabled:
            return self._conn
        if not self.db_path:
            self._conn_failed = True
            self.notes.append("no repository index (not inside a git repository)")
            return None
        try:
            self._conn = open_readonly(self.db_path)
            self._coupling_col = coupling_column(self._conn)
        except Failure as exc:
            self._conn_failed = True
            self.notes.append(exc.message)
        return self._conn

    def close(self) -> None:
        if self._conn is not None:
            self._conn.close()
            self._conn = None

    def _binary_or_none(self, command: str, positional: Sequence[str], *options: str) -> Optional[Dict[str, Any]]:
        if not (self.binary and self.db_exists):
            return None
        if any(p.startswith("-") for p in positional):
            return None  # a path that looks like an option is answered from the database instead
        try:
            return self.run(command, *positional, *options)
        except Failure as exc:
            self.notes.append(exc.message)
            return None

    # ---------- commands (contract shapes) ----------

    def sync(self, max_files: Optional[int] = None) -> Dict[str, Any]:
        args: List[str] = []
        if max_files:
            args += ["--max-files", str(max_files)]
        doc = self.run("sync", *args, timeout=3600)
        self.close()
        self._conn_failed = False
        return doc

    def file_info(self, path: str, limit: int = 5) -> Optional[Dict[str, Any]]:
        doc = self._binary_or_none("file", [path], "--limit", str(limit))
        if doc is not None:
            return doc
        conn = self.connection()
        if conn is None:
            return None
        pid = _path_id(conn, path)
        if pid is None:
            return {"path": path, "stats": None, "authors": [], "coupled": [], "history": []}
        row = conn.execute("SELECT commits, additions, deletions, first_time, last_time FROM path_stats WHERE path_id = ?", (pid,)).fetchone()
        stats = None
        if row:
            stats = {"commits": row[0], "additions": row[1], "deletions": row[2], "firstTime": row[3], "lastTime": row[4],
                     "couplingCommits": _coupling_commits(conn, pid, self._coupling_col)}
        rows = conn.execute(
            "SELECT c.author_name, c.author_email, c.author_time, COALESCE(fc.additions, 0), COALESCE(fc.deletions, 0) "
            "FROM file_changes fc JOIN commits c ON c.id = fc.commit_id WHERE fc.path_id = ?", (pid,)).fetchall()
        authors = _authors(((r[0], r[1], r[2], r[3], r[4], None) for r in rows))
        coupled = self._partners(conn, pid, limit, 2)
        return {"path": path, "stats": stats, "authors": authors[:limit], "coupled": coupled, "history": _history(conn, pid, limit)}

    def coupled(self, path: str, limit: int = 20, min_commits: int = 2) -> Optional[Dict[str, Any]]:
        doc = self._binary_or_none("coupled", [path], "--limit", str(limit), "--min-commits", str(min_commits))
        if doc is not None:
            return doc
        conn = self.connection()
        if conn is None:
            return None
        pid = _path_id(conn, path)
        if pid is None:
            return {"path": path, "commits": 0, "partners": []}
        return {"path": path, "commits": _path_commits(conn, pid), "partners": self._partners(conn, pid, limit, min_commits)}

    def impact(self, paths: Sequence[str], limit: int = 20, min_confidence: float = 0.3,
               min_commits: int = 2) -> Optional[Dict[str, Any]]:
        paths = [p for p in paths if p][:200]
        if not paths:
            return {"changed": [], "suggestions": []}
        doc = self._binary_or_none("impact", paths, "--limit", str(limit), "--min-confidence", str(min_confidence),
                                   "--min-commits", str(min_commits))
        if doc is not None:
            return doc
        conn = self.connection()
        if conn is None:
            return None
        changed = set(paths)
        found: Dict[str, Dict[str, Any]] = {}
        for path in paths:
            pid = _path_id(conn, path)
            if pid is None:
                continue
            for partner in self._partners(conn, pid, 10_000, min_commits):
                if partner["path"] in changed or partner["confidence"] < min_confidence:
                    continue
                entry = found.setdefault(partner["path"], {"path": partner["path"], "score": 0.0, "because": []})
                entry["because"].append({"path": path, "commits": partner["commits"], "confidence": partner["confidence"]})
                entry["score"] = round(max(entry["score"], partner["confidence"]), 4)
        suggestions = sorted(found.values(), key=lambda s: (-s["score"], -sum(b["commits"] for b in s["because"]), s["path"]))
        return {"changed": paths, "suggestions": suggestions[:limit]}

    def owners(self, prefix: Optional[str] = None, since: Optional[int] = None, limit: int = 20) -> Optional[Dict[str, Any]]:
        options = (["--since", str(since)] if since else []) + ["--limit", str(limit)]
        doc = self._binary_or_none("owners", [prefix] if prefix else [], *options)
        if doc is not None:
            return doc
        conn = self.connection()
        if conn is None:
            return None
        query = ("SELECT DISTINCT c.id, c.author_name, c.author_email, c.author_time FROM file_changes fc "
                 "JOIN commits c ON c.id = fc.commit_id JOIN paths p ON p.id = fc.path_id WHERE c.commit_time >= ?")
        params: List[Any] = [since or 0]
        if prefix:
            query += " AND substr(p.path, 1, ?) = ?"
            params += [len(prefix), prefix]
        rows = conn.execute(query, params).fetchall()
        authors = _authors(((r[1], r[2], r[3], 0, 0, r[0]) for r in rows))
        total = len({r[0] for r in rows})
        for author in authors:
            author["share"] = round(author["commits"] / total, 4) if total else 0.0
        return {"prefix": prefix, "commits": total, "authors": authors[:limit], "busFactor": bus_factor([a["commits"] for a in authors])}

    # ---------- SQL helpers ----------

    def _partners(self, conn: sqlite3.Connection, pid: int, limit: int, min_commits: int) -> List[Dict[str, Any]]:
        """Co-change partners of one path. Confidence and Jaccard use coupling_commits (commits small enough
        for cochange) as the README of crates/gitrochi-index defines them."""
        own = _coupling_commits(conn, pid, self._coupling_col)
        rows = conn.execute(
            "SELECT other, shared, last FROM ("
            " SELECT b AS other, commits AS shared, last_time AS last FROM cochange WHERE a = ? AND commits >= ?"
            " UNION ALL SELECT a, commits, last_time FROM cochange WHERE b = ? AND commits >= ?)"
            " ORDER BY shared DESC, last DESC LIMIT ?", (pid, min_commits, pid, min_commits, limit)).fetchall()
        partners = []
        for other, shared, last in rows:
            info = conn.execute("SELECT path FROM paths WHERE id = ?", (other,)).fetchone()
            if not info:
                continue
            union = own + _coupling_commits(conn, other, self._coupling_col) - shared
            partners.append({
                "path": info[0],
                "commits": shared,
                "confidence": round(min(1.0, shared / own), 4) if own else 0.0,
                "jaccard": round(min(1.0, shared / union), 4) if union > 0 else 0.0,
                "lastTime": last,
            })
        partners.sort(key=lambda p: (-p["confidence"], -p["commits"], p["path"]))
        return partners


def _path_id(conn: sqlite3.Connection, path: str) -> Optional[int]:
    row = conn.execute("SELECT id FROM paths WHERE path = ?", (path,)).fetchone()
    return int(row[0]) if row else None


def _path_commits(conn: sqlite3.Connection, pid: int) -> int:
    row = conn.execute("SELECT commits FROM path_stats WHERE path_id = ?", (pid,)).fetchone()
    if row:
        return int(row[0])
    row = conn.execute("SELECT COUNT(*) FROM file_changes WHERE path_id = ?", (pid,)).fetchone()
    return int(row[0]) if row else 0


def _history(conn: sqlite3.Connection, pid: int, limit: int) -> List[Dict[str, Any]]:
    """Commits that changed a path, newest first: (commit_time DESC, seq DESC) as schema.sql asks; id order before seq existed."""
    columns = {row[1] for row in conn.execute("PRAGMA table_info(commits)").fetchall()}
    order = "c.commit_time DESC, c.seq DESC" if "seq" in columns else "c.commit_time DESC, c.id DESC"
    rows = conn.execute(
        "SELECT c.id, c.sha, c.author_name, c.author_email, c.author_time, c.committer_name, c.committer_email, c.commit_time, "
        "c.subject, c.body, c.files_changed, c.additions, c.deletions FROM file_changes fc JOIN commits c ON c.id = fc.commit_id "
        f"WHERE fc.path_id = ? ORDER BY {order} LIMIT ?", (pid, limit)).fetchall()
    out = []
    for r in rows:
        parents = [p[0] for p in conn.execute("SELECT parent_sha FROM commit_parents WHERE commit_id = ? ORDER BY position", (r[0],))]
        out.append({"sha": r[1], "parents": parents, "authorName": r[2], "authorEmail": r[3], "authorTime": r[4], "committerName": r[5],
                    "committerEmail": r[6], "commitTime": r[7], "subject": r[8], "body": r[9], "filesChanged": r[10],
                    "additions": r[11], "deletions": r[12]})
    return out


def coupling_column(conn: sqlite3.Connection) -> str:
    """The co-change denominator column; early schema-1 databases had no coupling_commits and use commits."""
    columns = {row[1] for row in conn.execute("PRAGMA table_info(path_stats)").fetchall()}
    return "coupling_commits" if "coupling_commits" in columns else "commits"


def _coupling_commits(conn: sqlite3.Connection, pid: int, column: str = "coupling_commits") -> int:
    if column not in ("coupling_commits", "commits"):
        raise ValueError(column)
    row = conn.execute(f"SELECT {column} FROM path_stats WHERE path_id = ?", (pid,)).fetchone()
    return int(row[0]) if row and row[0] is not None else 0


def _authors(rows: Iterable[Tuple[str, str, int, int, int, Optional[int]]]) -> List[Dict[str, Any]]:
    """Aggregate (name, email, time, additions, deletions, commit id) rows into Author objects, most commits first."""
    by_email: Dict[str, Dict[str, Any]] = {}
    for name, email, when, additions, deletions, _cid in rows:
        key = (email or name or "").strip().lower()
        entry = by_email.get(key)
        if entry is None:
            entry = by_email[key] = {"name": name, "email": email, "commits": 0, "additions": 0, "deletions": 0, "lastTime": when}
        entry["commits"] += 1
        entry["additions"] += int(additions or 0)
        entry["deletions"] += int(deletions or 0)
        if when is not None and (entry["lastTime"] is None or when >= entry["lastTime"]):
            entry["lastTime"] = when
            entry["name"] = name
    return sorted(by_email.values(), key=lambda a: (-a["commits"], -(a["lastTime"] or 0), a["email"] or ""))


def bus_factor(commit_counts: Sequence[int]) -> int:
    """The fewest authors who together made at least half of the commits."""
    total = sum(commit_counts)
    if total <= 0:
        return 0
    running = 0
    for count, value in enumerate(sorted(commit_counts, reverse=True), start=1):
        running += value
        if running * 2 >= total:
            return count
    return len(commit_counts)
