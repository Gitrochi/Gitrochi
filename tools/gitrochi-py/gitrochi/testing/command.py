"""`gitrochi-py test plan|run|history|flaky|slow|trends`."""

from __future__ import annotations

import argparse
import json
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any, Dict, List, Optional

from gitrochi import gitutil
from gitrochi.index import Index
from gitrochi.testing import flow, history, plan, runners
from gitrochi.testing.runners import Suite, SuiteResult
from gitrochi.util import Failure, UsageError, age_text, day, dumps, emit, envelope, parse_time, plural, table, truncate


def register(sub: Any, common: argparse.ArgumentParser, index_opts: argparse.ArgumentParser) -> None:
    p = sub.add_parser("test", help="test automation: plan, run, history, flaky and slow tests",
                       description="Plan the tests a change needs, run them, and keep a history to find flaky and slow tests.")
    tsub = p.add_subparsers(dest="test_command", metavar="<subcommand>", parser_class=type(p))
    tsub.required = True

    hist = argparse.ArgumentParser(add_help=False)
    hist.add_argument("--history-db", metavar="FILE", help="history database (default: <git common dir>/gitrochi/tests.sqlite3)")

    selection = argparse.ArgumentParser(add_help=False)
    selection.add_argument("--base", help="compare with this commit (default: merge-base with the default branch)")
    selection.add_argument("--head", help="head commit (default: HEAD and the uncommitted changes)")
    selection.add_argument("--committed-only", action="store_true", help="ignore uncommitted changes")
    selection.add_argument("--no-graph", action="store_true", help="do not ask `gitch graph affected` for static dependents")
    selection.add_argument("--gitch-bin", metavar="PATH", help="gitch executable (default: $GITCH, PATH, tools/gitch/gitch)")
    selection.add_argument("--min-score", type=float, default=0.3, help="lowest candidate score that is run (default 0.3)")
    selection.add_argument("--python", default=sys.executable, help="interpreter for Python tests (default: this one)")

    sp = tsub.add_parser("plan", parents=[common, index_opts, selection], help="changed files -> ranked candidate tests")
    sp.set_defaults(func=run_plan)

    sr = tsub.add_parser("run", parents=[common, index_opts, selection, hist], help="run the planned tests (or --all)")
    sr.add_argument("--all", action="store_true", help="run every test suite found in the repository")
    sr.add_argument("--plan", metavar="FILE", help="run the suites of a saved `test plan --json` document")
    sr.add_argument("--jobs", type=int, default=2, help="suites run in parallel (default 2)")
    sr.add_argument("--timeout", type=float, default=900, help="seconds per suite (default 900)")
    sr.add_argument("--rerun-failures", type=int, default=0, metavar="N", help="rerun failing tests up to N times; a pass marks them flaky")
    sr.add_argument("--flaky", choices=("warn", "fail"), default="warn", help="whether a flaky pass fails the run (default warn)")
    sr.add_argument("--flow-bin", metavar="PATH", help="gitch-flow executable (default: $GITCH_FLOW, PATH, tools/gitch-flow/target/release)")
    sr.add_argument("--no-flow", action="store_true", help="use the built-in runners even when .gitch/flow.yml exists")
    sr.add_argument("--no-history", action="store_true", help="do not record this run")
    sr.add_argument("--dry-run", action="store_true", help="print the suites and commands without running them")
    sr.set_defaults(func=run_tests)

    sh = tsub.add_parser("history", parents=[common, hist], help="recent test runs, or one test's timeline")
    sh.add_argument("--limit", type=int, default=20)
    sh.add_argument("--test", metavar="ID", help="show the results of one test id")
    sh.set_defaults(func=run_history)

    sf = tsub.add_parser("flaky", parents=[common, hist], help="tests that passed and failed on the same tree, or flip often")
    sf.add_argument("--min-runs", type=int, default=3, help="runs before a flip rate counts (default 3)")
    sf.add_argument("--min-flip-rate", type=float, default=0.2, help="flip rate that flags a test (default 0.2)")
    sf.add_argument("--since", help="only runs after this time (Unix seconds, YYYY-MM-DD or an age such as 30d)")
    sf.add_argument("--top", type=int, default=20)
    sf.add_argument("--fail", action="store_true", help="exit 1 when a flaky test is found")
    sf.set_defaults(func=run_flaky)

    ss = tsub.add_parser("slow", parents=[common, hist], help="slowest tests over the recent runs")
    ss.add_argument("--top", type=int, default=10)
    ss.add_argument("--runs", type=int, default=20, help="recent runs to consider (default 20)")
    ss.set_defaults(func=run_slow)

    st = tsub.add_parser("trends", parents=[common, hist], help="weekly failure rates and the most failing tests")
    st.add_argument("--weeks", type=int, default=12)
    st.add_argument("--top", type=int, default=5)
    st.set_defaults(func=run_trends)


def _index(args: argparse.Namespace, root: Path) -> Index:
    return Index(root, args.index_bin, args.index_db, enabled=not args.no_index)


# ---------- plan ----------

def run_plan(args: argparse.Namespace) -> int:
    root = gitutil.repo_root(Path(args.repo))
    index = _index(args, root)
    doc = plan.build(root, args.base, args.head, index, use_graph=not args.no_graph, gitch_bin=args.gitch_bin,
                     include_worktree=not args.committed_only, python=args.python, min_score=args.min_score)
    index.close()
    for suite in doc["suites"]:
        suite["command"] = runners.command(Suite.from_dict(suite), "<report>", python=args.python)
    out = envelope("test plan", **doc)
    if args.json:
        emit(dumps(out))
        return 0
    rng = doc["range"]
    lines = [f"Test plan for {rng['baseRef']}...{rng['headRef']}{' + uncommitted changes' if rng['includesWorktree'] else ''}: "
             f"{plural(len(doc['changed']), 'changed file')}"]
    if doc["runAll"]:
        lines.append(f"Run everything: {doc['runAllReason']}")
    if doc["candidates"]:
        lines.append("Candidates:")
        for c in doc["candidates"][:40]:
            best = c["reasons"][0] if c["reasons"] else {"kind": "-", "detail": ""}
            mark = " " if c["selected"] else "~"
            lines.append(f" {mark}{c['score']:.2f}  {c['path']}  [{c['runner'] or 'no runner'}]  {best['kind']}: {best['detail']}")
    if doc["suites"]:
        lines.append("Suites:")
        for s in doc["suites"]:
            lines.append(f"  {s['id']}: {plural(len(s['tests']), 'test file')} -> {' '.join(s['command'][:6])}{' ...' if len(s['command']) > 6 else ''}")
    for note in doc["notes"]:
        lines.append(f"Note: {note}")
    emit("\n".join(lines))
    return 0


# ---------- run ----------

def _suites_from_plan_file(path: str) -> List[Suite]:
    try:
        doc = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise UsageError(f"cannot read the plan {path}: {exc}")
    suites = doc.get("suites") if isinstance(doc, dict) else None
    if not isinstance(suites, list):
        raise UsageError(f"{path} is not a `test plan --json` document")
    out = []
    for item in suites:
        suite = Suite.from_dict(item)
        if suite.runner not in runners.RUNNERS:
            raise UsageError(f"unknown runner {suite.runner!r} in {path}")
        out.append(suite)
    return out


def _run_suite(suite: Suite, root: Path, args: argparse.Namespace) -> SuiteResult:
    result = runners.execute(suite, root, args.timeout, python=args.python)
    if args.rerun_failures > 0 and any(c.bad for c in result.cases):
        runners.rerun_failures(result, root, args.rerun_failures, args.timeout, python=args.python)
    return result


def run_tests(args: argparse.Namespace) -> int:
    root = gitutil.repo_root(Path(args.repo))
    if args.all and args.plan:
        raise UsageError("use either --all or --plan")
    if args.jobs < 1:
        raise UsageError("--jobs must be at least 1")
    started = time.time()
    identity = history.tree_key(root)
    notes: List[str] = []
    if not args.no_flow and not args.plan and flow.has_flow(root):
        engine = flow.find_engine(args.flow_bin, root)
        if engine is not None:
            if args.dry_run:
                return _emit_run(args, {"mode": "flow", "dryRun": True, "command": engine + ["test", "--json"] + ([] if args.all else ["--affected"])},
                                 0)
            return _run_flow(args, root, engine, identity, started)
        notes.append(".gitch/flow.yml exists but gitch-flow was not found; using the built-in runners")
    plan_doc: Optional[Dict[str, Any]] = None
    if args.plan:
        suites, selection = _suites_from_plan_file(args.plan), "plan-file"
    elif args.all:
        suites, selection = plan.all_suites(root, args.python), "all"
    else:
        index = _index(args, root)
        plan_doc = plan.build(root, args.base, args.head, index, use_graph=not args.no_graph, gitch_bin=args.gitch_bin,
                              include_worktree=not args.committed_only, python=args.python, min_score=args.min_score)
        index.close()
        notes += plan_doc["notes"]
        if plan_doc["runAll"]:
            suites, selection = plan.all_suites(root, args.python), "all"
            notes.append(plan_doc["runAllReason"])
        else:
            suites, selection = [Suite.from_dict(s) for s in plan_doc["suites"]], "plan"
    if args.dry_run:
        return _emit_run(args, {"mode": selection, "dryRun": True,
                                "suites": [dict(s.to_dict(), command=runners.command(s, "<report>", python=args.python)) for s in suites],
                                "notes": notes}, 0)
    if not suites:
        if selection == "all":
            raise Failure("no test suites were found in this repository", code="NO_TESTS")
        doc = {"mode": selection, "runId": None, "commit": identity["commit"], "treeKey": identity["treeKey"], "suites": [],
               "counts": {"executed": 0, "passed": 0, "failed": 0, "skipped": 0, "flaky": 0}, "flaky": [], "failures": [],
               "result": "no-tests", "exitCode": 0, "notes": notes + ["nothing to run for this change"]}
        return _emit_run(args, doc, 0)
    with ThreadPoolExecutor(max_workers=min(args.jobs, len(suites))) as pool:
        results = list(pool.map(lambda s: _run_suite(s, root, args), suites))
    suite_docs = [r.to_dict() for r in results]
    return _finish(args, root, identity, started, "builtin", selection, suite_docs, notes, all(r.ok for r in results))


def _run_flow(args: argparse.Namespace, root: Path, engine: List[str], identity: Dict[str, Any], started: float) -> int:
    doc, code, output = flow.run(root, engine, affected=not args.all, suites=[], timeout=max(args.timeout, 60) * 4)
    if doc is None or "nodes" not in doc:
        err = (doc or {}).get("error") if isinstance(doc, dict) else None
        message = (err or {}).get("message") if isinstance(err, dict) else None
        tail = (output.strip().splitlines() or ["no output"])[-1]
        if code == 2:
            raise Failure(f"gitch-flow needs a person to confirm: {message or tail} (run `gitch flow trust` in a terminal)",
                          code=str((err or {}).get("flowCode") or "FLOW_CONFIRMATION"))
        raise Failure(f"gitch-flow test failed: {message or tail[:300]}", code=str((err or {}).get("flowCode") or "FLOW_FAILED"))
    suites = flow.to_suites(doc, root)
    notes = [f"delegated to gitch-flow (run {doc.get('runId')}, state {doc.get('state')})"]
    flow_info = {"runId": doc.get("runId"), "state": doc.get("state"), "code": doc.get("code"), "exitCode": code}
    return _finish(args, root, identity, started, "gitch-flow", "flow" if not args.all else "flow-all", suites, notes, code == 0,
                   extra={"flowRun": flow_info})


def _finish(args: argparse.Namespace, root: Path, identity: Dict[str, Any], started: float, source: str, selection: str,
            suite_docs: List[Dict[str, Any]], notes: List[str], ok: bool, extra: Optional[Dict[str, Any]] = None) -> int:
    totals = {"executed": 0, "passed": 0, "failed": 0, "skipped": 0, "flaky": 0}
    for suite in suite_docs:
        for key in totals:
            totals[key] += int(suite["counts"].get(key, 0))
    flaky = [c["id"] for s in suite_docs for c in s["cases"] if c.get("flaky")]
    failures = [{"suite": s["id"], "id": c["id"], "file": c.get("file"), "message": truncate(c.get("message") or "", 600)}
                for s in suite_docs for c in s["cases"] if c["status"] in ("failed", "error")]
    for s in suite_docs:
        if not s.get("ok") and s.get("error"):
            failures.append({"suite": s["id"], "id": None, "file": None, "message": s["error"]})
    result = "failed" if not ok else ("flaky" if flaky else "passed")
    exit_code = 1 if result == "failed" or (result == "flaky" and args.flaky == "fail") else 0
    run_id = None
    history_path = None
    if not args.no_history:
        history_path = Path(args.history_db) if args.history_db else history.default_path(root)
        store = history.History(history_path)
        try:
            run_id = store.record(identity, source, selection, suite_docs, started, exit_code)
        finally:
            store.close()
    doc = {"mode": selection, "source": source, "runId": run_id, "commit": identity["commit"], "branch": identity["branch"],
           "treeKey": identity["treeKey"], "dirty": identity["dirty"], "suites": suite_docs, "counts": totals, "flaky": flaky,
           "failures": failures, "result": result, "exitCode": exit_code, "history": str(history_path) if history_path else None,
           "notes": notes}
    if extra:
        doc.update(extra)
    return _emit_run(args, doc, exit_code)


def _emit_run(args: argparse.Namespace, doc: Dict[str, Any], exit_code: int) -> int:
    out = envelope("test run", **doc)
    if args.json:
        emit(dumps(out))
        return exit_code
    if doc.get("dryRun"):
        lines = [f"Dry run ({doc['mode']}):"]
        if doc.get("command"):
            lines.append("  " + " ".join(doc["command"]))
        for s in doc.get("suites") or []:
            lines.append(f"  {s['id']} (in {s['cwd']}): {' '.join(s['command'])}")
        lines += [f"Note: {n}" for n in doc.get("notes") or []]
        emit("\n".join(lines))
        return exit_code
    short = (doc.get("commit") or "")[:10]
    lines = [f"Test run ({doc['mode']}) on {doc.get('branch') or 'detached'} {short}{' (uncommitted changes)' if doc.get('dirty') else ''}"]
    for s in doc["suites"]:
        c = s["counts"]
        mark = "PASS" if s.get("ok") else "FAIL"
        extra = f", {c['flaky']} flaky" if c.get("flaky") else ""
        lines.append(f"  {mark} {s['id']}: {c['passed']} passed, {c['failed']} failed, {c['skipped']} skipped{extra} "
                     f"({s['durationMs'] / 1000:.1f}s){' - ' + s['error'] if s.get('error') and not s.get('ok') else ''}")
    if doc["failures"]:
        lines.append("Failures:")
        for f in doc["failures"][:30]:
            first = (f.get("message") or "").strip().splitlines()
            lines.append(f"  {f.get('id') or f['suite']}{' (' + f['file'] + ')' if f.get('file') else ''}: {truncate(first[-1] if first else '', 160)}")
    if doc["flaky"]:
        lines.append("Flaky (failed, then passed on a rerun): " + ", ".join(doc["flaky"][:20]))
    c = doc["counts"]
    run_text = f" · history run #{doc['runId']}" if doc.get("runId") else ""
    lines.append(f"Result: {doc['result'].upper()} · {c['executed']} executed, {c['failed']} failed, {c['flaky']} flaky{run_text}")
    lines += [f"Note: {n}" for n in doc.get("notes") or []]
    emit("\n".join(lines))
    return exit_code


# ---------- history ----------

def _history(args: argparse.Namespace) -> history.History:
    root = gitutil.repo_root(Path(args.repo))
    path = Path(args.history_db) if args.history_db else history.default_path(root)
    return history.History(path, readonly=True)


def run_history(args: argparse.Namespace) -> int:
    store = _history(args)
    try:
        if args.test:
            timeline = store.test_timeline(args.test, args.limit)
            doc = envelope("test history", test=args.test, results=timeline)
            if args.json:
                emit(dumps(doc))
                return 0
            rows = [(r["run"], day(r["started"]), (r["commit"] or "")[:10], r["attempt"], r["status"], r["durationMs"]) for r in timeline]
            emit(f"History of {args.test}\n" + (table(rows, ["run", "date", "commit", "attempt", "status", "ms"], "rllrlr") if rows else "no results"))
            return 0
        runs = store.runs(args.limit)
    finally:
        store.close()
    doc = envelope("test history", runs=runs)
    if args.json:
        emit(dumps(doc))
        return 0
    now = time.time()
    rows = [(r["id"], age_text(now - r["started"]) + " ago", (r["commit"] or "")[:10] + ("*" if r["dirty"] else ""), r["source"], r["selection"],
             r["counts"]["executed"], r["counts"]["failed"], r["counts"]["flaky"], r["exitCode"]) for r in runs]
    emit(table(rows, ["run", "when", "commit", "source", "selection", "tests", "failed", "flaky", "exit"], "rllllrrrr") if rows else "no test runs recorded yet")
    return 0


def run_flaky(args: argparse.Namespace) -> int:
    store = _history(args)
    try:
        found = store.flaky(args.min_runs, args.min_flip_rate, parse_time(args.since), args.top)
    finally:
        store.close()
    doc = envelope("test flaky", minRuns=args.min_runs, minFlipRate=args.min_flip_rate, tests=found)
    code = 1 if (args.fail and found) else 0
    if args.json:
        emit(dumps(doc))
        return code
    rows = [(f["test"], f["suite"], f["runs"], f["passes"], f["fails"], f"{f['flipRate']:.2f}", f["sameTreeConflicts"], f["reason"]) for f in found]
    emit(table(rows, ["test", "suite", "runs", "passes", "fails", "flip rate", "same tree", "why"], "llrrrrrl") if rows else "no flaky tests found")
    return code


def run_slow(args: argparse.Namespace) -> int:
    store = _history(args)
    try:
        found = store.slowest(args.top, args.runs)
    finally:
        store.close()
    doc = envelope("test slow", runs=args.runs, tests=found)
    if args.json:
        emit(dumps(doc))
        return 0
    rows = [(t["test"], t["suite"], t["samples"], t["averageMs"], t["p95Ms"], t["maxMs"]) for t in found]
    emit(table(rows, ["test", "suite", "samples", "avg ms", "p95 ms", "max ms"], "llrrrr") if rows else "no timings recorded yet")
    return 0


def run_trends(args: argparse.Namespace) -> int:
    store = _history(args)
    try:
        data = store.trends(args.weeks, top=args.top)
    finally:
        store.close()
    doc = envelope("test trends", **data)
    if args.json:
        emit(dumps(doc))
        return 0
    rows = [(w["week"], w["runs"], w["failedRuns"], "-" if w["runFailureRate"] is None else f"{w['runFailureRate']:.0%}",
             "-" if w["testFailureRate"] is None else f"{w['testFailureRate']:.1%}") for w in data["weeks"]]
    text = table(rows, ["week", "runs", "failed runs", "run failure rate", "test failure rate"], "lrrrr")
    if data["topFailing"]:
        text += "\nMost failing tests:\n" + "\n".join(f"  {t['failures']:>3}  {t['test']} ({t['suite']})" for t in data["topFailing"])
    emit(text)
    return 0
