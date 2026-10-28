"""review: diff collection and parsing, chunking, line mapping and the deterministic local checks."""

import json
import unittest

from testkit import DAY, NOW, Repo, Sandbox, build_index, run_cli, write_script

from gitrochi.review import checks, diff, prompts
from gitrochi.review.findings import FileIndex, extract_json, validate


def _patch(text):
    return diff.parse_patch(text)


class ParsePatchTests(unittest.TestCase):
    def test_hunk_counts_keep_sql_comment_lines_as_content(self):
        files = _patch(
            "diff --git a/q.sql b/q.sql\nindex 1..2 100644\n--- a/q.sql\n+++ b/q.sql\n"
            "@@ -1,3 +1,3 @@\n select 1;\n--- old comment\n+-- new comment\n end;\n")
        self.assertEqual(len(files), 1)
        lines = [(ln.kind, ln.old, ln.new, ln.text) for ln in files[0].hunks[0].lines]
        self.assertEqual(lines, [(" ", 1, 1, "select 1;"), ("-", 2, None, "-- old comment"), ("+", None, 2, "-- new comment"),
                                 (" ", 3, 3, "end;")])
        self.assertEqual((files[0].additions, files[0].deletions), (1, 1))

    def test_quoted_renamed_binary_and_deleted_paths(self):
        files = _patch(
            "diff --git \"a/sp\\303\\251c.txt\" \"b/sp\\303\\251c.txt\"\nnew file mode 100644\n--- /dev/null\n"
            "+++ \"b/sp\\303\\251c.txt\"\n@@ -0,0 +1 @@\n+hi\n"
            "diff --git a/old name.txt b/new name.txt\nsimilarity index 90%\nrename from old name.txt\nrename to new name.txt\n"
            "diff --git a/logo.png b/logo.png\ndeleted file mode 100644\nBinary files a/logo.png and /dev/null differ\n")
        self.assertEqual([(f.path, f.status) for f in files], [("spéc.txt", "A"), ("new name.txt", "R"), ("logo.png", "D")])
        self.assertEqual(files[1].old_path, "old name.txt")
        self.assertEqual(files[1].similarity, 90)
        self.assertTrue(files[2].binary)


class CollectTests(unittest.TestCase):
    def setUp(self):
        self.sb = Sandbox()
        self.repo = Repo(self.sb.path("repo"))
        self.repo.write("app.py", "def add(a, b):\n    return a + b\n")
        self.repo.commit("Add app", when=NOW - 10 * DAY)

    def tearDown(self):
        self.sb.close()

    def test_default_range_is_merge_base_with_default_branch(self):
        self.repo.git("checkout", "-q", "-b", "feature")
        self.repo.write("app.py", "def add(a, b):\n    return a + b + 0\n")
        self.repo.commit("Change app")
        self.repo.write("app.py", "uncommitted\n")
        changes = diff.collect(self.repo.path)
        self.assertEqual(changes.mode, "range")
        self.assertEqual(changes.base_ref, "main")
        self.assertEqual([f.path for f in changes.files], ["app.py"])
        self.assertIn("return a + b + 0", changes.files[0].added_lines()[0].text)

    def test_staged_and_worktree_with_untracked(self):
        self.repo.write("app.py", "def add(a, b):\n    return b + a\n")
        self.repo.git("add", "app.py")
        self.repo.write("notes.py", "x = 1\n")
        staged = diff.collect(self.repo.path, staged=True)
        self.assertEqual([f.path for f in staged.files], ["app.py"])
        worktree = diff.collect(self.repo.path, worktree=True)
        self.assertEqual(sorted(f.path for f in worktree.files), ["app.py", "notes.py"])
        added = [f for f in worktree.files if f.path == "notes.py"][0]
        self.assertEqual((added.status, added.added_lines()[0].new), ("A", 1))
        without = diff.collect(self.repo.path, worktree=True, include_untracked=False)
        self.assertEqual([f.path for f in without.files], ["app.py"])

    def test_bad_ref_is_a_failure_and_option_like_ref_a_usage_error(self):
        code, out, _ = run_cli("review", "--no-ai", "--json", "--repo", self.repo.path, "--base", "no-such-branch")
        self.assertEqual(code, 1)
        self.assertEqual(json.loads(out)["error"]["code"], "UNKNOWN_REF")
        code, out, _ = run_cli("review", "--no-ai", "--json", "--repo", self.repo.path, "--base=--output=x")
        self.assertEqual(code, 2)
        self.assertEqual(json.loads(out)["error"]["code"], "USAGE")


class ChunkAndLineTests(unittest.TestCase):
    def _file(self, path, n, start=1):
        body = "".join(f"+line {i} of {path}\n" for i in range(n))
        return _patch(f"diff --git a/{path} b/{path}\nnew file mode 100644\n--- /dev/null\n+++ b/{path}\n@@ -0,0 +{start},{n} @@\n{body}")[0]

    def test_budget_splits_skips_and_reports(self):
        files = [self._file("src/a.py", 40), self._file("src/b.py", 40), self._file("docs/c.md", 40), self._file("yarn.lock", 5)]
        chunks, skipped = prompts.plan(files, max_chunk=2000, max_total=3500)
        reasons = {s["path"]: s["reason"] for s in skipped}
        self.assertEqual(reasons["yarn.lock"], "lock file")
        self.assertIn("budget", reasons["docs/c.md"])  # docs come last and fall out of the budget first
        self.assertTrue(all(c.size <= 2000 + 64 for c in chunks))
        self.assertEqual(chunks[0].paths[0], "src/a.py")

    def test_oversized_hunk_is_truncated_with_a_note(self):
        big = self._file("src/big.py", 400)
        parts = prompts.file_parts(big, 3000)
        self.assertTrue(parts[0].truncated)
        self.assertIn("hunk truncated", parts[0].text)

    def test_model_lines_map_to_the_new_side(self):
        f = _patch("diff --git a/m.py b/m.py\n--- a/m.py\n+++ b/m.py\n@@ -10,3 +10,4 @@ def f\n a\n+b\n c\n d\n")[0]
        index = FileIndex([f])
        findings, dropped = validate({"findings": [
            {"file": "b/m.py", "line": 11, "severity": "high", "message": "exact"},
            {"file": "m.py", "line": "L95", "severity": "nit", "message": "far away, moved to the changed line"},
            {"file": "other.py", "line": 1, "message": "not in the change"},
            {"file": "m.py", "message": ""},
        ]}, index)
        self.assertEqual(dropped, 2)
        self.assertEqual([(x.line, x.severity, x.line_adjusted) for x in findings], [(11, "error", False), (11, "info", True)])

    def test_json_repair(self):
        self.assertEqual(extract_json("Here:\n```json\n{\"findings\": []}\n```")[0], {"findings": []})
        value, repaired = extract_json('{"findings": [{"file": "a", "message": "x",},]}')
        self.assertTrue(repaired)
        self.assertEqual(value["findings"][0]["message"], "x")
        cut = '{"findings": [{"file": "a.py", "line": 1, "message": "one"}, {"file": "a.py", "line": 2, "mess'
        value, repaired = extract_json(cut)
        self.assertTrue(repaired)
        self.assertEqual([f["message"] for f in value["findings"]], ["one"])
        with self.assertRaises(ValueError):
            extract_json("no json here")


class LocalCheckTests(unittest.TestCase):
    def setUp(self):
        self.sb = Sandbox()
        self.repo = Repo(self.sb.path("repo"))
        self.repo.write("src/auth.py", "def login(user):\n    return user\n")
        self.repo.write("src/token.py", "TTL = 60\n")
        self.repo.write("src/unrelated.py", "X = 1\n")
        self.repo.write("tests/test_auth.py", "import unittest\n")
        self.repo.commit("Add auth", when=NOW - 30 * DAY)
        self.repo.git("checkout", "-q", "-b", "feature")
        self.db = self.repo.common_dir() / "gitrochi" / "index.sqlite3"
        history = []
        for i in range(4):
            history.append({"author": ("Dev A", "a@example.com"), "time": NOW - (100 - i) * DAY,
                            "files": [("src/auth.py", "M", 3, 1), ("src/token.py", "M", 1, 1)]})
        history.append({"author": ("Dev B", "b@example.com"), "time": NOW - 50 * DAY, "files": [("src/unrelated.py", "M", 1, 0)]})
        build_index(self.db, history)

    def tearDown(self):
        self.sb.close()

    def _review(self, *extra):
        code, out, err = run_cli("review", "--no-ai", "--json", "--repo", self.repo.path, *extra)
        self.assertNotIn("Traceback", err)
        return code, json.loads(out)

    def test_missing_cochange_partner_is_reported(self):
        self.repo.write("src/auth.py", "def login(user):\n    return user.strip()\n")
        self.repo.commit("Change auth only")
        code, doc = self._review("--fail-on", "warning")
        partners = [f for f in doc["findings"] if f["rule"] == "cochange-missing"]
        self.assertEqual(len(partners), 1, doc["findings"])
        self.assertEqual(partners[0]["details"]["partner"], "src/token.py")
        self.assertEqual(partners[0]["file"], "src/auth.py")
        self.assertEqual(doc["index"]["source"], "sqlite")
        self.assertEqual(code, 1, "a warning must fail with --fail-on warning")

    def test_partner_in_the_change_is_not_reported(self):
        self.repo.write("src/auth.py", "def login(user):\n    return user.strip()\n")
        self.repo.write("src/token.py", "TTL = 120\n")
        self.repo.commit("Change both")
        code, doc = self._review()
        self.assertFalse([f for f in doc["findings"] if f["rule"] == "cochange-missing"])
        self.assertEqual(code, 0)

    def test_no_index_degrades_gracefully(self):
        self.db.unlink()
        self.repo.write("src/auth.py", "def login(user):\n    return user.strip()\n")
        self.repo.commit("Change auth only")
        code, doc = self._review()
        self.assertEqual(code, 0)
        self.assertEqual(doc["index"]["source"], "none")
        self.assertTrue(any("no index database" in n for n in doc["notes"]))

    def test_fake_index_binary_is_used_for_impact(self):
        calls = self.sb.path("calls.jsonl")
        fake = write_script(self.sb.path("bin", "gitrochi-index"), f"""
import json, sys
args = sys.argv[1:]
open({str(calls)!r}, "a").write(json.dumps(args) + "\\n")
cmd = [a for a in args if not a.startswith("--")]
if "impact" in args:
    print(json.dumps({{"changed": ["src/auth.py"], "suggestions": [{{"path": "src/session.py", "score": 0.9,
        "because": [{{"path": "src/auth.py", "commits": 9, "confidence": 0.9}}]}}]}}))
elif "file" in args:
    print(json.dumps({{"path": "src/auth.py", "stats": {{"commits": 9, "additions": 1, "deletions": 1, "firstTime": 1, "lastTime": 2}},
        "authors": [], "coupled": [], "history": []}}))
else:
    print(json.dumps({{"error": {{"code": "INVALID_ARGUMENT", "message": "unexpected"}}}})); sys.exit(1)
""")
        self.repo.write("src/auth.py", "def login(user):\n    return user.strip()\n")
        self.repo.commit("Change auth only")
        code, doc = self._review("--index-bin", fake)
        self.assertEqual(doc["index"]["source"], "binary")
        partners = [f["details"]["partner"] for f in doc["findings"] if f["rule"] == "cochange-missing"]
        self.assertEqual(partners, ["src/session.py"])
        recorded = [json.loads(line) for line in calls.read_text().splitlines()]
        impact = [a for a in recorded if "impact" in a][0]
        self.assertEqual(impact[:2], ["--repo", str(self.repo.path)])
        self.assertIn("src/auth.py", impact)

    def test_added_line_checks(self):
        self.repo.write("src/auth.py", "def login(user):\n    # TODO: rate limit\n    breakpoint()\n"
                                       "    api_key = \"sk-ant-api03-" + "x7Kq" * 6 + "\"\n<<<<<<< HEAD\n    return user\n")
        self.repo.write("web/app.ts", "export function f() {\n  console.log('x');\n  debugger;\n}\n")
        self.repo.remove("tests/test_auth.py")
        self.repo.commit("Risky change")
        code, doc = self._review()
        rules = {(f["rule"], f["file"], f["line"]) for f in doc["findings"]}
        self.assertIn(("todo-added", "src/auth.py", 2), rules)
        self.assertIn(("debug-statement", "src/auth.py", 3), rules)
        self.assertIn(("secret-added", "src/auth.py", 4), rules)
        self.assertIn(("conflict-marker", "src/auth.py", 5), rules)
        self.assertIn(("test-deleted", "tests/test_auth.py", None), rules)
        self.assertIn(("debug-statement", "web/app.ts", 3), rules)
        self.assertEqual(code, 1)
        self.assertNotIn("x7Kqx7Kq", json.dumps(doc), "the secret itself must not be echoed")

    def test_lock_file_only_and_size(self):
        self.repo.write("package-lock.json", "{}\n")
        self.repo.commit("Add lock")
        self.repo.git("checkout", "-q", "-b", "deps")
        self.repo.write("package-lock.json", "{\"lockfileVersion\": 3}\n")
        self.repo.commit("Bump lock")
        code, doc = self._review("--base", "feature")
        self.assertEqual([f["rule"] for f in doc["findings"]], ["lockfile-only"])
        files = [diff.FileDiff(path=f"f{i}.py") for i in range(70)]
        size = checks.run(files, None)
        self.assertTrue(any(f.rule == "large-diff" for f in size))

    def test_markdown_and_sarif_formats(self):
        self.repo.write("src/auth.py", "def login(user):\n    breakpoint()\n    return user\n")
        self.repo.commit("Debug")
        code, out, _ = run_cli("review", "--no-ai", "--format", "markdown", "--repo", self.repo.path)
        self.assertIn("## Gitrochi review", out)
        self.assertIn("| warning | `src/auth.py:2` |", out)
        code, out, _ = run_cli("review", "--no-ai", "--format", "sarif", "--repo", self.repo.path, "--fail-on", "never")
        self.assertEqual(code, 0)
        sarif = json.loads(out)
        self.assertEqual(sarif["version"], "2.1.0")
        run = sarif["runs"][0]
        self.assertEqual(run["tool"]["driver"]["name"], "gitrochi-review")
        rule_ids = [r["id"] for r in run["tool"]["driver"]["rules"]]
        for result in run["results"]:
            self.assertIn(result["level"], ("error", "warning", "note"))
            self.assertEqual(rule_ids[result["ruleIndex"]], result["ruleId"])
            location = result["locations"][0]["physicalLocation"]
            self.assertFalse(location["artifactLocation"]["uri"].startswith("/"))
            self.assertGreaterEqual(location["region"]["startLine"], 1)
            self.assertTrue(result["partialFingerprints"])


if __name__ == "__main__":
    unittest.main()
