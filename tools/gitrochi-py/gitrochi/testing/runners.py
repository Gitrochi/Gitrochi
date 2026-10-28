"""Test suites: the command each runner needs, running it with a timeout, and reading its results.

Results come from machine-readable reports: JUnit XML (pytest, unittest via pyunit.py, vitest, swift),
`go test -json`, jest's --json file, and libtest's text lines for cargo (stable Rust has no JSON output).
"""

from __future__ import annotations

import json
import os
import re
import sys
import tempfile
import time
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence

from gitrochi import procs, redact

PYUNIT = str(Path(__file__).resolve().parent / "pyunit.py")
RUNNERS = ("pytest", "unittest", "go", "cargo", "jest", "vitest", "swift")
MAX_REPORT_BYTES = 50 * 1024 * 1024


@dataclass
class Suite:
    id: str
    runner: str
    cwd: str  # repository-relative folder ('' is the root)
    tests: List[str] = field(default_factory=list)  # repository-relative test files
    selectors: Dict[str, Any] = field(default_factory=dict)
    all: bool = False

    def to_dict(self) -> Dict[str, Any]:
        return {"id": self.id, "runner": self.runner, "cwd": self.cwd or ".", "tests": self.tests,
                "selectors": self.selectors, "all": self.all}

    @staticmethod
    def from_dict(data: Dict[str, Any]) -> "Suite":
        cwd = data.get("cwd") or ""
        return Suite(str(data["id"]), str(data["runner"]), "" if cwd == "." else str(cwd), list(data.get("tests") or []),
                     dict(data.get("selectors") or {}), bool(data.get("all")))


@dataclass
class Case:
    id: str
    name: str
    classname: str = ""
    file: Optional[str] = None
    status: str = "passed"  # passed | failed | error | skipped
    duration_ms: int = 0
    message: Optional[str] = None
    attempts: List[str] = field(default_factory=list)
    flaky: bool = False

    @property
    def bad(self) -> bool:
        return self.status in ("failed", "error")

    def to_dict(self) -> Dict[str, Any]:
        return {"id": self.id, "name": self.name, "classname": self.classname, "file": self.file, "status": self.status,
                "durationMs": self.duration_ms, "message": self.message, "attempts": self.attempts or [self.status],
                "flaky": self.flaky}


@dataclass
class SuiteResult:
    suite: Suite
    command: List[str]
    exit_code: Optional[int] = None
    timed_out: bool = False
    duration_ms: int = 0
    cases: List[Case] = field(default_factory=list)
    output_tail: str = ""
    error: Optional[str] = None
    reruns: int = 0

    def counts(self) -> Dict[str, int]:
        out = {"executed": 0, "passed": 0, "failed": 0, "skipped": 0, "flaky": 0}
        for c in self.cases:
            if c.status == "skipped":
                out["skipped"] += 1
                continue
            out["executed"] += 1
            if c.bad:
                out["failed"] += 1
            else:
                out["passed"] += 1
            if c.flaky:
                out["flaky"] += 1
        return out

    @property
    def ok(self) -> bool:
        counts = self.counts()
        if self.error or self.timed_out:
            return False
        if counts["failed"]:
            return False
        # Exit code 0 alone is not trusted, and a non-zero exit with no failing case is a harness failure.
        if self.exit_code not in (0, None) and counts["failed"] == 0 and not self.reruns:
            return False
        return counts["executed"] > 0

    def to_dict(self) -> Dict[str, Any]:
        return {"id": self.suite.id, "runner": self.suite.runner, "cwd": self.suite.cwd or ".", "command": self.command,
                "exitCode": self.exit_code, "timedOut": self.timed_out, "durationMs": self.duration_ms, "ok": self.ok,
                "counts": self.counts(), "reruns": self.reruns, "error": self.error,
                "cases": [c.to_dict() for c in self.cases], "outputTail": self.output_tail}


# ---------- commands ----------

def _rel(path: str, cwd: str) -> str:
    if cwd and path.startswith(cwd + "/"):
        return path[len(cwd) + 1:]
    return path


def command(suite: Suite, report: str, only: Optional[Sequence[Case]] = None, python: str = sys.executable) -> List[str]:
    """The argv for a suite (run in suite.cwd). `only` limits it to these cases (reruns)."""
    files = [_rel(t, suite.cwd) for t in suite.tests]
    runner = suite.runner
    if runner == "unittest":
        cmd = [python, PYUNIT, "--junit", report, "--root", "."]
        for case in only or []:
            # pyunit filters by unittest ids (module.Class.method); results use classname::name.
            cmd += ["--only", f"{case.classname}.{case.name}" if case.classname else case.name]
        return cmd + (files if files else ["--discover"])
    if runner == "pytest":
        cmd = [python, "-m", "pytest", "-q", "-p", "no:cacheprovider", f"--junitxml={report}", "-o", "junit_family=xunit1"]
        if only:
            return cmd + [_pytest_node(c, suite.cwd) for c in only]
        return cmd + files
    if runner == "go":
        packages = suite.selectors.get("packages") or ["./..."]
        names = sorted({c.name.split("/", 1)[0] for c in only}) if only else suite.selectors.get("tests") or []
        cmd = ["go", "test", "-json", "-count=1"]
        if names:
            cmd += ["-run", "^(" + "|".join(re.escape(n) for n in names) + ")$"]
        return cmd + list(packages)
    if runner == "cargo":
        cmd = ["cargo", "test"]
        if suite.selectors.get("manifest"):
            cmd += ["--manifest-path", suite.selectors["manifest"]]
        for target in suite.selectors.get("targets") or []:
            cmd += ["--test", target]
        if suite.selectors.get("lib"):
            cmd.append("--lib")
        cmd.append("--")
        if only:
            return cmd + ["--exact"] + [c.id for c in only]
        return cmd + list(suite.selectors.get("filters") or [])
    if runner == "jest":
        cmd = ["npx", "--no-install", "jest", "--ci", "--json", f"--outputFile={report}"]
        if only:
            names = [(c.classname + " " + c.name).strip() for c in only]
            cmd += ["--testNamePattern", "^(" + "|".join(re.escape(n) for n in names) + ")$"]
            paths = sorted({_rel(c.file, suite.cwd) for c in only if c.file}) or files
            return cmd + (["--runTestsByPath"] + paths if paths else [])
        return cmd + (["--runTestsByPath"] + files if files else [])
    if runner == "vitest":
        cmd = ["npx", "--no-install", "vitest", "run", "--reporter=junit", f"--outputFile={report}"]
        if only:
            cmd += ["--testNamePattern", "|".join(re.escape(c.name.split(" > ")[-1]) for c in only)]
        return cmd + files
    if runner == "swift":
        cmd = ["swift", "test", "--parallel", "--xunit-output", report]
        if only:
            cmd += ["--filter", "|".join(re.escape(c.classname.split(".")[-1] + "/" + c.name) for c in only)]
        elif suite.selectors.get("filter"):
            cmd += ["--filter", suite.selectors["filter"]]
        return cmd
    raise ValueError(f"unknown runner {runner}")


def _pytest_node(case: Case, cwd: str) -> str:
    """A pytest node id (path::Class::name) from a JUnit case written with junit_family=xunit1."""
    if not case.file:
        return case.id
    rel = _rel(case.file, cwd)
    module = rel[:-3].replace("/", ".") if rel.endswith(".py") else rel
    if case.classname == module:
        parts: List[str] = []
    elif case.classname.startswith(module + "."):
        parts = case.classname[len(module) + 1:].split(".")
    else:
        parts = [p for p in case.classname.split(".") if p[:1].isupper()]
    return "::".join([rel] + parts + [case.name])


# ---------- parsing ----------

def _ms(value: Any) -> int:
    try:
        return int(float(str(value).replace(",", "")) * 1000)
    except (TypeError, ValueError):
        return 0


def parse_junit(text: str, cwd: str = "") -> List[Case]:
    try:
        root = ET.fromstring(text)
    except ET.ParseError as exc:
        raise ValueError(f"not a JUnit report: {exc}")
    cases: List[Case] = []
    for tc in root.iter("testcase"):
        name = tc.get("name") or ""
        classname = tc.get("classname") or ""
        status = "passed"
        message = None
        for child in tc:
            tag = child.tag.split("}", 1)[-1]
            if tag in ("failure", "error"):
                status = "failed" if tag == "failure" else "error"
                body = (child.text or "").strip()
                message = (child.get("message") or "").strip()
                message = (message + "\n" + body).strip() if body and body != message else (message or body)
            elif tag == "skipped" and status == "passed":
                status = "skipped"
                message = child.get("message")
        file = tc.get("file")
        if file:
            file = file.replace("\\", "/")
            if cwd and not file.startswith(cwd + "/"):
                file = f"{cwd}/{file}"
        cases.append(Case(id=f"{classname}::{name}" if classname else name, name=name, classname=classname, file=file,
                          status=status, duration_ms=_ms(tc.get("time")), message=_short(message)))
    return cases


def _short(message: Optional[str], limit: int = 2000) -> Optional[str]:
    if not message:
        return None
    return redact.redact(message[:limit])


def parse_go_json(text: str, cwd: str = "") -> List[Case]:
    outputs: Dict[str, List[str]] = {}
    results: Dict[str, Case] = {}
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            event = json.loads(line)
        except ValueError:
            continue
        test = event.get("Test")
        package = event.get("Package") or ""
        if not test:
            if event.get("Action") == "fail" and package and not any(k.startswith(package + "::") for k in results):
                results[package + "::(package)"] = Case(id=package + "::(package)", name="(package)", classname=package, status="error",
                                                        message="package failed to build or run")
            continue
        key = f"{package}::{test}"
        action = event.get("Action")
        if action == "output":
            outputs.setdefault(key, []).append(event.get("Output") or "")
        elif action in ("pass", "fail", "skip"):
            status = {"pass": "passed", "fail": "failed", "skip": "skipped"}[action]
            results[key] = Case(id=key, name=test, classname=package, status=status, duration_ms=_ms(event.get("Elapsed")),
                                message=_short("".join(outputs.get(key, [])[-30:])) if status == "failed" else None)
    return list(results.values())


_CARGO_LINE = re.compile(r"^test (\S+) \.\.\. (ok|FAILED|ignored|failed)(?:, .*)?$")


def parse_cargo(text: str) -> List[Case]:
    cases: Dict[str, Case] = {}
    failures: Dict[str, List[str]] = {}
    current: Optional[str] = None
    for line in text.splitlines():
        match = _CARGO_LINE.match(line.strip())
        if match:
            name, outcome = match.group(1), match.group(2)
            status = {"ok": "passed", "ignored": "skipped"}.get(outcome, "failed")
            cases[name] = Case(id=name, name=name, classname=name.rsplit("::", 1)[0] if "::" in name else "", status=status)
            continue
        head = re.match(r"^---- (\S+) stdout ----$", line.strip())
        if head:
            current = head.group(1)
            failures[current] = []
            continue
        if current is not None:
            if line.startswith("failures:") or line.startswith("test result:"):
                current = None
            else:
                failures[current].append(line)
    for name, lines in failures.items():
        if name in cases and cases[name].bad:
            cases[name].message = _short("\n".join(lines).strip())
    return list(cases.values())


def parse_jest(doc: Dict[str, Any], cwd: str = "") -> List[Case]:
    cases: List[Case] = []
    for result in doc.get("testResults") or []:
        file = result.get("name") or result.get("testFilePath") or ""
        file = file.replace("\\", "/")
        for assertion in result.get("assertionResults") or []:
            status = {"passed": "passed", "failed": "failed", "pending": "skipped", "skipped": "skipped",
                      "todo": "skipped", "disabled": "skipped"}.get(assertion.get("status"), "failed")
            full = assertion.get("fullName") or assertion.get("title") or ""
            messages = assertion.get("failureMessages") or []
            cases.append(Case(id=f"{file}::{full}", name=assertion.get("title") or full,
                              classname=" ".join(assertion.get("ancestorTitles") or []), file=file or None, status=status,
                              duration_ms=int(assertion.get("duration") or 0),
                              message=_short("\n".join(messages)) if messages else None))
        if not result.get("assertionResults") and result.get("status") == "failed":
            cases.append(Case(id=f"{file}::(file)", name="(file)", file=file or None, status="error",
                              message=_short(result.get("message") or "test file failed to run")))
    return cases


def _relative_files(cases: List[Case], root: Path, cwd: str) -> None:
    base = (Path(root) / cwd).resolve() if cwd else Path(root).resolve()
    root_resolved = Path(root).resolve()
    for case in cases:
        if not case.file:
            continue
        path = Path(case.file)
        if not path.is_absolute():
            path = base / path
        try:
            case.file = path.resolve().relative_to(root_resolved).as_posix()
        except (ValueError, OSError):
            case.file = None


# ---------- running ----------

def _read_report(path: Path) -> Optional[str]:
    try:
        if path.stat().st_size > MAX_REPORT_BYTES:
            return None
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None


def execute(suite: Suite, root: Path, timeout: float, env: Optional[Dict[str, str]] = None, python: str = sys.executable,
            only: Optional[Sequence[Case]] = None) -> SuiteResult:
    workdir = tempfile.mkdtemp(prefix="gitrochi-test-")
    report = os.path.join(workdir, "report.json" if suite.runner == "jest" else "report.xml")
    cmd = command(suite, report, only, python)
    cwd = str(Path(root) / suite.cwd) if suite.cwd else str(root)
    if suite.runner in ("pytest", "unittest"):
        # Keep __pycache__ out of the worktree: it would change the tree key of the next run.
        env = dict(os.environ if env is None else env)
        env.setdefault("PYTHONDONTWRITEBYTECODE", "1")
    result = SuiteResult(suite, cmd)
    started = time.monotonic()
    run = procs.run_capture(cmd, cwd=cwd, env=env, timeout=timeout)
    result.duration_ms = int((time.monotonic() - started) * 1000)
    result.exit_code = run["exitCode"]
    result.timed_out = run["timedOut"]
    result.error = run["error"]
    output = run["output"] or ""
    result.output_tail = redact.redact(output[-4000:])
    try:
        if suite.runner in ("pytest", "unittest", "vitest", "swift"):
            text = _read_report(Path(report))
            if text:
                result.cases = parse_junit(text, "")
        elif suite.runner == "jest":
            text = _read_report(Path(report))
            if text:
                result.cases = parse_jest(json.loads(text))
        elif suite.runner == "go":
            result.cases = parse_go_json(output)
        elif suite.runner == "cargo":
            result.cases = parse_cargo(output)
    except (ValueError, TypeError) as exc:
        result.error = result.error or f"could not read the test report: {exc}"
    _relative_files(result.cases, root, suite.cwd)
    if result.timed_out:
        result.error = result.error or f"timed out after {int(timeout)}s"
    elif not result.cases and not result.error:
        result.error = "no test results were reported" + (f" (exit code {result.exit_code})" if result.exit_code else "")
    for case in result.cases:
        case.attempts = [case.status]
    _cleanup(workdir)
    return result


def _cleanup(folder: str) -> None:
    try:
        for name in os.listdir(folder):
            try:
                os.unlink(os.path.join(folder, name))
            except OSError:
                pass
        os.rmdir(folder)
    except OSError:
        pass


def rerun_failures(result: SuiteResult, root: Path, times: int, timeout: float, env: Optional[Dict[str, str]] = None,
                   python: str = sys.executable) -> None:
    """Run the failing cases again up to `times` times; a case that passes on a rerun is marked flaky."""
    for _ in range(max(0, times)):
        failing = [c for c in result.cases if c.bad and c.name not in ("(package)", "(file)")]
        if not failing:
            return
        again = execute(result.suite, root, timeout, env, python, only=failing)
        result.reruns += 1
        by_id = {c.id: c for c in again.cases}
        for case in failing:
            other = by_id.get(case.id)
            if other is None:
                continue
            case.attempts.append(other.status)
            if not other.bad and other.status != "skipped":
                case.status = "passed"
                case.flaky = True
                case.duration_ms = other.duration_ms
        if all(not c.bad for c in result.cases):
            result.exit_code = 0
