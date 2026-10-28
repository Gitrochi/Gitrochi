"""Analyses over the index tables (crates/gitrochi-index/src/schema.sql). The connection is read-only.

Times are commit times unless noted; author activity uses author times. Merge commits have no file changes
in the index, so every per-file number below counts non-merge commits.
"""

from __future__ import annotations

import math
import sqlite3
import statistics
from collections import defaultdict
from dataclasses import dataclass
from typing import Any, Dict, Iterable, List, Optional, Sequence, Set, Tuple

from gitrochi.index import bus_factor, coupling_column
from gitrochi.util import iso_week, week_start

DAY = 86400


@dataclass
class Options:
    now: int
    since: Optional[int] = None
    prefix: Optional[str] = None
    top: int = 10
    half_life_days: float = 90.0
    min_coupling_commits: int = 3
    min_jaccard: float = 0.3
    depth: int = 1
    inactive_days: int = 180
    min_file_commits: int = 3
    weeks: int = 26
    outlier_z: float = 3.5
    existing: Optional[Set[str]] = None  # paths in HEAD; deleted files are left out when known


def _prefix_sql(prefix: Optional[str], column: str = "p.path") -> Tuple[str, List[Any]]:
    if not prefix:
        return "", []
    return f" AND substr({column}, 1, ?) = ?", [len(prefix), prefix]


def _keep(path: str, opts: Options) -> bool:
    if opts.prefix and not path.startswith(opts.prefix):
        return False
    return opts.existing is None or path in opts.existing


def overview(conn: sqlite3.Connection) -> Dict[str, Any]:
    meta = {row[0]: row[1] for row in conn.execute("SELECT key, value FROM meta").fetchall()}
    commits, newest, oldest = conn.execute("SELECT COUNT(*), MAX(commit_time), MIN(commit_time) FROM commits").fetchone()
    paths = conn.execute("SELECT COUNT(*) FROM paths").fetchone()[0]
    return {"commits": commits, "paths": paths, "newestCommitTime": newest, "oldestCommitTime": oldest,
            "lastSync": _int_or_none(meta.get("last_sync")), "maxFiles": _int_or_none(meta.get("max_files")),
            "shallow": meta.get("shallow") in ("1", "true")}


def _int_or_none(value: Any) -> Optional[int]:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _changes(conn: sqlite3.Connection, opts: Options) -> Iterable[sqlite3.Row]:
    clause, params = _prefix_sql(opts.prefix)
    return conn.execute(
        "SELECT p.path, c.id AS cid, c.commit_time, c.author_time, c.author_name, c.author_email, "
        "COALESCE(fc.additions, 0) AS additions, COALESCE(fc.deletions, 0) AS deletions "
        "FROM file_changes fc JOIN commits c ON c.id = fc.commit_id JOIN paths p ON p.id = fc.path_id "
        "WHERE c.commit_time >= ?" + clause, [opts.since or 0] + params)


def hotspots(conn: sqlite3.Connection, opts: Options) -> List[Dict[str, Any]]:
    """Churn weighted by recency: sum over changes of 0.5^(age/half-life) * (1 + ln(1 + lines changed))."""
    acc: Dict[str, Dict[str, Any]] = {}
    for row in _changes(conn, opts):
        path = row["path"]
        if not _keep(path, opts):
            continue
        entry = acc.get(path)
        if entry is None:
            entry = acc[path] = {"path": path, "commits": 0, "additions": 0, "deletions": 0, "authors": set(), "lastTime": 0, "score": 0.0}
        lines = row["additions"] + row["deletions"]
        age_days = max(0.0, (opts.now - row["commit_time"]) / DAY)
        entry["commits"] += 1
        entry["additions"] += row["additions"]
        entry["deletions"] += row["deletions"]
        entry["authors"].add((row["author_email"] or row["author_name"] or "").lower())
        entry["lastTime"] = max(entry["lastTime"], row["commit_time"])
        entry["score"] += (0.5 ** (age_days / opts.half_life_days)) * (1.0 + math.log1p(lines))
    out = []
    for entry in acc.values():
        entry["churn"] = entry["additions"] + entry["deletions"]
        entry["authors"] = len(entry["authors"])
        entry["score"] = round(entry["score"], 3)
        out.append(entry)
    out.sort(key=lambda e: (-e["score"], -e["churn"], e["path"]))
    return [{k: e[k] for k in ("path", "commits", "churn", "additions", "deletions", "authors", "lastTime", "score")} for e in out[:opts.top]]


def coupling(conn: sqlite3.Connection, opts: Options, max_files: int = 30) -> Dict[str, Any]:
    """Clusters of files that change together: connected components over pairs with enough shared commits and Jaccard."""
    edges: List[Dict[str, Any]] = []
    if opts.since:
        pairs, totals = _window_pairs(conn, opts, max_files)
        for (a, b), (shared, last) in pairs.items():
            edges.append(_edge(a, b, shared, last, totals.get(a, 0), totals.get(b, 0)))
    else:
        column = coupling_column(conn)
        rows = conn.execute(
            f"SELECT pa.path, pb.path, cc.commits, cc.last_time, sa.{column}, sb.{column} FROM cochange cc "
            "JOIN paths pa ON pa.id = cc.a JOIN paths pb ON pb.id = cc.b "
            "JOIN path_stats sa ON sa.path_id = cc.a JOIN path_stats sb ON sb.path_id = cc.b WHERE cc.commits >= ?",
            (opts.min_coupling_commits,)).fetchall()
        for a, b, shared, last, ca, cb in rows:
            edges.append(_edge(a, b, shared, last, ca, cb))
    edges = [e for e in edges if e["commits"] >= opts.min_coupling_commits and e["jaccard"] >= opts.min_jaccard
             and _keep(e["a"], opts) and _keep(e["b"], opts)]
    parent: Dict[str, str] = {}

    def find(x: str) -> str:
        parent.setdefault(x, x)
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    for e in edges:
        ra, rb = find(e["a"]), find(e["b"])
        if ra != rb:
            parent[max(ra, rb)] = min(ra, rb)
    groups: Dict[str, List[Dict[str, Any]]] = defaultdict(list)
    for e in edges:
        groups[find(e["a"])].append(e)
    clusters = []
    for group_edges in groups.values():
        files = sorted({e["a"] for e in group_edges} | {e["b"] for e in group_edges})
        strength = sum(e["jaccard"] for e in group_edges) / len(group_edges)
        group_edges.sort(key=lambda e: (-e["jaccard"], -e["commits"], e["a"], e["b"]))
        clusters.append({"files": files[:25], "size": len(files), "truncated": len(files) > 25,
                         "strength": round(strength, 4), "commits": max(e["commits"] for e in group_edges),
                         "edges": group_edges[:10]})
    clusters.sort(key=lambda c: (-(c["size"] * c["strength"]), -c["commits"], c["files"][0]))
    for number, cluster in enumerate(clusters, start=1):
        cluster["id"] = number
    return {"minCommits": opts.min_coupling_commits, "minJaccard": opts.min_jaccard, "pairs": len(edges),
            "clusters": [dict({"id": c["id"]}, **{k: v for k, v in c.items() if k != "id"}) for c in clusters[:opts.top]]}


def _edge(a: str, b: str, shared: int, last: int, ca: int, cb: int) -> Dict[str, Any]:
    union = ca + cb - shared
    return {"a": a, "b": b, "commits": shared, "lastTime": last,
            "jaccard": round(min(1.0, shared / union), 4) if union > 0 else 0.0,
            "confidence": round(min(1.0, shared / min(ca, cb)), 4) if min(ca, cb) > 0 else 0.0}


def _window_pairs(conn: sqlite3.Connection, opts: Options, max_files: int):
    """Co-change counts recomputed for the --since window (the cochange table covers all history)."""
    by_commit: Dict[int, Tuple[int, List[str]]] = {}
    for row in conn.execute(
            "SELECT c.id, c.commit_time, p.path FROM file_changes fc JOIN commits c ON c.id = fc.commit_id "
            "JOIN paths p ON p.id = fc.path_id WHERE c.commit_time >= ? AND c.files_changed <= ?", (opts.since or 0, max_files)):
        entry = by_commit.setdefault(row[0], (row[1], []))
        entry[1].append(row[2])
    pairs: Dict[Tuple[str, str], List[int]] = {}
    totals: Dict[str, int] = defaultdict(int)
    for when, paths in by_commit.values():
        unique_paths = sorted(set(paths))
        for p in unique_paths:
            totals[p] += 1
        for i, a in enumerate(unique_paths):
            for b in unique_paths[i + 1:]:
                item = pairs.setdefault((a, b), [0, 0])
                item[0] += 1
                item[1] = max(item[1], when)
    return {k: (v[0], v[1]) for k, v in pairs.items()}, totals


def _directory(path: str, prefix: Optional[str], depth: int) -> str:
    rest = path[len(prefix):] if prefix and path.startswith(prefix) else path
    parts = rest.split("/")
    if len(parts) <= 1:
        return (prefix or "") or "."
    return (prefix or "") + "/".join(parts[:depth])


def ownership(conn: sqlite3.Connection, opts: Options) -> List[Dict[str, Any]]:
    """Main authors and bus factor per folder (the fewest authors with at least half of the folder's commits)."""
    dirs: Dict[str, Dict[str, Any]] = {}
    for row in _changes(conn, opts):
        if not _keep(row["path"], opts):
            continue
        folder = _directory(row["path"], opts.prefix, opts.depth)
        entry = dirs.setdefault(folder, {"commits": set(), "authors": {}})
        entry["commits"].add(row["cid"])
        key = (row["author_email"] or row["author_name"] or "").lower()
        author = entry["authors"].setdefault(key, {"name": row["author_name"], "email": row["author_email"], "commits": set(), "lastTime": 0})
        author["commits"].add(row["cid"])
        if row["author_time"] >= author["lastTime"]:
            author["lastTime"] = row["author_time"]
            author["name"] = row["author_name"]
    out = []
    for folder, entry in dirs.items():
        total = len(entry["commits"])
        authors = sorted(({"name": a["name"], "email": a["email"], "commits": len(a["commits"]), "lastTime": a["lastTime"]}
                          for a in entry["authors"].values()), key=lambda a: (-a["commits"], a["email"] or ""))
        for a in authors:
            a["share"] = round(a["commits"] / total, 4) if total else 0.0
        out.append({"directory": folder, "commits": total, "authorCount": len(authors),
                    "busFactor": bus_factor([a["commits"] for a in authors]), "authors": authors[:5]})
    out.sort(key=lambda d: (-d["commits"], d["directory"]))
    return out[:max(opts.top, 1)]


def knowledge_loss(conn: sqlite3.Connection, opts: Options) -> Dict[str, Any]:
    """Files whose commits come mostly from authors with no commit in the last N days."""
    last_active: Dict[str, int] = {}
    for email, name, when in conn.execute("SELECT author_email, author_name, MAX(author_time) FROM commits GROUP BY lower(author_email)"):
        last_active[(email or name or "").lower()] = when
    cutoff = opts.now - opts.inactive_days * DAY
    files: Dict[str, Dict[str, Any]] = {}
    clause, params = _prefix_sql(opts.prefix)
    for row in conn.execute(
            "SELECT p.path, c.author_name, c.author_email, c.commit_time FROM file_changes fc JOIN commits c ON c.id = fc.commit_id "
            "JOIN paths p ON p.id = fc.path_id WHERE 1 = 1" + clause, params):
        if not _keep(row[0], opts):
            continue
        entry = files.setdefault(row[0], {"commits": 0, "authors": {}, "lastTime": 0})
        entry["commits"] += 1
        entry["lastTime"] = max(entry["lastTime"], row[3])
        key = (row[2] or row[1] or "").lower()
        author = entry["authors"].setdefault(key, {"name": row[1], "email": row[2], "commits": 0})
        author["commits"] += 1
    risky = []
    for path, entry in files.items():
        if entry["commits"] < opts.min_file_commits:
            continue
        authors = sorted(entry["authors"].items(), key=lambda kv: (-kv[1]["commits"], kv[0]))
        inactive = sum(a["commits"] for key, a in authors if last_active.get(key, 0) < cutoff)
        share = inactive / entry["commits"]
        main_key, main = authors[0]
        if share < 0.5 or last_active.get(main_key, 0) >= cutoff:
            continue
        risky.append({"path": path, "commits": entry["commits"], "inactiveShare": round(share, 4), "lastTime": entry["lastTime"],
                      "activeAuthors": sum(1 for key, _ in authors if last_active.get(key, 0) >= cutoff),
                      "mainAuthor": {"name": main["name"], "email": main["email"], "commits": main["commits"],
                                     "lastActive": last_active.get(main_key)}})
    risky.sort(key=lambda r: (-(r["inactiveShare"] * math.log1p(r["commits"])), r["path"]))
    return {"inactiveDays": opts.inactive_days, "files": risky[:opts.top], "atRisk": len(risky)}


def trends(conn: sqlite3.Connection, opts: Options) -> Dict[str, Any]:
    """Commits, churn and active authors per ISO week (UTC), with a least-squares slope of commits per week."""
    end = week_start(opts.now)
    start = week_start(opts.since) if opts.since else end - (max(1, opts.weeks) - 1) * 7 * DAY
    start = max(start, end - 519 * 7 * DAY)  # at most ten years of weeks
    buckets: Dict[int, Dict[str, Any]] = {}
    t = start
    while t <= end:
        buckets[t] = {"week": iso_week(t), "start": t, "commits": set(), "churn": 0, "authors": set()}
        t += 7 * DAY
    clause, params = _prefix_sql(opts.prefix)
    for path, cid, when, email, lines in conn.execute(
            "SELECT p.path, c.id, c.commit_time, lower(c.author_email), COALESCE(fc.additions, 0) + COALESCE(fc.deletions, 0) "
            "FROM file_changes fc JOIN commits c ON c.id = fc.commit_id JOIN paths p ON p.id = fc.path_id "
            "WHERE c.commit_time >= ? AND c.commit_time < ?" + clause, [start, end + 7 * DAY] + params):
        bucket = buckets.get(week_start(when))
        if bucket is None:
            continue
        bucket["commits"].add(cid)
        bucket["churn"] += lines
        bucket["authors"].add(email)
    weeks = [{"week": b["week"], "start": b["start"], "commits": len(b["commits"]), "churn": b["churn"], "authors": len(b["authors"])}
             for _, b in sorted(buckets.items())]
    series = [w["commits"] for w in weeks]
    slope = _slope(series)
    recent = series[-4:]
    previous = series[-8:-4]
    recent_avg = sum(recent) / len(recent) if recent else 0.0
    previous_avg = sum(previous) / len(previous) if previous else 0.0
    change = (recent_avg - previous_avg) / previous_avg if previous_avg else None
    return {"weeks": weeks, "slope": round(slope, 4), "recentAverage": round(recent_avg, 2),
            "previousAverage": round(previous_avg, 2), "change": round(change, 4) if change is not None else None,
            "direction": "up" if slope > 0.05 else ("down" if slope < -0.05 else "flat")}


def _slope(values: Sequence[float]) -> float:
    n = len(values)
    if n < 2:
        return 0.0
    mean_x = (n - 1) / 2
    mean_y = sum(values) / n
    num = sum((i - mean_x) * (v - mean_y) for i, v in enumerate(values))
    den = sum((i - mean_x) ** 2 for i in range(n))
    return num / den if den else 0.0


def outliers(conn: sqlite3.Connection, opts: Options) -> Dict[str, Any]:
    """Unusually large commits by a robust z-score of log(1 + lines changed): 0.6745 * (x - median) / MAD."""
    query = ("SELECT sha, subject, author_name, author_email, commit_time, files_changed, additions, deletions FROM commits "
             "WHERE parent_count <= 1 AND commit_time >= ?")
    params: List[Any] = [opts.since or 0]
    if opts.prefix:
        query += (" AND id IN (SELECT fc.commit_id FROM file_changes fc JOIN paths p ON p.id = fc.path_id "
                  "WHERE substr(p.path, 1, ?) = ?)")
        params += [len(opts.prefix), opts.prefix]
    rows = conn.execute(query, params).fetchall()
    if len(rows) < 5:
        return {"threshold": opts.outlier_z, "median": None, "commits": [], "considered": len(rows)}
    values = [math.log1p(r[6] + r[7]) for r in rows]
    median = statistics.median(values)
    mad = statistics.median([abs(v - median) for v in values])
    scale = mad / 0.6745 if mad > 0 else (statistics.pstdev(values) or 0.0)
    found = []
    if scale > 0:
        for row, value in zip(rows, values):
            z = (value - median) / scale
            if z >= opts.outlier_z:
                found.append({"sha": row[0], "subject": row[1], "authorName": row[2], "authorEmail": row[3], "commitTime": row[4],
                              "filesChanged": row[5], "additions": row[6], "deletions": row[7], "size": row[6] + row[7],
                              "score": round(z, 2)})
    found.sort(key=lambda r: (-r["score"], -r["size"], r["sha"]))
    return {"threshold": opts.outlier_z, "median": int(round(math.expm1(median))), "considered": len(rows), "commits": found[:opts.top]}
