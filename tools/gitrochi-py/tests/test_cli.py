"""The command line contract: exit codes 0/1/2, JSON errors, help, and the launcher script."""

import json
import os
import subprocess
import sys
import unittest

import testkit
from testkit import Repo, Sandbox, run_cli

from gitrochi import redact


class CliTests(unittest.TestCase):
    def setUp(self):
        self.sb = Sandbox()

    def tearDown(self):
        self.sb.close()

    def test_help_and_usage_exit_codes(self):
        code, out, _ = run_cli("--help")
        self.assertEqual(code, 0)
        self.assertIn("review", out)
        self.assertEqual(run_cli()[0], 2)
        code, out, _ = run_cli("review", "--json", "--no-such-flag")
        self.assertEqual(code, 2)
        doc = json.loads(out)
        self.assertEqual((doc["schemaVersion"], doc["error"]["code"]), (1, "USAGE"))
        code, out, _ = run_cli("test", "--json")
        self.assertEqual(code, 2)
        self.assertEqual(run_cli("runtime", "deploy", "svc")[0], 2, "--version is required")

    def test_failures_are_json_with_exit_1(self):
        code, out, _ = run_cli("review", "--json", "--no-ai", "--repo", self.sb.dir)
        self.assertEqual(code, 1)
        self.assertEqual(json.loads(out)["error"]["code"], "NOT_A_REPOSITORY")
        code, _, err = run_cli("analyze", "--repo", self.sb.dir)
        self.assertEqual(code, 1)
        self.assertIn("not a git repository", err)

    def test_error_messages_are_redacted(self):
        repo = Repo(self.sb.path("repo"))
        repo.write("a.txt", "x\n")
        repo.commit("Init")
        token = "ghp_" + "Z9y8" * 9
        code, out, _ = run_cli("review", "--json", "--no-ai", "--repo", repo.path, "--base", token)
        self.assertEqual(code, 1)
        self.assertNotIn(token, out)
        self.assertIn("[REDACTED:github-token]", out)

    def test_launcher_and_module_entry_point(self):
        launcher = testkit.PACKAGE_DIR / "gitrochi-py"
        env = dict(os.environ)
        proc = subprocess.run([sys.executable, str(launcher), "--version"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn(b"gitrochi-py", proc.stdout)
        env["PYTHONPATH"] = str(testkit.PACKAGE_DIR)
        proc = subprocess.run([sys.executable, "-m", "gitrochi", "runtime", "status", "--json", "--manifest", str(self.sb.path("none.json"))],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, cwd=str(self.sb.dir))
        self.assertEqual(proc.returncode, 1)
        self.assertEqual(json.loads(proc.stdout)["error"]["code"], "MANIFEST")

    def test_redaction_patterns(self):
        # Secret-shaped fixtures are assembled at run time so the repository's secret check passes.
        text = ("key sk-ant-api03-" + "a" * 30 + " url https://bot:s3cr3tpass@example.com/x jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0."
                "c2lnbmF0dXJlLXRlc3Q sha 0123456789abcdef0123456789abcdef01234567 " + "-----BEGIN " + "PRIVATE KEY-----\nMIIB\n-----END PRIVATE KEY-----")
        masked = redact.redact(text)
        for secret in ("sk-ant-api03-", "s3cr3tpass", "eyJhbGciOiJIUzI1NiJ9", "MIIB"):
            self.assertNotIn(secret, masked)
        self.assertIn("0123456789abcdef0123456789abcdef01234567", masked, "commit SHAs are not secrets")
        self.assertEqual(redact.mask("echo the-key-123456 back", ["the-key-123456"]), "echo [REDACTED:known-secret] back")


if __name__ == "__main__":
    unittest.main()
