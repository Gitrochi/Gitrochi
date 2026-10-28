"""test plan / run / history / flaky: naming conventions, index and graph evidence, runners, reruns and delegation."""

import hashlib
import json
import os
import unittest

from testkit import DAY, NOW, Repo, Sandbox, build_index, run_cli, write_script

from gitrochi.testing import discover, runners
from gitrochi.testing.runners import Case, Suite

CALC = "def add(a, b):\n    return a + b\n"
TESTS = """import os
import unittest

from calc import add


class CalcTests(unittest.TestCase):
    def test_add(self):
        self.assertEqual(add(2, 3), 5)

    def test_flaky(self):
        marker = os.environ.get("FLAKY_MARKER")
        if marker and not os.path.exists(marker):
            open(marker, "w").close()
            self.fail("fails on the first attempt only")
"""


class NamingTests(unittest.TestCase):
    def test_conventions_across_languages(self):
        def best(source, tests):
            return {t: s for t, s, _ in discover.naming_matches(source, tests)}
        self.assertEqual(best("src/foo.ts", ["src/foo.test.ts", "src/bar.test.ts", "src/__tests__/foo.ts"]),
                         {"src/foo.test.ts": 0.95, "src/__tests__/foo.ts": 0.95})
        self.assertEqual(best("Sources/App/Foo.swift", ["Tests/AppTests/FooTests.swift"]), {"Tests/AppTests/FooTests.swift": 0.85})
        self.assertEqual(best("pkg/foo.py", ["tests/test_foo.py", "pkg/foo_test.py", "tests/test_bar.py"]),
                         {"tests/test_foo.py": 0.85, "pkg/foo_test.py": 0.95})
        self.assertEqual(best("cmd/x/foo.go", ["cmd/x/foo_test.go", "cmd/x/bar_test.go", "cmd/y/foo_test.go"]),
                         {"cmd/x/foo_test.go": 0.95, "cmd/x/bar_test.go": 0.6})
        self.assertEqual(best("src/foo.ts", ["src/foo.test.py"]), {}, "languages do not mix")
        self.assertTrue(discover.is_test_file("crates/a/tests/http.rs"))
        self.assertFalse(discover.is_test_file("crates/a/src/http.rs"))
        self.assertEqual(discover.rust_module_path("crates/a/src/net/http.rs", "crates/a"), "net::http")
        self.assertIsNone(discover.rust_module_path("crates/a/src/lib.rs", "crates/a"))


class CommandAndParserTests(unittest.TestCase):
    def test_commands(self):
        go = Suite("go:.", "go", "", ["pkg/a_test.go"], {"packages": ["./pkg"], "tests": ["TestA", "TestB"]})
        self.assertEqual(runners.command(go, "r"), ["go", "test", "-json", "-count=1", "-run", "^(TestA|TestB)$", "./pkg"])
        cargo = Suite("cargo", "cargo", "", [], {"manifest": "crates/a/Cargo.toml", "lib": True, "filters": ["net::http::"]})
        self.assertEqual(runners.command(cargo, "r"), ["cargo", "test", "--manifest-path", "crates/a/Cargo.toml", "--lib", "--", "net::http::"])
        rerun = runners.command(cargo, "r", only=[Case("net::http::tests::get", "net::http::tests::get")])
        self.assertEqual(rerun[-2:], ["--exact", "net::http::tests::get"])
        jest = Suite("jest:web", "jest", "web", ["web/src/a.test.ts"], {})
        self.assertEqual(runners.command(jest, "/tmp/r.json"),
                         ["npx", "--no-install", "jest", "--ci", "--json", "--outputFile=/tmp/r.json", "--runTestsByPath", "src/a.test.ts"])
        pytest = Suite("pytest:.", "pytest", "", ["tests/test_a.py"], {})
        node = runners.command(pytest, "r", only=[Case("tests.test_a.TestA::test_x", "test_x", "tests.test_a.TestA", "tests/test_a.py")])
        self.assertEqual(node[-1], "tests/test_a.py::TestA::test_x")
        swift = Suite("swift:.", "swift", "", ["Tests/AppTests/FooTests.swift"], {"filter": "FooTests"})
        self.assertEqual(runners.command(swift, "r")[-2:], ["--filter", "FooTests"])

    def test_parsers(self):
        go = "\n".join(json.dumps(e) for e in [
            {"Action": "run", "Package": "example.com/m/pkg", "Test": "TestA"},
            {"Action": "output", "Package": "example.com/m/pkg", "Test": "TestA", "Output": "a_test.go:9: boom\n"},
            {"Action": "fail", "Package": "example.com/m/pkg", "Test": "TestA", "Elapsed": 0.25},
            {"Action": "pass", "Package": "example.com/m/pkg", "Test": "TestB", "Elapsed": 0.01},
            {"Action": "skip", "Package": "example.com/m/pkg", "Test": "TestC"},
        ])
        cases = {c.name: c for c in runners.parse_go_json(go)}
        self.assertEqual((cases["TestA"].status, cases["TestA"].duration_ms), ("failed", 250))
        self.assertIn("boom", cases["TestA"].message)
        self.assertEqual((cases["TestB"].status, cases["TestC"].status), ("passed", "skipped"))
        cargo = ("running 3 tests\ntest net::tests::ok ... ok\ntest net::tests::bad ... FAILED\ntest net::tests::later ... ignored\n\n"
                 "failures:\n\n---- net::tests::bad stdout ----\nthread 'net::tests::bad' panicked at src/net.rs:9:5\n\nfailures:\n"
                 "    net::tests::bad\n\ntest result: FAILED. 1 passed; 1 failed; 1 ignored\n")
        cases = {c.id: c for c in runners.parse_cargo(cargo)}
        self.assertEqual([cases[k].status for k in ("net::tests::ok", "net::tests::bad", "net::tests::later")], ["passed", "failed", "skipped"])
        self.assertIn("panicked", cases["net::tests::bad"].message)
        jest = {"testResults": [{"name": "/repo/web/a.test.ts", "assertionResults": [
            {"title": "adds", "fullName": "math adds", "ancestorTitles": ["math"], "status": "passed", "duration": 3},
            {"title": "divides", "fullName": "math divides", "ancestorTitles": ["math"], "status": "failed", "failureMessages": ["Expected 2"]}]}]}
        cases = runners.parse_jest(jest)
        self.assertEqual([(c.name, c.status) for c in cases], [("adds", "passed"), ("divides", "failed")])
        junit = ('<testsuites><testsuite name="pytest"><testcase classname="tests.test_a" name="test_x" file="tests/test_a.py" time="0.5">'
                 '<failure message="assert 1 == 2">trace</failure></testcase><testcase classname="tests.test_a" name="test_y" time="0.1">'
                 '<skipped message="later"/></testcase></testsuite></testsuites>')
        cases = runners.parse_junit(junit)
        self.assertEqual([(c.id, c.status, c.file) for c in cases],
                         [("tests.test_a::test_x", "failed", "tests/test_a.py"), ("tests.test_a::test_y", "skipped", None)])
        self.assertEqual(cases[0].duration_ms, 500)


class PlanTests(unittest.TestCase):
    def setUp(self):
        self.sb = Sandbox()
        self.repo = Repo(self.sb.path("repo"))
        self.repo.write(".gitignore", "__pycache__/\n")
        self.repo.write("calc.py", CALC)
        self.repo.write("test_calc.py", TESTS)
        self.repo.write("tests/test_other.py", "import unittest\n")
        self.repo.write("tests/test_integration.py", "import unittest\n")
        self.repo.write("README.md", "# demo\n")
        self.repo.commit("Init", when=NOW - 30 * DAY)
        self.repo.git("checkout", "-q", "-b", "feature")
        build_index(self.repo.common_dir() / "gitrochi" / "index.sqlite3", [
            {"author": ("Dev A", "dev-a@example.com"), "time": NOW - (20 - i) * DAY,
             "files": [("calc.py", "M", 1, 1), ("tests/test_integration.py", "M", 2, 0)]} for i in range(3)])
        self.gitch = write_script(self.sb.path("bin", "gitch"), """
import json, sys
if sys.argv[1:4] != ["graph", "affected", "--base"] or "--json" not in sys.argv:
    sys.exit(2)
print(json.dumps({"schemaVersion": 1, "tool": "gitch graph", "stats": {"nodes": 3, "edges": 2, "heuristicEdges": 0,
    "affected": {"base": sys.argv[4], "changedFiles": ["calc.py"], "files": ["calc.py", "tests/test_other.py"], "modules": [],
                 "unresolvedFiles": [], "includesBaseDependencies": True}}, "nodes": [], "edges": []}))
""")

    def tearDown(self):
        self.sb.close()

    def _plan(self, *extra):
        code, out, err = run_cli("test", "plan", "--json", "--repo", self.repo.path, *extra)
        self.assertEqual(code, 0, err)
        return json.loads(out)

    def test_reasons_from_naming_index_and_graph(self):
        self.repo.write("calc.py", CALC + "\ndef sub(a, b):\n    return a - b\n")
        doc = self._plan("--gitch-bin", self.gitch)
        by_path = {c["path"]: c for c in doc["candidates"]}
        self.assertEqual({r["kind"] for r in by_path["test_calc.py"]["reasons"]}, {"naming"})
        self.assertEqual({r["kind"] for r in by_path["tests/test_integration.py"]["reasons"]}, {"cochange"})
        self.assertEqual({r["kind"] for r in by_path["tests/test_other.py"]["reasons"]}, {"graph"})
        self.assertEqual(doc["candidates"][0]["path"], "test_calc.py", "the strongest evidence ranks first")
        self.assertEqual(doc["sources"], {"naming": True, "index": "sqlite", "graph": "ok"})
        self.assertFalse(doc["runAll"])
        suite = doc["suites"][0]
        self.assertEqual(suite["runner"], "unittest")
        self.assertEqual(sorted(suite["tests"]), ["test_calc.py", "tests/test_integration.py", "tests/test_other.py"])
        self.assertIn("--junit", suite["command"])
        self.assertTrue(doc["range"]["includesWorktree"])

    def test_graph_unavailable_and_config_change_runs_everything(self):
        self.repo.write("pyproject.toml", "[project]\nname = 'demo'\n")
        doc = self._plan()
        self.assertEqual(doc["sources"]["graph"], "unavailable")
        self.assertTrue(doc["runAll"])
        self.assertIn("pyproject.toml", doc["runAllReason"])

    def test_head_ref_plans_that_commit(self):
        self.repo.write("calc.py", CALC + "\n# changed\n")
        self.repo.commit("Change calc")
        self.repo.git("checkout", "-q", "main")
        self.repo.write("README.md", "# uncommitted on main\n")
        doc = self._plan("--no-graph", "--head", "feature")
        self.assertEqual([c["path"] for c in doc["changed"]], ["calc.py"])
        self.assertFalse(doc["range"]["includesWorktree"])
        self.assertIn("test_calc.py", [c["path"] for c in doc["candidates"]])

    def test_docs_only_change_has_no_candidates(self):
        self.repo.write("README.md", "# demo\nmore\n")
        doc = self._plan("--no-graph")
        self.assertEqual(doc["candidates"], [])
        self.assertTrue(any("does not mean no tests are needed" in n for n in doc["notes"]))
        code, out, _ = run_cli("test", "run", "--json", "--repo", self.repo.path, "--no-graph")
        self.assertEqual((code, json.loads(out)["result"]), (0, "no-tests"))


class RunTests(unittest.TestCase):
    def setUp(self):
        self.sb = Sandbox()
        self.repo = Repo(self.sb.path("repo"))
        self.repo.write(".gitignore", "__pycache__/\n")
        self.repo.write("calc.py", CALC)
        self.repo.write("test_calc.py", TESTS)
        self.repo.commit("Init", when=NOW - DAY)
        self.history = self.sb.path("tests.sqlite3")
        os.environ["FLAKY_MARKER"] = str(self.sb.path("flaky-marker"))

    def tearDown(self):
        self.sb.close()

    def _run(self, *extra):
        code, out, err = run_cli("test", "run", "--json", "--repo", self.repo.path, "--history-db", self.history, *extra)
        self.assertNotIn("Traceback", err)
        return code, json.loads(out)

    def test_rerun_marks_flaky_and_history_flags_it(self):
        code, doc = self._run("--all", "--rerun-failures", "2")
        self.assertEqual(code, 0, doc)
        self.assertEqual(doc["result"], "flaky")
        self.assertEqual(doc["flaky"], ["test_calc.CalcTests::test_flaky"])
        suite = doc["suites"][0]
        flaky_case = [c for c in suite["cases"] if c["name"] == "test_flaky"][0]
        self.assertEqual(flaky_case["attempts"], ["failed", "passed"])
        self.assertEqual(suite["counts"], {"executed": 2, "passed": 2, "failed": 0, "skipped": 0, "flaky": 1})
        code, out, _ = run_cli("test", "flaky", "--json", "--repo", self.repo.path, "--history-db", self.history, "--fail")
        found = json.loads(out)["tests"]
        self.assertEqual(code, 1, "--fail exits 1 when a flaky test is found")
        self.assertEqual([(f["test"], f["sameTreeConflicts"]) for f in found], [("test_calc.CalcTests::test_flaky", 1)])

    def test_failure_without_rerun_then_pass_on_same_tree_is_flaky(self):
        code, doc = self._run("--all")
        self.assertEqual((code, doc["result"]), (1, "failed"))
        self.assertEqual([f["id"] for f in doc["failures"]], ["test_calc.CalcTests::test_flaky"])
        code, doc = self._run("--all")
        self.assertEqual((code, doc["result"]), (0, "passed"))
        self.assertEqual(doc["treeKey"], doc["treeKey"])
        code, out, _ = run_cli("test", "flaky", "--json", "--repo", self.repo.path, "--history-db", self.history)
        tests = json.loads(out)["tests"]
        self.assertEqual(tests[0]["test"], "test_calc.CalcTests::test_flaky")
        self.assertEqual(tests[0]["reason"], "passed and failed on the same tree")
        code, out, _ = run_cli("test", "history", "--json", "--repo", self.repo.path, "--history-db", self.history)
        runs = json.loads(out)["runs"]
        self.assertEqual([r["counts"]["failed"] for r in runs], [0, 1])
        self.assertEqual(runs[0]["treeKey"], runs[1]["treeKey"], "both runs saw the same tree")
        code, out, _ = run_cli("test", "slow", "--json", "--repo", self.repo.path, "--history-db", self.history)
        self.assertEqual(json.loads(out)["command"], "test slow")
        code, out, _ = run_cli("test", "trends", "--json", "--repo", self.repo.path, "--history-db", self.history)
        weeks = json.loads(out)["weeks"]
        self.assertEqual(weeks[-1]["runs"], 2)
        self.assertEqual(weeks[-1]["failedRuns"], 1)

    def test_steady_failure_is_not_flaky_and_fails(self):
        self.repo.write("test_broken.py", "import unittest\n\nclass Broken(unittest.TestCase):\n"
                                          "    def test_always_fails(self):\n        self.assertEqual(1, 2)\n")
        self.repo.commit("Broken test")
        open(os.environ["FLAKY_MARKER"], "w").close()
        code, doc = self._run("--all", "--rerun-failures", "1")
        self.assertEqual(code, 1)
        self.assertEqual(doc["flaky"], [])
        broken = [c for s in doc["suites"] for c in s["cases"] if c["name"] == "test_always_fails"][0]
        self.assertEqual(broken["attempts"], ["failed", "failed"])
        self.assertIn("AssertionError", broken["message"])

    def test_plan_mode_runs_only_matching_tests_and_timeouts_fail(self):
        self.repo.write("slow_test_helper.py", "")
        self.repo.write("test_slow.py", "import time, unittest\n\nclass Slow(unittest.TestCase):\n"
                                        "    def test_sleeps(self):\n        time.sleep(30)\n")
        self.repo.commit("Slow test")
        self.repo.git("checkout", "-q", "-b", "feature")
        self.repo.write("calc.py", CALC + "\n")
        open(os.environ["FLAKY_MARKER"], "w").close()
        code, doc = self._run("--no-graph", "--base", "main")
        self.assertEqual(code, 0, doc)
        self.assertEqual(doc["mode"], "plan")
        self.assertEqual(doc["suites"][0]["counts"]["executed"], 2, "only test_calc.py ran")
        code, doc = self._run("--all", "--timeout", "2")
        self.assertEqual(code, 1)
        slow = [s for s in doc["suites"] if s["timedOut"]]
        self.assertTrue(slow, "the suite with the sleeping test timed out")

    def test_dry_run_and_bad_plan_file(self):
        code, doc = self._run("--all", "--dry-run")
        self.assertEqual(code, 0)
        self.assertTrue(doc["dryRun"])
        self.assertEqual(doc["suites"][0]["runner"], "unittest")
        bad = self.sb.path("plan.json")
        bad.write_text(json.dumps({"suites": [{"id": "x", "runner": "rm-rf", "cwd": "."}]}), encoding="utf-8")
        code, out, _ = run_cli("test", "run", "--json", "--repo", self.repo.path, "--plan", bad)
        self.assertEqual(code, 2)


class FlowDelegationTests(unittest.TestCase):
    def setUp(self):
        self.sb = Sandbox()
        self.repo = Repo(self.sb.path("repo"))
        self.repo.write(".gitch/flow.yml", "version: 1\nsuites:\n  unit: { use: test.pytest }\n")
        self.repo.write("app.py", "x = 1\n")
        self.repo.commit("Init")
        self.calls = self.sb.path("flow-args.json")
        self.history = self.sb.path("tests.sqlite3")

    def tearDown(self):
        self.sb.close()

    def _engine(self, exit_code=1, stderr_error=None):
        summary = {"schemaVersion": 1, "runId": "20261028T000000-abc123", "flow": "test", "env": "local", "state": "FAILED",
                   "startedAt": "2026-10-28T00:00:00Z", "git": {"sha": "0" * 40, "branch": "main", "clean": True}, "exitCode": exit_code,
                   "nodes": [{"id": "unit", "suite": "unit", "block": "test.pytest", "state": "FAILED", "durationMs": 1200, "attempts": 1,
                              "tests": {"executed": 3, "passed": 2, "failed": 1, "skipped": 0, "flaky": 0},
                              "failures": [{"id": "tests/test_x.py::test_bad", "name": "test_bad", "file": "tests/test_x.py", "line": 3,
                                            "status": "failed", "durationMs": 5, "message": "assert 1 == 2"}],
                              "report": "reports/unit.json", "failure": {"code": "TEST-01", "detail": "1 of 3 tests failed"}}]}
        body = f"open({str(self.calls)!r}, 'w').write(json.dumps(sys.argv[1:]))\n"
        if stderr_error:
            body += f"sys.stderr.write(json.dumps({stderr_error!r}))\nsys.exit(2)\n"
        else:
            body += f"print(json.dumps({summary!r}, indent=2))\nsys.exit({exit_code})\n"
        return write_script(self.sb.path("bin", "gitch-flow"), "import json, sys\n" + body)

    def test_delegates_records_and_reads_the_full_report(self):
        engine = self._engine()
        worktree_id = hashlib.sha256(str(self.repo.path.resolve()).encode("utf-8")).hexdigest()[:12]
        report = self.repo.common_dir() / "gitch" / "flow" / "runs" / worktree_id / "20261028T000000-abc123" / "reports" / "unit.json"
        report.parent.mkdir(parents=True)
        report.write_text(json.dumps({"cases": [
            {"id": "tests/test_x.py::test_ok1", "name": "test_ok1", "file": "tests/test_x.py", "status": "passed", "durationMs": 3},
            {"id": "tests/test_x.py::test_ok2", "name": "test_ok2", "file": "tests/test_x.py", "status": "passed", "durationMs": 4},
            {"id": "tests/test_x.py::test_bad", "name": "test_bad", "file": "tests/test_x.py", "status": "failed", "durationMs": 5,
             "message": "assert 1 == 2"}]}), encoding="utf-8")
        code, out, err = run_cli("test", "run", "--json", "--repo", self.repo.path, "--flow-bin", engine, "--history-db", self.history)
        doc = json.loads(out)
        self.assertEqual(code, 1, err)
        self.assertEqual((doc["mode"], doc["source"]), ("flow", "gitch-flow"))
        self.assertEqual(json.loads(self.calls.read_text()), ["test", "--json", "--affected"])
        self.assertEqual(doc["counts"]["executed"], 3)
        self.assertEqual(len(doc["suites"][0]["cases"]), 3, "cases come from the run's report file")
        self.assertEqual(doc["flowRun"]["state"], "FAILED")
        code, out, _ = run_cli("test", "history", "--json", "--repo", self.repo.path, "--history-db", self.history)
        self.assertEqual(json.loads(out)["runs"][0]["source"], "gitch-flow")
        code, out, _ = run_cli("test", "run", "--json", "--all", "--repo", self.repo.path, "--flow-bin", engine, "--no-history")
        self.assertEqual(json.loads(self.calls.read_text()), ["test", "--json"])

    def test_untrusted_flow_needs_a_person(self):
        engine = self._engine(stderr_error={"schemaVersion": 1, "error": {"code": "GITCH_CONFIRMATION_REQUIRED", "flowCode": "TRUST-01",
                                                                          "message": "the flow file is not trusted"}})
        code, out, _ = run_cli("test", "run", "--json", "--repo", self.repo.path, "--flow-bin", engine, "--no-history")
        doc = json.loads(out)
        self.assertEqual(code, 1)
        self.assertEqual(doc["error"]["code"], "TRUST-01")
        self.assertIn("gitch flow trust", doc["error"]["message"])

    def test_no_flow_uses_builtin_runners(self):
        engine = self._engine()
        code, out, _ = run_cli("test", "run", "--json", "--repo", self.repo.path, "--flow-bin", engine, "--no-flow", "--all", "--no-history")
        self.assertFalse(self.calls.exists())
        self.assertEqual(json.loads(out)["error"]["code"], "NO_TESTS")


if __name__ == "__main__":
    unittest.main()
