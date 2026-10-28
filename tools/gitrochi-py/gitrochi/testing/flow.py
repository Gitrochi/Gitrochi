"""Delegation to the Rust flow engine when the repository has `.gitch/flow.yml` (tools/gitch-flow, docs/flow/).

`gitch-flow test --json` prints the run summary (schema flow-run v1). Each suite node carries test counts
and its failures; the full case list is in the run's report file, which is read when it can be found.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from gitrochi import gitutil, procs
from gitrochi.index import PACKAGE_REPO_ROOT
from gitrochi.util import is_executable

FLOW_FILE = Path(".gitch") / "flow.yml"
EXE = "gitch-flow.exe" if os.name == "nt" else "gitch-flow"


def has_flow(root: Path) -> bool:
    return (Path(root) / FLOW_FILE).is_file()


def find_engine(explicit: Optional[str], root: Path) -> Optional[List[str]]:
    """argv prefix for the flow engine: gitch-flow itself, or `gitch flow` as a fallback."""
    if explicit:
        return [explicit] if is_executable(explicit) else None
    env = os.environ.get("GITCH_FLOW", "").strip()
    if env:
        return [env] if is_executable(env) else None
    found = shutil.which("gitch-flow")
    if found:
        return [found]
    for base in (Path(root), PACKAGE_REPO_ROOT):
        candidate = base / "tools" / "gitch-flow" / "target" / "release" / EXE
        if is_executable(str(candidate)):
            return [str(candidate)]
    gitch = shutil.which("gitch")
    if gitch:
        return [gitch, "flow"]
    return None


def run(root: Path, engine: List[str], affected: bool, suites: List[str], timeout: float) -> Tuple[Optional[Dict[str, Any]], int, str]:
    cmd = engine + ["test", "--json"] + (["--affected"] if affected else []) + list(suites)
    result = procs.run_capture(cmd, cwd=str(root), timeout=timeout)
    output = result["output"] or ""
    doc = _last_json(output)
    code = result["exitCode"] if result["exitCode"] is not None else 1
    return doc, int(code), output


def _last_json(text: str) -> Optional[Dict[str, Any]]:
    """The run summary (pretty-printed JSON on stdout); error envelopes go to stderr, which is merged here."""
    decoder = json.JSONDecoder()
    found: Optional[Dict[str, Any]] = None
    index = 0
    while True:
        start = text.find("{", index)
        if start == -1:
            break
        try:
            value, end = decoder.raw_decode(text, start)
        except ValueError:
            index = start + 1
            continue
        if isinstance(value, dict) and ("nodes" in value or "error" in value):
            if found is None or "nodes" in value:
                found = value
        index = end
    return found


def _report_path(root: Path, run_id: str, rel: str) -> Optional[Path]:
    try:
        common = gitutil.common_dir(root)
    except Exception:
        return None
    worktree_id = hashlib.sha256(str(Path(root).resolve()).encode("utf-8")).hexdigest()[:12]
    path = common / "gitch" / "flow" / "runs" / worktree_id / run_id / rel
    return path if path.is_file() else None


def to_suites(doc: Dict[str, Any], root: Path) -> List[Dict[str, Any]]:
    """SuiteResult-like dicts from a flow run summary, for history and output."""
    out: List[Dict[str, Any]] = []
    run_id = str(doc.get("runId") or "")
    for node in doc.get("nodes") or []:
        tests = node.get("tests")
        if not isinstance(tests, dict):
            continue
        cases_src: List[Dict[str, Any]] = []
        report = node.get("report")
        if run_id and isinstance(report, str):
            path = _report_path(root, run_id, report)
            if path is not None:
                try:
                    cases_src = json.loads(path.read_text(encoding="utf-8")).get("cases") or []
                except (OSError, ValueError, AttributeError):
                    cases_src = []
        if not cases_src:
            cases_src = node.get("failures") or []
        cases = []
        for c in cases_src:
            status = {"passed": "passed", "failed": "failed", "skipped": "skipped", "flaky": "passed", "error": "error"}.get(
                str(c.get("status") or "failed").lower(), "failed")
            flaky = str(c.get("status") or "").lower() == "flaky"
            cases.append({"id": c.get("id") or c.get("name"), "name": c.get("name"), "classname": "", "file": c.get("file"),
                          "status": status, "durationMs": int(c.get("durationMs") or 0), "message": c.get("message"),
                          "attempts": ["failed", "passed"] if flaky else [status], "flaky": flaky})
        counts = {"executed": int(tests.get("executed") or 0), "passed": int(tests.get("passed") or 0),
                  "failed": int(tests.get("failed") or 0), "skipped": int(tests.get("skipped") or 0), "flaky": int(tests.get("flaky") or 0)}
        out.append({"id": node.get("suite") or node.get("id"), "runner": "gitch-flow", "cwd": ".", "command": [],
                    "exitCode": None, "timedOut": False, "durationMs": int(node.get("durationMs") or 0),
                    "ok": node.get("state") in ("PASSED", "CACHED"), "counts": counts, "reruns": max(0, int(node.get("attempts") or 1) - 1),
                    "error": (node.get("failure") or {}).get("detail") if node.get("state") not in ("PASSED", "CACHED") else None,
                    "cases": cases, "state": node.get("state"), "code": node.get("code"), "outputTail": ""})
    return out
