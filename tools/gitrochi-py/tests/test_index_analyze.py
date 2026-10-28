"""The index reader (read-only, schema check, SQL shapes) and `analyze` over fixture databases."""

import json
import sqlite3
import unittest

from testkit import DAY, NOW, Repo, Sandbox, build_index, run_cli, write_script

from gitrochi import index as indexmod
from gitrochi.util import Failure

A = ("Dev A", "dev-a@example.com")
B = ("Dev B", "dev-b@example.com")
C = ("Dev C", "dev-c@example.com")


def history():
    """A small history: core/ is busy and coupled, legacy/ was written by an author who left, one huge commit."""
    commits = []
    for week in range(20):
        when = NOW - (140 - week * 7) * DAY
        commits.append({"author": A if week % 3 else B, "time": when, "subject": f"Tune engine {week}",
                        "files": [("core/engine.py", "M", 10, 4), ("core/engine_config.py", "M", 2, 1)]})
    for i in range(6):
        commits.append({"author": C, "time": NOW - (400 + i) * DAY, "subject": f"Legacy {i}", "files": [("legacy/old.py", "M", 5, 5)]})
    commits.append({"author": A, "time": NOW - 300 * DAY, "subject": "Touch legacy once", "files": [("legacy/old.py", "M", 1, 0)]})
    commits.append({"author": B, "time": NOW - 10 * DAY, "subject": "Vendor everything",
                    "files": [(f"vendor/lib{i}.py", "A", 900, 0) for i in range(40)]})
    commits.append({"author": A, "time": NOW - 5 * DAY, "subject": "Docs", "files": [("README.md", "M", 3, 1)]})
    commits.append({"author": B, "time": NOW - 3 * DAY, "subject": "Rename <b>tag</b>", "files": [("web/<img src=x>.html", "A", 4, 0)]})
    return commits


class IndexReaderTests(unittest.TestCase):
    def setUp(self):
        self.sb = Sandbox()
        self.db = build_index(self.sb.path("index.sqlite3"), history())

    def tearDown(self):
        self.sb.close()

    def test_readonly_and_schema_check(self):
        conn = indexmod.open_readonly(self.db)
        with self.assertRaises(sqlite3.OperationalError):
            conn.execute("DELETE FROM commits")
        conn.close()
        raw = sqlite3.connect(str(self.db))
        raw.execute("PRAGMA user_version = 7")
        raw.commit()
        raw.close()
        with self.assertRaises(Failure) as ctx:
            indexmod.open_readonly(self.db)
        self.assertEqual(ctx.exception.code, "SCHEMA_MISMATCH")
        with self.assertRaises(Failure) as ctx:
            indexmod.open_readonly(self.sb.path("missing.sqlite3"))
        self.assertEqual(ctx.exception.code, "INDEX_MISSING")

    def test_sql_shapes_use_coupling_commits(self):
        idx = indexmod.Index(None, db=str(self.db), use_binary=False)
        coupled = idx.coupled("core/engine.py", min_commits=2)
        self.assertEqual(coupled["commits"], 20)
        partner = coupled["partners"][0]
        self.assertEqual((partner["path"], partner["commits"], partner["confidence"], partner["jaccard"]), ("core/engine_config.py", 20, 1.0, 1.0))
        impact = idx.impact(["core/engine.py"])
        self.assertEqual([s["path"] for s in impact["suggestions"]], ["core/engine_config.py"])
        self.assertEqual(impact["suggestions"][0]["because"][0]["path"], "core/engine.py")
        info = idx.file_info("legacy/old.py")
        self.assertEqual(info["stats"]["commits"], 7)
        self.assertEqual([c["subject"] for c in info["history"][:2]], ["Touch legacy once", "Legacy 0"], "newest first")
        self.assertEqual(info["authors"][0]["email"], C[1])
        owners = idx.owners("core/")
        self.assertEqual(owners["commits"], 20)
        self.assertEqual(owners["busFactor"], 1)
        self.assertEqual(idx.source, "sqlite")
        idx.close()

    def test_history_orders_equal_times_by_seq(self):
        db = build_index(self.sb.path("ties.sqlite3"), [
            {"author": A, "time": NOW, "subject": "child", "files": [("a.py", "M", 1, 0)]},
            {"author": A, "time": NOW, "subject": "parent", "files": [("a.py", "M", 1, 0)]}])
        raw = sqlite3.connect(str(db))
        raw.execute("UPDATE commits SET seq = CASE subject WHEN 'child' THEN 9 ELSE 3 END")
        raw.commit()
        raw.close()
        idx = indexmod.Index(None, db=str(db), use_binary=False)
        self.assertEqual([c["subject"] for c in idx.file_info("a.py")["history"]], ["child", "parent"])
        idx.close()

    def test_vendor_commit_does_not_couple(self):
        idx = indexmod.Index(None, db=str(self.db), use_binary=False)
        self.assertEqual(idx.coupled("vendor/lib1.py", min_commits=1)["partners"], [], "commits over max_files are left out")
        idx.close()

    def test_binary_discovery_order(self):
        fake = write_script(self.sb.path("bin", "gitrochi-index"), "print('{}')\n")
        self.assertEqual(indexmod.find_binary(str(fake)), (str(fake), "--index-bin"))
        self.assertEqual(indexmod.find_binary(None)[0], None, "GITROCHI_INDEX_BIN points nowhere in the sandbox")
        self.assertEqual(indexmod.find_binary(str(self.sb.path("nope")))[0], None)

    def test_gitrochi_index_0_turns_the_index_off(self):
        import os
        repo = Repo(self.sb.path("repo"))
        repo.write("core/engine.py", "x = 1\n")
        repo.commit("Engine", when=NOW - 2 * DAY)
        repo.git("checkout", "-q", "-b", "feature")
        repo.write("core/engine.py", "x = 2\n")
        repo.commit("Engine 2", when=NOW - DAY)
        build_index(repo.common_dir() / "gitrochi" / "index.sqlite3", history())
        os.environ["GITROCHI_INDEX"] = "0"
        code, out, _ = run_cli("review", "--no-ai", "--json", "--repo", repo.path)
        doc = json.loads(out)
        self.assertEqual(doc["index"]["source"], "disabled")
        self.assertFalse([f for f in doc["findings"] if f["rule"] == "cochange-missing"])
        self.assertTrue(any("GITROCHI_INDEX=0" in n for n in doc["notes"]))
        code, out, _ = run_cli("analyze", "--json", "--repo", repo.path)
        self.assertEqual((code, json.loads(out)["error"]["code"]), (1, "INDEX_DISABLED"))
        code, out, _ = run_cli("analyze", "--json", "--repo", repo.path, "--index-db", self.db, "--now", NOW)
        self.assertEqual(code, 0, "an explicit --index-db wins over the switch")
        os.environ.pop("GITROCHI_INDEX")
        code, out, _ = run_cli("review", "--no-ai", "--json", "--repo", repo.path)
        self.assertTrue([f for f in json.loads(out)["findings"] if f["rule"] == "cochange-missing"])

    def test_binary_errors_become_notes(self):
        fake = write_script(self.sb.path("bin", "gitrochi-index"),
                            "import json, sys\nprint(json.dumps({'error': {'code': 'NOT_INDEXED', 'message': 'run sync'}}))\nsys.exit(1)\n")
        idx = indexmod.Index(None, binary=str(fake), db=str(self.db))
        info = idx.file_info("core/engine.py")
        self.assertEqual(info["stats"]["commits"], 20, "falls back to the database")
        self.assertTrue(any("run sync" in n for n in idx.notes))
        with self.assertRaises(Failure) as ctx:
            idx.run("status")
        self.assertEqual(ctx.exception.code, "NOT_INDEXED")
        idx.close()


class AnalyzeTests(unittest.TestCase):
    def setUp(self):
        self.sb = Sandbox()
        self.db = build_index(self.sb.path("index.sqlite3"), history())

    def tearDown(self):
        self.sb.close()

    def _analyze(self, *extra):
        code, out, err = run_cli("analyze", "--index-db", self.db, "--repo", self.sb.dir, "--now", NOW, *extra)
        self.assertNotIn("Traceback", err)
        return code, out

    def test_json_sections(self):
        code, out = self._analyze("--json", "--top", "5")
        self.assertEqual(code, 0)
        doc = json.loads(out)
        self.assertEqual(doc["index"]["commits"], len(history()))
        self.assertEqual(doc["hotspots"][0]["path"], "core/engine.py", "busy and recent beats big but old")
        self.assertGreater(doc["hotspots"][0]["score"], doc["hotspots"][-1]["score"])
        cluster = doc["coupling"]["clusters"][0]
        self.assertEqual(cluster["files"], ["core/engine.py", "core/engine_config.py"])
        core = [d for d in doc["ownership"] if d["directory"] == "core"][0]
        self.assertEqual(core["busFactor"], 1)
        self.assertEqual(core["authors"][0]["email"], A[1])
        risky = [f["path"] for f in doc["knowledgeLoss"]["files"]]
        self.assertEqual(risky, ["legacy/old.py"], "the main author has been inactive for over 180 days")
        self.assertEqual(doc["knowledgeLoss"]["files"][0]["mainAuthor"]["email"], C[1])
        weeks = doc["trends"]["weeks"]
        self.assertEqual(len(weeks), 26)
        self.assertEqual(sum(w["commits"] for w in weeks), 23, "20 engine commits, vendor, docs and web; legacy is older")
        outliers = [c["subject"] for c in doc["outliers"]["commits"]]
        self.assertIn("Vendor everything", outliers)

    def test_since_prefix_and_only(self):
        code, out = self._analyze("--json", "--since", "30d", "--prefix", "core/", "--only", "hotspots,coupling")
        doc = json.loads(out)
        self.assertEqual(doc["sections"], ["hotspots", "coupling"])
        self.assertNotIn("trends", doc)
        self.assertTrue(all(h["path"].startswith("core/") for h in doc["hotspots"]))
        self.assertTrue(all(h["lastTime"] >= NOW - 30 * DAY for h in doc["hotspots"]))
        code, out = self._analyze("--json", "--only", "nonsense")
        self.assertEqual(code, 2)

    def test_html_is_offline_and_escaped(self):
        out_file = self.sb.path("report.html")
        code, _ = self._analyze("--format", "html", "--out", out_file, "--prefix", "web/")
        self.assertEqual(code, 0)
        page = out_file.read_text(encoding="utf-8")
        self.assertIn('http-equiv="Content-Security-Policy"', page)
        self.assertIn("default-src 'none'", page)
        self.assertNotIn("<script", page)
        self.assertNotIn("<img src=x>", page, "paths are escaped")
        self.assertIn("&lt;img src=x&gt;", page)
        for marker in ("http://", "https://", "src=\"", "href=\""):
            self.assertNotIn(marker, page.replace("&lt;img src=x&gt;", ""))

    def test_text_and_markdown(self):
        code, out = self._analyze()
        self.assertIn("Hotspots", out)
        self.assertIn("core/engine.py", out)
        code, out = self._analyze("--format", "markdown")
        self.assertIn("## Ownership and bus factor", out)
        self.assertIn("| Path |", out)

    def test_missing_database_fails_cleanly(self):
        code, out, _ = run_cli("analyze", "--json", "--index-db", self.sb.path("none.sqlite3"), "--repo", self.sb.dir)
        self.assertEqual(code, 1)
        self.assertEqual(json.loads(out)["error"]["code"], "INDEX_MISSING")

    def test_repository_default_database_and_deleted_files(self):
        repo = Repo(self.sb.path("repo"))
        repo.write("core/engine.py", "x = 1\n")
        repo.commit("Engine")
        build_index(repo.common_dir() / "gitrochi" / "index.sqlite3", history())
        code, out, _ = run_cli("analyze", "--json", "--repo", repo.path, "--now", NOW, "--only", "hotspots")
        doc = json.loads(out)
        self.assertEqual([h["path"] for h in doc["hotspots"]], ["core/engine.py"], "files missing from HEAD are left out")
        code, out, _ = run_cli("analyze", "--json", "--repo", repo.path, "--now", NOW, "--only", "hotspots", "--include-deleted")
        self.assertGreater(len(json.loads(out)["hotspots"]), 1)


if __name__ == "__main__":
    unittest.main()
