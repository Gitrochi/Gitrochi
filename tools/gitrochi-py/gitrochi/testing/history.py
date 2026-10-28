"""Test history in `<git common dir>/gitrochi/tests.sqlite3`. Python owns this database (never the Rust index).

A run records each test attempt with the commit and a tree key: the HEAD tree for a clean worktree, or the
tree plus a hash of the uncommitted changes. Passing and failing on the same tree key is flakiness evidence.
"""

from __future__ import annotations

import hashlib
import sqlite3
import statistics
import time
from collections import defaultdict
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

from gitrochi import gitutil
from gitrochi.util import iso_week, week_start

SCHEMA_VERSION = 1
SCHEMA = """
CREATE TABLE IF NOT EXISTS runs (
    id          INTEGER PRIMARY KEY,
    started     INTEGER NOT NULL,
    finished    INTEGER NOT NULL,
    commit_sha  TEXT,
    tree_key    TEXT,
    branch      TEXT,
    dirty       INTEGER NOT NULL DEFAULT 0,
    source      TEXT NOT NULL,
    selection   TEXT NOT NULL,
    executed    INTEGER NOT NULL DEFAULT 0,
    passed      INTEGER NOT NULL DEFAULT 0,
    failed      INTEGER NOT NULL DEFAULT 0,
    skipped     INTEGER NOT NULL DEFAULT 0,
    flaky       INTEGER NOT NULL DEFAULT 0,
    duration_ms INTEGER NOT NULL DEFAULT 0,
    exit_code   INTEGER
);
CREATE INDEX IF NOT EXISTS runs_tree ON runs (tree_key);
CREATE INDEX IF NOT EXISTS runs_started ON runs (started);
CREATE TABLE IF NOT EXISTS results (
    run_id      INTEGER NOT NULL REFERENCES runs (id) ON DELETE CASCADE,
    suite       TEXT NOT NULL,
    test_id     TEXT NOT NULL,
    name        TEXT,
    file        TEXT,
    status      TEXT NOT NULL,
    duration_ms INTEGER NOT NULL DEFAULT 0,
    attempt     INTEGER NOT NULL DEFAULT 1,
    message     TEXT
);
CREATE INDEX IF NOT EXISTS results_test ON results (test_id, run_id);
CREATE INDEX IF NOT EXISTS results_run ON results (run_id);
"""


def default_path(root: Path) -> Path:
    return gitutil.common_dir(root) / "gitrochi" / "tests.sqlite3"


def tree_key(root: Path) -> Dict[str, Any]:
    """Commit, branch and a key for the exact tree the tests ran on."""
    commit = gitutil.head(root)
    tree = gitutil.tree_of(root, "HEAD") if commit else gitutil.empty_tree(root)
    dirty = gitutil.is_dirty(root)
    key = tree
    if dirty:
        digest = hashlib.sha256()
        proc = gitutil.run_git(root, ["diff", "HEAD" if commit else "--cached", "--binary", "--no-ext-diff", "--no-color"], check=False)
        digest.update(proc.stdout)
        untracked = gitutil.untracked_files(root)[:2000]
        if untracked:
            hashed = gitutil.run_git(root, ["hash-object", "--stdin-paths"], check=False, input_text="\n".join(untracked) + "\n")
            digest.update("\n".join(untracked).encode("utf-8"))
            digest.update(hashed.stdout)
        key = f"{tree}+{digest.hexdigest()[:16]}"
    return {"commit": commit, "tree": tree, "treeKey": key, "dirty": dirty, "branch": gitutil.current_branch(root)}


class History:
    def __init__(self, path: Path, readonly: bool = False):
        self.path = Path(path)
        if readonly:
            if not self.path.is_file():
                self.conn = None
                return
            self.conn = sqlite3.connect(self.path.resolve().as_uri() + "?mode=ro", uri=True, timeout=10)
        else:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            self.conn = sqlite3.connect(str(self.path), timeout=10)
            self.conn.execute("PRAGMA journal_mode=WAL")
            version = self.conn.execute("PRAGMA user_version").fetchone()[0]
            if version not in (0, SCHEMA_VERSION):
                raise ValueError(f"test history schema {version} is newer than this tool understands")
            self.conn.executescript(SCHEMA)
            self.conn.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")
            self.conn.commit()
        self.conn.row_factory = sqlite3.Row

    def close(self) -> None:
        if self.conn is not None:
            self.conn.close()
            self.conn = None

    # ---------- writing ----------

    def record(self, identity: Dict[str, Any], source: str, selection: str, suites: Sequence[Dict[str, Any]],
               started: float, exit_code: int) -> int:
        """Store one run: `suites` are SuiteResult.to_dict() shapes (cases with their attempts)."""
        assert self.conn is not None
        totals = {"executed": 0, "passed": 0, "failed": 0, "skipped": 0, "flaky": 0}
        duration = 0
        for suite in suites:
            for key in totals:
                totals[key] += int((suite.get("counts") or {}).get(key, 0))
            duration += int(suite.get("durationMs") or 0)
        cur = self.conn.execute(
            "INSERT INTO runs (started, finished, commit_sha, tree_key, branch, dirty, source, selection, executed, passed, failed, "
            "skipped, flaky, duration_ms, exit_code) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (int(started), int(time.time()), identity.get("commit"), identity.get("treeKey"), identity.get("branch"),
             1 if identity.get("dirty") else 0, source, selection, totals["executed"], totals["passed"], totals["failed"],
             totals["skipped"], totals["flaky"], duration, exit_code))
        run_id = int(cur.lastrowid)
        rows = []
        for suite in suites:
            for case in suite.get("cases") or []:
                attempts = case.get("attempts") or [case.get("status")]
                for number, status in enumerate(attempts, start=1):
                    rows.append((run_id, suite.get("id"), case.get("id"), case.get("name"), case.get("file"), status,
                                 int(case.get("durationMs") or 0) if number == len(attempts) else 0, number,
                                 (case.get("message") or None) if status in ("failed", "error") else None))
        self.conn.executemany("INSERT INTO results (run_id, suite, test_id, name, file, status, duration_ms, attempt, message) "
                              "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", rows)
        self.conn.commit()
        return run_id

    # ---------- reading ----------

    def runs(self, limit: int = 20) -> List[Dict[str, Any]]:
        if self.conn is None:
            return []
        rows = self.conn.execute("SELECT * FROM runs ORDER BY id DESC LIMIT ?", (limit,)).fetchall()
        return [_run_dict(r) for r in rows]

    def test_timeline(self, test_id: str, limit: int = 50) -> List[Dict[str, Any]]:
        if self.conn is None:
            return []
        rows = self.conn.execute(
            "SELECT r.run_id, r.suite, r.status, r.attempt, r.duration_ms, r.message, runs.started, runs.commit_sha, runs.tree_key "
            "FROM results r JOIN runs ON runs.id = r.run_id WHERE r.test_id = ? ORDER BY r.run_id DESC, r.attempt DESC LIMIT ?",
            (test_id, limit)).fetchall()
        return [{"run": r["run_id"], "suite": r["suite"], "status": r["status"], "attempt": r["attempt"], "durationMs": r["duration_ms"],
                 "message": r["message"], "started": r["started"], "commit": r["commit_sha"], "treeKey": r["tree_key"]} for r in rows]

    def _outcomes(self, since: Optional[int]) -> Dict[Tuple[str, str], List[Tuple[int, int, str, Optional[str], int]]]:
        assert self.conn is not None
        rows = self.conn.execute(
            "SELECT r.suite, r.test_id, r.run_id, r.attempt, r.status, runs.tree_key, runs.started FROM results r "
            "JOIN runs ON runs.id = r.run_id WHERE r.status IN ('passed', 'failed', 'error') AND runs.started >= ? "
            "ORDER BY r.run_id, r.attempt", (since or 0,)).fetchall()
        out: Dict[Tuple[str, str], List[Tuple[int, int, str, Optional[str], int]]] = defaultdict(list)
        for suite, test_id, run_id, attempt, status, tree, started in rows:
            out[(suite, test_id)].append((run_id, attempt, "fail" if status in ("failed", "error") else "pass", tree, started))
        return out

    def flaky(self, min_runs: int = 3, min_flip_rate: float = 0.2, since: Optional[int] = None, top: int = 20) -> List[Dict[str, Any]]:
        """Tests that passed and failed on the same tree, or flip between pass and fail often."""
        if self.conn is None:
            return []
        found = []
        for (suite, test_id), outcomes in self._outcomes(since).items():
            states = [o[2] for o in outcomes]
            by_tree: Dict[Optional[str], set] = defaultdict(set)
            for _, _, state, tree, _ in outcomes:
                by_tree[tree].add(state)
            same_tree = sum(1 for tree, seen in by_tree.items() if tree and len(seen) == 2)
            flips = sum(1 for a, b in zip(states, states[1:]) if a != b)
            rate = flips / (len(states) - 1) if len(states) > 1 else 0.0
            runs = len({o[0] for o in outcomes})
            if same_tree == 0 and not (runs >= min_runs and rate >= min_flip_rate and flips > 0):
                continue
            found.append({"suite": suite, "test": test_id, "runs": runs, "attempts": len(states),
                          "passes": states.count("pass"), "fails": states.count("fail"), "flips": flips,
                          "flipRate": round(rate, 4), "sameTreeConflicts": same_tree, "lastSeen": max(o[4] for o in outcomes),
                          "reason": "passed and failed on the same tree" if same_tree else "flips between pass and fail"})
        found.sort(key=lambda f: (-f["sameTreeConflicts"], -f["flipRate"], -f["fails"], f["test"]))
        return found[:top]

    def slowest(self, top: int = 10, runs: int = 20) -> List[Dict[str, Any]]:
        if self.conn is None:
            return []
        rows = self.conn.execute(
            "SELECT r.suite, r.test_id, r.duration_ms FROM results r WHERE r.status = 'passed' AND r.run_id IN "
            "(SELECT id FROM runs ORDER BY id DESC LIMIT ?)", (runs,)).fetchall()
        times: Dict[Tuple[str, str], List[int]] = defaultdict(list)
        for suite, test_id, ms in rows:
            if ms:
                times[(suite, test_id)].append(int(ms))
        out = []
        for (suite, test_id), values in times.items():
            values.sort()
            p95 = values[min(len(values) - 1, int(round(0.95 * (len(values) - 1))))]
            out.append({"suite": suite, "test": test_id, "samples": len(values), "averageMs": int(statistics.mean(values)),
                        "p95Ms": p95, "maxMs": values[-1]})
        out.sort(key=lambda t: (-t["averageMs"], t["test"]))
        return out[:top]

    def trends(self, weeks: int = 12, now: Optional[int] = None, top: int = 5) -> Dict[str, Any]:
        if self.conn is None:
            return {"weeks": [], "topFailing": []}
        end = week_start(now or time.time())
        start = end - (max(1, weeks) - 1) * 7 * 86400
        buckets: Dict[int, Dict[str, Any]] = {}
        t = start
        while t <= end:
            buckets[t] = {"week": iso_week(t), "start": t, "runs": 0, "failedRuns": 0, "results": 0, "failedResults": 0}
            t += 7 * 86400
        for row in self.conn.execute("SELECT id, started, failed FROM runs WHERE started >= ?", (start,)).fetchall():
            bucket = buckets.get(week_start(row["started"]))
            if bucket is None:
                continue
            bucket["runs"] += 1
            bucket["failedRuns"] += 1 if row["failed"] else 0
        for started, status in self.conn.execute(
                "SELECT runs.started, r.status FROM results r JOIN runs ON runs.id = r.run_id WHERE runs.started >= ? AND r.attempt = 1 "
                "AND r.status != 'skipped'", (start,)).fetchall():
            bucket = buckets.get(week_start(started))
            if bucket is None:
                continue
            bucket["results"] += 1
            bucket["failedResults"] += 1 if status in ("failed", "error") else 0
        weeks_out = []
        for _, b in sorted(buckets.items()):
            b["runFailureRate"] = round(b["failedRuns"] / b["runs"], 4) if b["runs"] else None
            b["testFailureRate"] = round(b["failedResults"] / b["results"], 4) if b["results"] else None
            weeks_out.append(b)
        failing = self.conn.execute(
            "SELECT r.suite, r.test_id, COUNT(*) AS fails FROM results r JOIN runs ON runs.id = r.run_id "
            "WHERE runs.started >= ? AND r.status IN ('failed', 'error') AND r.attempt = 1 GROUP BY r.suite, r.test_id "
            "ORDER BY fails DESC, r.test_id LIMIT ?", (start, top)).fetchall()
        return {"weeks": weeks_out, "topFailing": [{"suite": r[0], "test": r[1], "failures": r[2]} for r in failing]}


def _run_dict(r: sqlite3.Row) -> Dict[str, Any]:
    return {"id": r["id"], "started": r["started"], "finished": r["finished"], "commit": r["commit_sha"], "treeKey": r["tree_key"],
            "branch": r["branch"], "dirty": bool(r["dirty"]), "source": r["source"], "selection": r["selection"],
            "counts": {"executed": r["executed"], "passed": r["passed"], "failed": r["failed"], "skipped": r["skipped"], "flaky": r["flaky"]},
            "durationMs": r["duration_ms"], "exitCode": r["exit_code"]}
