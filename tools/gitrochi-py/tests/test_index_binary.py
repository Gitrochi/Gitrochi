"""Integration with the real `gitrochi-index` executable, when crates/gitrochi-index has been built.

The database is a temporary file passed with --db, so nothing is written into a repository's .git folder.
"""

import json
import os
import unittest

import testkit
from testkit import DAY, NOW, Repo, Sandbox, run_cli

from gitrochi.index import Index

REAL = testkit.REPO_ROOT / "crates" / "target" / "release" / ("gitrochi-index.exe" if os.name == "nt" else "gitrochi-index")


@unittest.skipUnless(REAL.is_file() and os.access(str(REAL), os.X_OK), "crates/gitrochi-index is not built (cargo build --release)")
class RealIndexTests(unittest.TestCase):
    def setUp(self):
        self.sb = Sandbox()
        self.repo = Repo(self.sb.path("repo"))
        for i in range(4):
            self.repo.author("Dev A" if i % 2 else "Dev B", "dev-a@example.com" if i % 2 else "dev-b@example.com")
            self.repo.write("src/auth.py", "".join(f"step_{n} = {n}\n" for n in range(i + 1)))
            self.repo.write("src/token.py", "".join(f"ttl_{n} = {n}\n" for n in range(i + 1)))
            self.repo.write("tests/test_auth.py", "import unittest\n" + "".join(f"# case {n}\n" for n in range(i + 1)))
            self.repo.commit(f"Auth change {i}", when=NOW - (40 - i) * DAY)
        self.repo.git("checkout", "-q", "-b", "feature")
        self.repo.write("src/auth.py", "step_0 = 0\nstep_new = 1\n")
        self.repo.commit("Change auth alone", when=NOW - DAY)
        self.db = self.sb.path("index.sqlite3")
        self.index = Index(self.repo.path, binary=str(REAL), db=str(self.db))
        synced = self.index.sync()
        self.assertEqual(synced["totalCommits"], 5)

    def tearDown(self):
        self.index.close()
        self.sb.close()

    def test_review_uses_the_binary_and_reports_the_missing_partner(self):
        code, out, err = run_cli("review", "--no-ai", "--json", "--repo", self.repo.path, "--index-bin", REAL, "--index-db", self.db)
        self.assertNotIn("Traceback", err)
        doc = json.loads(out)
        self.assertEqual(doc["index"]["source"], "binary")
        partners = sorted(f["details"]["partner"] for f in doc["findings"] if f["rule"] == "cochange-missing")
        self.assertEqual(partners, ["src/token.py", "tests/test_auth.py"])
        self.assertFalse((self.repo.common_dir() / "gitrochi").exists(), "--db keeps the repository's .git untouched")

    def test_analyze_reads_the_rust_database(self):
        code, out, err = run_cli("analyze", "--json", "--repo", self.repo.path, "--index-db", self.db, "--now", NOW)
        self.assertEqual(code, 0, err)
        doc = json.loads(out)
        self.assertEqual(doc["index"]["commits"], 5)
        self.assertIn("src/auth.py", [h["path"] for h in doc["hotspots"]])
        files = doc["coupling"]["clusters"][0]["files"]
        self.assertEqual(files, ["src/auth.py", "src/token.py", "tests/test_auth.py"])
        self.assertEqual(sorted(a["email"] for a in doc["ownership"][0]["authors"]), ["dev-a@example.com", "dev-b@example.com"])

    def test_plan_finds_the_cochanged_test_through_the_binary(self):
        code, out, err = run_cli("test", "plan", "--json", "--repo", self.repo.path, "--index-bin", REAL, "--index-db", self.db, "--no-graph")
        self.assertEqual(code, 0, err)
        doc = json.loads(out)
        candidate = [c for c in doc["candidates"] if c["path"] == "tests/test_auth.py"][0]
        kinds = {r["kind"] for r in candidate["reasons"]}
        self.assertIn("cochange", kinds)
        self.assertIn("naming", kinds)
        self.assertEqual(doc["sources"]["index"], "binary")


if __name__ == "__main__":
    unittest.main()
