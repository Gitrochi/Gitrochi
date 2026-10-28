#!/usr/bin/env python3
"""Run unittest test files and write a JUnit XML report, with one result per test.

`gitrochi-py test run` starts this file by path for projects without pytest. Standard library only;
it imports nothing from the gitrochi package so it works in any project's interpreter.
"""

import argparse
import importlib
import importlib.util
import os
import sys
import time
import traceback
import unittest
import xml.etree.ElementTree as ET


def module_name(rel_path):
    return rel_path[:-3].replace("\\", "/").replace("/", ".") if rel_path.endswith(".py") else rel_path


def load_module(path, root):
    """Import a test file under a stable dotted name taken from its path below the root."""
    rel = os.path.relpath(path, root).replace("\\", "/")
    name = module_name(rel)
    folder = os.path.dirname(os.path.abspath(path))
    packaged = True
    probe = folder
    root_abs = os.path.abspath(root)
    while os.path.normcase(probe) != os.path.normcase(root_abs) and probe.startswith(root_abs):
        if not os.path.isfile(os.path.join(probe, "__init__.py")):
            packaged = False
            break
        probe = os.path.dirname(probe)
    if packaged:
        return importlib.import_module(name), rel
    if folder not in sys.path:
        sys.path.insert(0, folder)
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module, rel


def flatten(suite):
    for item in suite:
        if isinstance(item, unittest.TestSuite):
            for test in flatten(item):
                yield test
        else:
            yield item


class Recorder(unittest.TestResult):
    def __init__(self, files, stream):
        super().__init__()
        self.files = files
        self.stream = stream
        self.records = []
        self._started = {}

    def startTest(self, test):
        self._started[test.id()] = time.monotonic()
        super().startTest(test)

    def _record(self, test, status, message=None):
        ident = test.id()
        seconds = time.monotonic() - self._started.get(ident, time.monotonic())
        classname, _, name = ident.rpartition(".")
        module = classname.rpartition(".")[0] if "." in classname else classname
        self.records.append({"classname": classname, "name": name or ident, "status": status, "time": seconds,
                             "message": message, "file": self.files.get(module) or self.files.get(classname)})
        mark = {"passed": "ok", "failed": "FAIL", "error": "ERROR", "skipped": "skipped"}[status]
        self.stream.write(f"{ident} ... {mark}\n")
        self.stream.flush()

    def addSuccess(self, test):
        super().addSuccess(test)
        self._record(test, "passed")

    def addFailure(self, test, err):
        super().addFailure(test, err)
        self._record(test, "failed", self._exc_info_to_string(err, test))

    def addError(self, test, err):
        super().addError(test, err)
        self._record(test, "error", self._exc_info_to_string(err, test))

    def addSkip(self, test, reason):
        super().addSkip(test, reason)
        self._record(test, "skipped", reason)

    def addExpectedFailure(self, test, err):
        super().addExpectedFailure(test, err)
        self._record(test, "passed")

    def addUnexpectedSuccess(self, test):
        super().addUnexpectedSuccess(test)
        self._record(test, "failed", "unexpected success")

    def addSubTest(self, test, subtest, err):
        super().addSubTest(test, subtest, err)
        if err is not None:
            status = "failed" if issubclass(err[0], test.failureException) else "error"
            self._record(subtest, status, self._exc_info_to_string(err, test))


def write_junit(records, path, seconds):
    failures = sum(1 for r in records if r["status"] == "failed")
    errors = sum(1 for r in records if r["status"] == "error")
    skipped = sum(1 for r in records if r["status"] == "skipped")
    suites = ET.Element("testsuites", tests=str(len(records)), failures=str(failures), errors=str(errors), time=f"{seconds:.3f}")
    suite = ET.SubElement(suites, "testsuite", name="unittest", tests=str(len(records)), failures=str(failures),
                          errors=str(errors), skipped=str(skipped), time=f"{seconds:.3f}")
    for r in records:
        attrs = {"classname": r["classname"], "name": r["name"], "time": f"{r['time']:.3f}"}
        if r.get("file"):
            attrs["file"] = r["file"]
        case = ET.SubElement(suite, "testcase", **attrs)
        if r["status"] in ("failed", "error"):
            text = r.get("message") or ""
            first = text.strip().splitlines()[-1] if text.strip() else r["status"]
            node = ET.SubElement(case, "failure" if r["status"] == "failed" else "error", message=first[:500])
            node.text = text
        elif r["status"] == "skipped":
            ET.SubElement(case, "skipped", message=(r.get("message") or "")[:500])
    folder = os.path.dirname(os.path.abspath(path))
    os.makedirs(folder, exist_ok=True)
    ET.ElementTree(suites).write(path, encoding="utf-8", xml_declaration=True)


def discover_files(root):
    found = []
    for folder, dirs, names in os.walk(root):
        dirs[:] = [d for d in dirs if not d.startswith(".") and d not in ("node_modules", "__pycache__", "venv", ".venv")]
        for name in names:
            if name.startswith("test") and name.endswith(".py"):
                found.append(os.path.relpath(os.path.join(folder, name), root))
    return sorted(found)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--junit", required=True, help="write the JUnit XML report here")
    parser.add_argument("--root", default=".", help="project folder that test module names are relative to")
    parser.add_argument("--only", action="append", default=[], help="run only this test id (repeatable)")
    parser.add_argument("--discover", action="store_true", help="find test*.py files below the root")
    parser.add_argument("files", nargs="*")
    args = parser.parse_args(argv)
    root = os.path.abspath(args.root)
    if root not in sys.path:
        sys.path.insert(0, root)
    files = list(args.files) or (discover_files(root) if args.discover else [])
    loader = unittest.TestLoader()
    suite = unittest.TestSuite()
    modules = {}
    broken = []
    for rel in files:
        path = os.path.join(root, rel)
        try:
            module, rel_path = load_module(path, root)
            modules[module.__name__] = rel_path
            suite.addTests(loader.loadTestsFromModule(module))
        except Exception:
            broken.append((rel, traceback.format_exc()))
    if args.only:
        wanted = set(args.only)
        suite = unittest.TestSuite([t for t in flatten(suite) if t.id() in wanted])
    recorder = Recorder(modules, sys.stdout)
    started = time.monotonic()
    suite.run(recorder)
    for rel, text in broken:
        name = module_name(rel.replace("\\", "/"))
        recorder.records.append({"classname": name, "name": "(import)", "status": "error", "time": 0.0, "message": text, "file": rel})
        sys.stdout.write(f"{name} ... ERROR (import failed)\n")
    write_junit(recorder.records, args.junit, time.monotonic() - started)
    bad = any(r["status"] in ("failed", "error") for r in recorder.records)
    return 1 if bad or not recorder.records else 0


if __name__ == "__main__":
    sys.exit(main())
