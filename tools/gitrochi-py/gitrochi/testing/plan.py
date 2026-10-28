"""`test plan`: changed files -> ranked candidate tests with reasons, grouped into runnable suites.

Evidence, combined as 1 - prod(1 - score):
  changed  the test file itself changed
  naming   naming conventions across languages (foo.ts <-> foo.test.ts, Foo.swift <-> FooTests.swift, ...)
  cochange source and test changed together in the past (repository index)
  graph    the test depends on changed code (`gitch graph affected --json`)
No candidates is not the same as "no tests needed": the plan says so in its notes.
"""

from __future__ import annotations

import json
import os
import shutil
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

from gitrochi import gitutil, procs
from gitrochi.index import PACKAGE_REPO_ROOT, Index
from gitrochi.testing import discover
from gitrochi.testing.runners import Suite
from gitrochi.util import Failure, UsageError, is_executable

GRAPH_SCORE = 0.75
MAX_COCHANGE_SCORE = 0.9


@dataclass
class Candidate:
    path: str
    reasons: List[Dict[str, Any]] = field(default_factory=list)
    runner: Optional[str] = None
    project: Optional[str] = None

    @property
    def score(self) -> float:
        remaining = 1.0
        for reason in self.reasons:
            remaining *= 1.0 - float(reason["score"])
        return round(1.0 - remaining, 4)

    def add(self, kind: str, detail: str, score: float, source: Optional[str] = None) -> None:
        for reason in self.reasons:
            if reason["kind"] == kind and reason.get("from") == source:
                reason["score"] = max(reason["score"], round(score, 4))
                return
        self.reasons.append({"kind": kind, "detail": detail, "from": source, "score": round(score, 4)})

    def to_dict(self) -> Dict[str, Any]:
        return {"path": self.path, "score": self.score, "runner": self.runner, "project": self.project if self.project else ".",
                "reasons": sorted(self.reasons, key=lambda r: -r["score"])}


def changed_files(root: Path, base: Optional[str], head: Optional[str], include_worktree: bool = True) -> Tuple[List[Dict[str, Any]], Dict[str, Any]]:
    """Paths changed since the merge-base with `base` (default: the default branch), plus uncommitted work."""
    for ref, name in ((base, "--base"), (head, "--head")):
        if ref is not None and (not ref.strip() or ref.startswith("-")):
            raise UsageError(f"{name} must be a commit")
    base_ref = base or gitutil.default_branch(root)
    if base_ref is None:
        raise Failure("could not find the default branch; pass --base REF", code="NO_BASE")
    base_sha = gitutil.rev(root, base_ref)
    if not base_sha:
        raise Failure(f"unknown commit: {base_ref}", code="UNKNOWN_REF")
    head_ref = head or "HEAD"
    head_sha = gitutil.rev(root, head_ref)
    if not head_sha:
        raise Failure(f"unknown commit: {head_ref}", code="UNKNOWN_REF")
    mb = gitutil.merge_base(root, base_sha, head_sha)
    if not mb:
        raise Failure(f"{base_ref} and {head_ref} have no common history", code="NO_MERGE_BASE")
    if head is None and include_worktree:
        items = gitutil.name_status(root, [mb])
        items += [{"status": "A", "oldPath": None, "path": p} for p in gitutil.untracked_files(root)]
    else:
        items = gitutil.name_status(root, [mb, head_sha])
    seen = set()
    unique = []
    for item in items:
        if item["path"] not in seen:
            seen.add(item["path"])
            unique.append(item)
    return unique, {"base": base_sha, "baseRef": base_ref, "mergeBase": mb, "head": head_sha, "headRef": head_ref,
                    "includesWorktree": head is None and include_worktree}


def find_gitch(explicit: Optional[str], root: Path) -> Optional[str]:
    if explicit:
        return explicit if is_executable(explicit) else None
    env = os.environ.get("GITCH", "").strip()
    if env:
        return env if is_executable(env) else None
    found = shutil.which("gitch")
    if found:
        return found
    for base in (Path(root), PACKAGE_REPO_ROOT):
        candidate = base / "tools" / "gitch" / "gitch"
        if is_executable(str(candidate)):
            return str(candidate)
    return None


def graph_affected(root: Path, gitch: str, base: str, timeout: float = 180) -> Tuple[Optional[List[str]], Optional[str]]:
    """Files that depend on the change according to `gitch graph affected --json` (None and a reason on failure)."""
    cmd = [gitch, "graph", "affected", "--base", base, "--json"]
    if os.name == "nt" and gitch.endswith(("gitch", ".sh")):
        bash = shutil.which("bash")
        if bash:
            cmd = [bash] + cmd
    result = procs.run_capture(cmd, cwd=str(root), timeout=timeout)
    if result["timedOut"]:
        return None, f"gitch graph affected timed out after {int(timeout)}s"
    if result["exitCode"] != 0:
        tail = (result["output"] or result["error"] or "").strip().splitlines()[-1:] or ["no output"]
        return None, f"gitch graph affected failed: {tail[0][:200]}"
    try:
        start = result["output"].index("{")
        doc = json.loads(result["output"][start:])
    except (ValueError, json.JSONDecodeError):
        return None, "gitch graph affected did not print JSON"
    affected = (doc.get("stats") or {}).get("affected") or doc.get("affected") or {}
    files = affected.get("files")
    if files is None:
        files = [n.get("id") or n.get("path") for n in doc.get("nodes") or [] if isinstance(n, dict) and n.get("affected")]
    return [f for f in files if isinstance(f, str)], None


def build(root: Path, base: Optional[str] = None, head: Optional[str] = None, index: Optional[Index] = None,
          use_graph: bool = True, gitch_bin: Optional[str] = None, include_worktree: bool = True,
          python: str = sys.executable, min_score: float = 0.3) -> Dict[str, Any]:
    changed, rng = changed_files(root, base, head, include_worktree)
    tracked = gitutil.ls_files(root) if head is None else gitutil.ls_tree(root, rng["head"])
    universe = sorted(set(tracked) | set(gitutil.untracked_files(root) if include_worktree and head is None else []))
    # Only test files need to exist on disk (deleted but still tracked ones are left out); stat nothing else.
    tests = [p for p in universe if discover.is_test_file(p) and (head is not None or (Path(root) / p).exists())]
    existing = set(tests)
    candidates: Dict[str, Candidate] = {}
    notes: List[str] = []
    sources: Dict[str, Any] = {"naming": True, "index": "disabled", "graph": "disabled"}

    def cand(path: str) -> Candidate:
        if path not in candidates:
            candidates[path] = Candidate(path)
        return candidates[path]

    run_all_reason = None
    for item in changed:
        path = item["path"]
        name = path.rsplit("/", 1)[-1]
        if run_all_reason is None and (name in discover.RUN_ALL_FILES or path.startswith(discover.RUN_ALL_PREFIXES)):
            run_all_reason = f"{path} changed (dependencies or configuration): every test may be affected"
        if item["status"] == "D":
            if discover.is_test_file(path):
                notes.append(f"test file deleted: {path}")
            continue
        if discover.is_test_file(path):
            if path in existing:
                cand(path).add("changed", "the test file itself changed", 1.0)
            continue
        for test, score, why in discover.naming_matches(path, tests):
            cand(test).add("naming", why, score, path)
        if discover.language(path) == "rust" and discover.rust_has_unit_tests(root, path):
            cand(path).add("naming", f"{path.rsplit('/', 1)[-1]} contains its own #[cfg(test)] unit tests", 0.9, path)

    if index is not None and index.enabled:
        sources["index"] = index.source
        source_paths = [i["path"] for i in changed if i["status"] != "D" and not discover.is_test_file(i["path"])][:100]
        for path in source_paths:
            doc = index.coupled(path, limit=50, min_commits=2)
            for partner in (doc or {}).get("partners") or []:
                test = partner.get("path")
                if test in existing and discover.is_test_file(test):
                    confidence = float(partner.get("confidence") or 0)
                    if confidence <= 0:
                        continue
                    cand(test).add("cochange", f"changed together with {path} in {partner.get('commits')} commits ({confidence:.0%})",
                                   min(MAX_COCHANGE_SCORE, confidence), path)
        notes += index.notes

    if use_graph:
        gitch = find_gitch(gitch_bin, root)
        if gitch is None:
            sources["graph"] = "unavailable"
            notes.append("gitch not found: static dependents were not considered")
        else:
            files, problem = graph_affected(root, gitch, rng["mergeBase"])
            if files is None:
                sources["graph"] = "failed"
                notes.append(problem or "gitch graph affected failed")
            else:
                sources["graph"] = "ok"
                changed_paths = {i["path"] for i in changed}
                for path in files:
                    if path in existing and discover.is_test_file(path) and path not in changed_paths:
                        cand(path).add("graph", "depends on changed code (gitch graph affected)", GRAPH_SCORE)

    for candidate in candidates.values():
        candidate.runner, candidate.project = runner_for(root, candidate.path, universe, python)
    ranked = sorted(candidates.values(), key=lambda c: (-c.score, c.path))
    selected = [c for c in ranked if c.score >= min_score]
    suites = group(root, selected, universe)
    if len(selected) < len(ranked):
        notes.append(f"{len(ranked) - len(selected)} weak candidate(s) below score {min_score} are listed but not run")
    unsupported = [c.path for c in ranked if c.runner is None]
    if unsupported:
        notes.append(f"no supported runner for {len(unsupported)} candidate(s): " + ", ".join(unsupported[:5]))
    if not ranked:
        notes.append("no candidate tests were found; that does not mean no tests are needed")
    return {
        "range": rng,
        "changed": [{"path": i["path"], "status": i["status"], "oldPath": i.get("oldPath")} for i in changed],
        "runAll": run_all_reason is not None,
        "runAllReason": run_all_reason,
        "minScore": min_score,
        "candidates": [dict(c.to_dict(), selected=c.score >= min_score) for c in ranked],
        "suites": [s.to_dict() for s in suites],
        "sources": sources,
        "notes": notes,
    }


def runner_for(root: Path, path: str, universe: Sequence[str], python: str = sys.executable) -> Tuple[Optional[str], Optional[str]]:
    lang = discover.language(path)
    if lang == "python":
        project = discover.project_dir(path, universe, ("pyproject.toml", "setup.cfg", "setup.py", "pytest.ini", "tox.ini")) or ""
        return discover.python_runner(root, project, [path], python), project
    if lang == "js":
        project = discover.project_dir(path, universe, ("package.json",))
        if project is None:
            return None, None
        return discover.js_runner(root, project), project
    if lang == "go":
        project = discover.project_dir(path, universe, ("go.mod",))
        return ("go", project) if project is not None else (None, None)
    if lang == "rust":
        project = discover.project_dir(path, universe, ("Cargo.toml",))
        return ("cargo", project) if project is not None else (None, None)
    if lang == "swift":
        project = discover.project_dir(path, universe, ("Package.swift",))
        return ("swift", project) if project is not None else (None, None)
    return None, None


def group(root: Path, ranked: Sequence[Candidate], universe: Sequence[str]) -> List[Suite]:
    """One suite per (runner, project); Rust splits integration targets from unit tests."""
    suites: Dict[Tuple[str, str, str], Suite] = {}
    for c in ranked:
        if c.runner is None:
            continue
        project = c.project or ""
        if c.runner == "go":
            key = ("go", project, "")
            suite = suites.setdefault(key, Suite(_suite_id("go", project), "go", project, [], {"packages": [], "tests": []}))
            rel = c.path[len(project) + 1:] if project else c.path
            folder = rel.rsplit("/", 1)[0] if "/" in rel else ""
            package = "./" + folder if folder else "."
            if package not in suite.selectors["packages"]:
                suite.selectors["packages"].append(package)
            suite.tests.append(c.path)
            suite.selectors["tests"] = sorted(set(suite.selectors["tests"]) | set(discover.go_test_names(root, c.path)))
            continue
        if c.runner == "cargo":
            manifest = f"{project}/Cargo.toml" if project else "Cargo.toml"
            module = discover.rust_module_path(c.path, project)
            integration = discover.is_test_file(c.path)
            kind = "integration" if integration else "unit"
            key = ("cargo", project, kind)
            suite = suites.setdefault(key, Suite(_suite_id("cargo", project, kind), "cargo", "", [], {"manifest": manifest}))
            suite.tests.append(c.path)
            if integration:
                suite.selectors.setdefault("targets", []).append(c.path.rsplit("/", 1)[-1][:-3])
            else:
                suite.selectors["lib"] = True
                if module:
                    suite.selectors.setdefault("filters", []).append(module + "::")
            continue
        key = (c.runner, project, "")
        suite = suites.setdefault(key, Suite(_suite_id(c.runner, project), c.runner, project, [], {}))
        suite.tests.append(c.path)
    for suite in suites.values():
        if suite.runner == "swift":
            classes = sorted({t.rsplit("/", 1)[-1][:-6] for t in suite.tests if t.endswith(".swift")})
            if classes:
                suite.selectors["filter"] = "|".join(classes)
    return list(suites.values())


def _suite_id(runner: str, project: str, kind: str = "") -> str:
    return f"{runner}:{project or '.'}" + (f":{kind}" if kind else "")


def all_suites(root: Path, python: str = sys.executable) -> List[Suite]:
    """`test run --all`: the whole test suite of every project found in the repository."""
    universe = gitutil.ls_files(root)
    existing = [p for p in universe if (Path(root) / p).exists()]
    suites: List[Suite] = []
    py_tests = [p for p in existing if discover.language(p) == "python" and discover.is_test_file(p)]
    by_project: Dict[str, List[str]] = {}
    for test in py_tests:
        project = discover.project_dir(test, existing, ("pyproject.toml", "setup.cfg", "setup.py", "pytest.ini", "tox.ini")) or ""
        by_project.setdefault(project, []).append(test)
    for project, tests in sorted(by_project.items()):
        runner = discover.python_runner(root, project, tests, python)
        suites.append(Suite(_suite_id(runner, project), runner, project, tests, {}, True))
    for marker, runner in (("go.mod", "go"), ("Package.swift", "swift")):
        for path in existing:
            if path.rsplit("/", 1)[-1] == marker:
                project = path.rsplit("/", 1)[0] if "/" in path else ""
                selectors: Dict[str, Any] = {"packages": ["./..."]} if runner == "go" else {}
                suites.append(Suite(_suite_id(runner, project), runner, project, [], selectors, True))
    cargo_dirs = sorted(p.rsplit("/", 1)[0] if "/" in p else "" for p in existing if p.rsplit("/", 1)[-1] == "Cargo.toml")
    workspaces = [d for d in cargo_dirs if _is_workspace(root, d)]
    for d in cargo_dirs:
        if any(w != d and (w == "" or d.startswith(w + "/")) for w in workspaces):
            continue
        manifest = f"{d}/Cargo.toml" if d else "Cargo.toml"
        suites.append(Suite(_suite_id("cargo", d), "cargo", "", [], {"manifest": manifest}, True))
    for path in existing:
        if path.rsplit("/", 1)[-1] == "package.json" and "node_modules/" not in path:
            project = path.rsplit("/", 1)[0] if "/" in path else ""
            runner = discover.js_runner(root, project)
            if runner:
                suites.append(Suite(_suite_id(runner, project), runner, project, [], {}, True))
    return suites


def _is_workspace(root: Path, folder: str) -> bool:
    try:
        text = (Path(root) / folder / "Cargo.toml").read_text(encoding="utf-8", errors="replace")
    except OSError:
        return False
    return "[workspace]" in text
