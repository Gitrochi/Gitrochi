"""`gitrochi-py analyze`: hotspots, change coupling, ownership, knowledge-loss risk, weekly trends and outliers."""

from __future__ import annotations

import argparse
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

from gitrochi import gitutil
from gitrochi.analysis import queries, report
from gitrochi.index import Index, open_readonly
from gitrochi.util import Failure, UsageError, emit, envelope, iso, parse_time

SECTIONS = ("hotspots", "coupling", "ownership", "knowledgeLoss", "trends", "outliers")
SECTION_ALIASES = {"hotspots": "hotspots", "coupling": "coupling", "ownership": "ownership", "owners": "ownership",
                   "knowledge-loss": "knowledgeLoss", "knowledgeloss": "knowledgeLoss", "risk": "knowledgeLoss",
                   "trends": "trends", "outliers": "outliers"}


def register(sub: Any, common: argparse.ArgumentParser, index_opts: argparse.ArgumentParser) -> None:
    p = sub.add_parser("analyze", parents=[common, index_opts], help="repository analysis from the index",
                       description="Analyse the repository index (read-only): hotspots, change coupling clusters, ownership and "
                                   "bus factor, knowledge-loss risk, weekly trends and large-commit outliers.")
    p.add_argument("--sync", action="store_true", help="run `gitrochi-index sync` first")
    p.add_argument("--since", help="only commits after this time (Unix seconds, YYYY-MM-DD or an age such as 90d)")
    p.add_argument("--prefix", help="only paths starting with this prefix (e.g. src/)")
    p.add_argument("--top", type=int, default=10, help="rows per section (default 10)")
    p.add_argument("--only", help="comma-separated sections: hotspots,coupling,ownership,knowledge-loss,trends,outliers")
    p.add_argument("--format", choices=("text", "json", "markdown", "html"), help="text (default), json, markdown or html")
    p.add_argument("--out", metavar="FILE", help="write the report to FILE")
    tuning = p.add_argument_group("tuning")
    tuning.add_argument("--half-life", type=float, default=90.0, metavar="DAYS", help="hotspot recency half-life (default 90)")
    tuning.add_argument("--min-coupling", type=int, default=3, metavar="N", help="shared commits for a coupling pair (default 3)")
    tuning.add_argument("--min-jaccard", type=float, default=0.3, help="Jaccard similarity for a coupling pair (default 0.3)")
    tuning.add_argument("--depth", type=int, default=1, help="folder depth for ownership (default 1)")
    tuning.add_argument("--inactive-days", type=int, default=180, help="author inactivity for knowledge-loss risk (default 180)")
    tuning.add_argument("--weeks", type=int, default=26, help="weeks of trend without --since (default 26)")
    tuning.add_argument("--outlier-z", type=float, default=3.5, help="robust z-score for outliers (default 3.5)")
    tuning.add_argument("--include-deleted", action="store_true", help="keep files that no longer exist in HEAD")
    tuning.add_argument("--now", help="reference time instead of the current time (for reproducible reports)")
    p.set_defaults(func=run)


def _sections(only: Optional[str]) -> List[str]:
    if not only:
        return list(SECTIONS)
    out = []
    for raw in only.split(","):
        name = SECTION_ALIASES.get(raw.strip().lower())
        if name is None:
            raise UsageError(f"unknown section {raw.strip()!r} (choose {', '.join(SECTION_ALIASES)})")
        if name not in out:
            out.append(name)
    return out


def run(args: argparse.Namespace) -> int:
    if args.no_index:
        raise UsageError("analyze needs the index; remove --no-index")
    fmt = "json" if args.json else (args.format or "text")
    if args.top < 1:
        raise UsageError("--top must be at least 1")
    root = gitutil.try_repo_root(Path(args.repo))
    if root is None and not args.index_db:
        raise Failure(f"not a git repository: {args.repo} (or pass --index-db)", code="NOT_A_REPOSITORY")
    index = Index(root, args.index_bin, args.index_db)
    if index.switched_off:
        raise Failure("the repository index is turned off (GITROCHI_INDEX=0); unset it or pass --index-db FILE", code="INDEX_DISABLED")
    notes: List[str] = []
    synced: Optional[Dict[str, Any]] = None
    if args.sync:
        if root is None:
            raise UsageError("--sync needs a repository (--repo)")
        synced = index.run("sync", timeout=3600) if index.binary else None
        if synced is None:
            raise Failure("--sync needs the gitrochi-index executable (set GITROCHI_INDEX_BIN or build crates/gitrochi-index)", code="INDEX_UNAVAILABLE")
    if not index.db_path:
        raise Failure("no index database (pass --index-db)", code="INDEX_MISSING")
    conn = open_readonly(index.db_path)
    now = parse_time(args.now) if args.now else int(time.time())
    existing = None
    if root is not None and not args.include_deleted:
        try:
            existing = set(gitutil.ls_files(root))
        except Failure:
            notes.append("could not list the files in HEAD; deleted files are included")
    opts = queries.Options(now=now, since=parse_time(args.since, now), prefix=args.prefix or None, top=args.top,
                           half_life_days=max(1.0, args.half_life), min_coupling_commits=max(1, args.min_coupling),
                           min_jaccard=args.min_jaccard, depth=max(1, args.depth), inactive_days=max(1, args.inactive_days),
                           weeks=max(1, args.weeks), outlier_z=args.outlier_z, existing=existing)
    sections = _sections(args.only)
    overview = queries.overview(conn)
    doc: Dict[str, Any] = envelope("analyze", generatedAt=iso(time.time()), now=now, since=opts.since, prefix=opts.prefix,
                                   sections=sections, index=dict(overview, database=str(index.db_path), schemaVersion=1))
    if synced is not None:
        doc["sync"] = synced
    if "hotspots" in sections:
        doc["hotspots"] = queries.hotspots(conn, opts)
    if "coupling" in sections:
        doc["coupling"] = queries.coupling(conn, opts, overview.get("maxFiles") or 30)
    if "ownership" in sections:
        doc["ownership"] = queries.ownership(conn, opts)
    if "knowledgeLoss" in sections:
        doc["knowledgeLoss"] = queries.knowledge_loss(conn, opts)
    if "trends" in sections:
        doc["trends"] = queries.trends(conn, opts)
    if "outliers" in sections:
        doc["outliers"] = queries.outliers(conn, opts)
    conn.close()
    if overview["commits"] == 0:
        notes.append("the index has no commits yet (run gitrochi-index sync)")
    if overview.get("shallow"):
        notes.append("the index is shallow: older history is not included")
    doc["notes"] = notes + index.notes
    emit(report.render(doc, fmt), args.out)
    return 0
