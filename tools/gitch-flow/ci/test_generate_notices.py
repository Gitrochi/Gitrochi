import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("generate_notices", Path(__file__).with_name("generate-notices.py"))
NOTICES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(NOTICES)


class NoticeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.metadata = {
            "packages": [],
            "resolve": {"root": "flow", "nodes": []},
        }
        self.package("flow", [])

    def package(self, name, dependencies, files=None):
        directory = self.directory / name
        directory.mkdir()
        for relative, content in (files or {}).items():
            path = directory / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
        self.metadata["packages"].append({
            "id": name, "name": name, "version": "1.2.3", "authors": ["Example Authors"],
            "license": "MIT", "source": "registry+https://github.com/rust-lang/crates.io-index",
            "manifest_path": str(directory / "Cargo.toml"),
        })
        self.metadata["resolve"]["nodes"].append({
            "id": name, "deps": [{"pkg": target, "dep_kinds": [{"kind": kind, "target": platform}]} for target, kind, platform in dependencies],
        })

    def use(self, *edges):
        self.metadata["resolve"]["nodes"][0]["deps"] = [
            {"pkg": name, "dep_kinds": [{"kind": kind, "target": target}]}
            for name, kind, target in edges
        ]

    def test_all_platform_normal_and_build_edges_without_dev(self):
        self.package("linux", [("nested", None, None)], {"LICENSE": b"Linux license"})
        self.package("windows", [], {"LICENSE": b"Windows license"})
        self.package("builder", [], {"COPYING": b"Build license"})
        self.package("nested", [], {"NOTICE": b"Nested notice"})
        self.package("dev", [], {})
        self.use(("linux", None, "cfg(unix)"), ("windows", None, "cfg(windows)"), ("builder", "build", None), ("dev", "dev", None))
        _, packages = NOTICES.dependencies(self.metadata)
        self.assertEqual([package["name"] for package in packages], ["builder", "linux", "nested", "windows"])
        self.assertIn(b"Coverage: 4 dependency packages", NOTICES.render(self.metadata, []))

    def test_nested_files_deduplication_and_stable_order(self):
        self.package("a", [], {"LICENSE": b"Shared license\n", "third-party/COPYRIGHT.txt": b"Nested attribution\n"})
        self.package("b", [], {"LICENSE-MIT": b"Shared license\n"})
        self.use(("b", None, None), ("a", None, None))
        content = NOTICES.render(self.metadata, [])
        self.assertEqual(content.count(b"Shared license\n"), 1)
        self.assertIn(b"third-party/COPYRIGHT.txt", content)
        self.assertIn(b"Nested attribution", content)
        reordered = copy.deepcopy(self.metadata)
        reordered["packages"].reverse()
        reordered["resolve"]["nodes"].reverse()
        self.assertEqual(content, NOTICES.render(reordered, []))

    def test_missing_notice_fails(self):
        self.package("missing", [], {})
        self.use(("missing", None, None))
        with self.assertRaisesRegex(ValueError, "No upstream license/notice"):
            NOTICES.render(self.metadata, [])

    def test_line_endings_are_portable(self):
        self.package("a", [], {"LICENSE": b"Copyright Example\r\nPermission\r\n"})
        self.use(("a", None, None))
        content = NOTICES.render(self.metadata, [])
        self.assertNotIn(b"\r", content)
        self.assertIn(b"Copyright Example\nPermission\n", content)

    def test_style_normalization_preserves_words_and_original_hash(self):
        original = b"Copyright Example Authors  \r\nPermission to copy.\t\r\n\r\n"
        self.package("a", [], {"LICENSE": original})
        self.metadata["packages"][-1]["authors"] = []
        self.use(("a", None, None))
        content = NOTICES.render(self.metadata, [])
        self.assertIn(b"Authors: not provided\n", content)
        self.assertIn(b"Copyright Example Authors\nPermission to copy.\n", content)
        self.assertIn(hashlib.sha256(original).hexdigest().encode(), content)
        self.assertNotIn(b"\r", content)
        self.assertTrue(content.endswith(b"\n"))
        self.assertFalse(content.endswith(b"\n\n"))
        self.assertTrue(all(line == line.rstrip(b" \t") for line in content.split(b"\n")))

    def test_supplement_does_not_mask_changed_license(self):
        self.package("a", [], {})
        self.use(("a", None, None))
        with self.assertRaisesRegex(ValueError, "Changed supplemental license expression"):
            NOTICES.render(self.metadata, [{"package": "a", "version": "1.2.3", "declared_license": "Apache-2.0"}])

    def test_changed_supplement_bytes_fail(self):
        self.package("a", [], {})
        self.use(("a", None, None))
        path = self.directory / "license.txt"
        path.write_text("changed license")
        supplement = {"package": "a", "version": "1.2.3", "declared_license": "MIT", "path": str(path), "sha256": "0" * 64}
        with self.assertRaisesRegex(ValueError, "Changed supplemental license text"):
            NOTICES.render(self.metadata, [supplement])

    def test_check_rejects_missing_and_changed_bundle(self):
        self.package("a", [], {"LICENSE": b"Example license\n"})
        self.use(("a", None, None))
        ci = self.directory / "ci"
        ci.mkdir()
        script = ci / "generate-notices.py"
        script.write_bytes(Path(NOTICES.__file__).read_bytes())
        (ci / "supplemental-notices.json").write_text("[]")
        # A synthetic cargo command returns only the fixture graph; no registry or user settings are accessed.
        cargo = self.directory / "cargo"
        cargo.write_text("#!/usr/bin/env python3\nimport sys\nsys.stdout.write(" + repr(json.dumps(self.metadata)) + ")\n")
        cargo.chmod(0o755)
        environment = dict(os.environ, PATH=str(self.directory) + os.pathsep + os.environ["PATH"])
        def run(*arguments):
            return subprocess.run([sys.executable, str(script), *arguments], env=environment, capture_output=True)
        self.assertNotEqual(run("--check").returncode, 0)
        self.assertEqual(run().returncode, 0)
        self.assertEqual(run("--check").returncode, 0)
        (self.directory / "THIRD_PARTY_NOTICES.txt").write_text("outdated")
        self.assertNotEqual(run("--check").returncode, 0)


if __name__ == "__main__":
    unittest.main()
