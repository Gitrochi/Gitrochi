#!/usr/bin/env python3
"""Black-box protocol and source correctness checks for the SCIP reader."""

import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from scip_fixtures import blob, encode, fixture, number
from helper_test_support import bash_executable, write_utf8


HELPER = Path(__file__).resolve().parents[1] / "gitch-scip-index"


class ScipImportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        self.index = fixture(self.repo)
        self.tracked = self.repo / "tracked.z"
        self.tracked.write_bytes(b"\0".join(doc["relative_path"].encode() for doc in self.index["documents"]) + b"\0")
        self.index_file = self.repo / "index.scip"

    def call(self, index=None, *, json_format=False, unpacked=False, args=(), raw=None):
        index = self.index if index is None else index
        if raw is None:
            raw = json.dumps(index).encode() if json_format else encode(index, unpacked=unpacked)
        self.index_file.write_bytes(raw)
        result = subprocess.run([sys.executable, str(HELPER), "--repo", str(self.repo), "--index", str(self.index_file), "--tracked", str(self.tracked), *args],
                                text=True, encoding="utf-8", stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(result.stderr, "", result.stderr)
        if "records" in args:
            return result.returncode, result.stdout
        return result.returncode, json.loads(result.stdout)

    def test_binary_class_and_function_references_three_languages(self):
        rc, result = self.call()
        self.assertEqual(rc, 0)
        self.assertEqual(result["schemaVersion"], 1)
        self.assertEqual(result["producer"]["name"], "fixture-indexer")
        edges = {(e["source"], e["target"]): e for e in result["edges"]}
        self.assertEqual(set(edges), {("ts/client.ts", "ts/engine.ts"), ("python/client.py", "python/engine.py"), ("java/Client.java", "java/Engine.java")})
        self.assertEqual(edges["ts/client.ts", "ts/engine.ts"]["weight"], 4)
        self.assertEqual(edges["python/client.py", "python/engine.py"]["weight"], 4)
        self.assertEqual(edges["java/Client.java", "java/Engine.java"]["weight"], 2)
        for edge in edges.values():
            self.assertEqual(edge["confidence"], "indexed")
            self.assertEqual(edge["kind"], "reference")
            self.assertEqual(len(edge["via"]), 2)
            for evidence in edge["evidence"]:
                self.assertEqual(evidence["method"], "scip")
                self.assertEqual(evidence["targetFile"], edge["target"])
                self.assertGreaterEqual(evidence["line"], 1)
                self.assertGreaterEqual(evidence["targetLine"], 1)
        self.assertEqual(result["diagnostics"], [])

    def test_binary_unpacked_ranges_equal_packed(self):
        _, packed = self.call()
        _, unpacked = self.call(unpacked=True)
        self.assertEqual(packed, unpacked)

    def test_json_snake_and_camel_case_match_binary(self):
        _, binary = self.call()
        _, snake = self.call(json_format=True)
        self.assertEqual(binary, snake)
        encoded = json.dumps(self.index)
        for before, after in (("relative_path", "relativePath"), ("project_root", "projectRoot"), ("tool_info", "toolInfo"), ("position_encoding", "positionEncoding"), ("symbol_roles", "symbolRoles")):
            encoded = encoded.replace('"' + before + '"', '"' + after + '"')
        _, camel = self.call(raw=encoded.encode())
        self.assertEqual(binary, camel)

    def test_typed_single_line_range_overrides_deprecated_range(self):
        occurrence = self.index["documents"][1]["occurrences"][0]
        line, start, end = occurrence["range"]
        occurrence["range"] = [9999, 9999, 9999]
        occurrence["single_line_range"] = {"line": line, "start_character": start, "end_character": end}
        rc, result = self.call()
        self.assertEqual(rc, 0)
        self.assertEqual(result["stats"]["references"], 10)
        self.assertFalse(any(d["code"] == "scip-occurrence-range" for d in result["diagnostics"]))
        _, result_json = self.call(json_format=True)
        self.assertEqual(result, result_json)

    def test_typed_multi_line_and_legacy_multi_line(self):
        occurrence = self.index["documents"][1]["occurrences"][0]
        occurrence["multi_line_range"] = {"start_line": 0, "start_character": 9, "end_line": 1, "end_character": 5}
        _, result = self.call()
        evidence = next(e for edge in result["edges"] if edge["source"] == "ts/client.ts" for e in edge["evidence"] if e["line"] == 1 and e["column"] == 10)
        self.assertEqual(evidence["endLine"], 2)
        self.assertEqual(evidence["endColumn"], 6)
        del occurrence["multi_line_range"]
        occurrence["range"] = [0, 9, 1, 5]
        _, legacy = self.call()
        self.assertEqual(result, legacy)

    def test_utf16_positions_accept_surrogate_pair_offsets(self):
        path = self.repo / "ts/client.ts"
        text = "'😀'; Engine;\n"
        write_utf8(path, text)
        doc = self.index["documents"][1]
        doc["text"] = text
        doc["position_encoding"] = 2
        doc["occurrences"] = [{"symbol": doc["occurrences"][0]["symbol"], "range": [0, 6, 12]}]
        _, result = self.call()
        evidence = next(edge for edge in result["edges"] if edge["source"] == "ts/client.ts")["evidence"][0]
        self.assertEqual(evidence["column"], 7)
        self.assertEqual(evidence["positionEncoding"], 2)

    def test_local_symbols_duplicates_and_self_references_do_not_invent_edges(self):
        doc = self.index["documents"][1]
        doc["occurrences"].append(copy.deepcopy(doc["occurrences"][0]))
        doc["occurrences"].extend([{"symbol": "local 123", "range": [0, 9, 15], "symbol_roles": role} for role in (0, 1)])
        _, result = self.call()
        self.assertEqual(result["stats"]["references"], 10)
        self.assertEqual(result["stats"]["edges"], 3)

    def test_crlf_source_and_embedded_text_keep_positions_and_freshness(self):
        for document in self.index["documents"]:
            document["text"] = document["text"].replace("\n", "\r\n")
            write_utf8(self.repo / document["relative_path"], document["text"])
        rc, result = self.call()
        self.assertEqual(rc, 0)
        self.assertEqual(result["stats"]["references"], 10)
        self.assertEqual(result["diagnostics"], [])
        self.assertTrue(all(item["freshness"] == "content" for edge in result["edges"] for item in edge["evidence"]))

    def test_external_and_unknown_symbols_are_diagnosed(self):
        doc = self.index["documents"][1]
        doc["occurrences"].extend([{"symbol": symbol, "range": [0, 9, 15]} for symbol in ("scip npm external 1 External#", "scip npm absent 1 Absent#")])
        self.index["external_symbols"] = [{"symbol": "scip npm external 1 External#"}]
        _, result = self.call()
        self.assertEqual(result["stats"]["externalReferences"], 1)
        self.assertEqual(result["stats"]["unresolvedReferences"], 1)
        self.assertEqual({d["code"] for d in result["diagnostics"]}, {"scip-external-symbol", "scip-unresolved-symbol"})
        self.assertEqual(result["stats"]["edges"], 3)

    def test_ambiguous_definitions_are_never_arbitrarily_selected(self):
        self.index["documents"][2]["occurrences"][0]["symbol"] = self.index["documents"][0]["occurrences"][0]["symbol"]
        _, result = self.call()
        ts = next(edge for edge in result["edges"] if edge["source"] == "ts/client.ts")
        self.assertEqual(ts["weight"], 2)
        self.assertTrue(all("make" in item["symbol"] for item in ts["evidence"]))
        self.assertTrue(any(d["code"] == "scip-ambiguous-symbol" for d in result["diagnostics"]))

    def test_forward_definition_is_not_used_as_a_concrete_definition(self):
        self.index["documents"][2]["occurrences"][0]["symbol"] = self.index["documents"][0]["occurrences"][0]["symbol"]
        self.index["documents"][2]["occurrences"][0]["symbol_roles"] = 65
        _, result = self.call()
        self.assertEqual(result["stats"]["references"], 10)
        self.assertFalse(any(d["code"] == "scip-ambiguous-symbol" for d in result["diagnostics"]))

    def test_stale_embedded_source_is_excluded_both_as_source_and_target(self):
        (self.repo / "ts/engine.ts").write_text("export const replaced = 1;\n")
        _, result = self.call()
        self.assertNotIn("ts/engine.ts", result["covered"])
        self.assertFalse(any(e["source"] == "ts/engine.ts" or e["target"] == "ts/engine.ts" for e in result["edges"]))
        self.assertTrue(any(d["code"] == "scip-stale-document" for d in result["diagnostics"]))

    def test_newer_source_without_embedded_text_is_excluded(self):
        for doc in self.index["documents"]:
            doc.pop("text")
        self.index_file.write_bytes(encode(self.index))
        newer = self.index_file.stat().st_mtime_ns + 2_000_000_000
        os.utime(self.repo / "ts/client.ts", ns=(newer, newer))
        # The test runner rewrites the index, so preserve an explicit old timestamp.
        raw = self.index_file.read_bytes()
        rc, result = self.call(raw=raw)
        self.assertEqual(rc, 0)
        self.assertNotIn("ts/client.ts", result["covered"])
        self.assertTrue(any(d["code"] == "scip-stale-document" and d["file"] == "ts/client.ts" for d in result["diagnostics"]))

    def test_copied_index_with_different_root_is_rejected(self):
        self.index["metadata"]["project_root"] = self.repo.parent.as_uri()
        rc, result = self.call()
        self.assertEqual(rc, 3)
        self.assertEqual(result["covered"], [])
        self.assertEqual(result["edges"], [])
        self.assertEqual(result["diagnostics"][0]["code"], "scip-project-root")

    def test_nested_project_root_is_repo_relative(self):
        # ts/ is indexed independently, but public graph ids remain repo-relative.
        self.index["metadata"]["project_root"] = (self.repo / "ts").as_uri()
        self.index["documents"] = [doc for doc in self.index["documents"] if doc["relative_path"].startswith("ts/")]
        for doc in self.index["documents"]:
            doc["relative_path"] = doc["relative_path"][3:]
        _, result = self.call()
        self.assertEqual([(e["source"], e["target"]) for e in result["edges"]], [("ts/client.ts", "ts/engine.ts")])

    def test_outside_absolute_and_noncanonical_document_paths_are_rejected(self):
        for path in ("../evil.ts", "/etc/passwd", "C:/evil.ts", "ts/./evil.ts", "ts//evil.ts", "ts/evil\t.ts", "ts\\evil.ts"):
            self.index["documents"].append({"relative_path": path, "language": "TypeScript"})
        _, result = self.call()
        self.assertEqual(result["stats"]["diagnosticCounts"]["scip-document-path"], 7)
        self.assertEqual(result["stats"]["references"], 10)

    def test_untracked_definitions_do_not_become_edges(self):
        self.tracked.write_bytes(self.tracked.read_bytes().replace(b"ts/engine.ts\0", b""))
        _, result = self.call()
        self.assertNotIn("ts/engine.ts", result["covered"])
        self.assertFalse(any(e["source"].startswith("ts/") for e in result["edges"]))
        self.assertTrue(any(d["code"] == "scip-untracked-document" for d in result["diagnostics"]))

    def test_symlink_document_is_rejected(self):
        original = self.repo / "ts/engine.ts"
        original.rename(self.repo / "ts/real.ts")
        try:
            original.symlink_to("real.ts")
        except OSError as exc:
            self.skipTest("symbolic link creation is unavailable: " + str(exc))
        _, result = self.call()
        self.assertNotIn("ts/engine.ts", result["covered"])
        self.assertTrue(any(d["code"] == "scip-document-symlink" for d in result["diagnostics"]))

    def test_scope_and_language_filter_sources_but_keep_outside_target(self):
        rc, result = self.call(args=("--scope", "ts", "--lang", "ts"))
        self.assertEqual(rc, 0)
        self.assertEqual(len(result["edges"]), 1)
        self.assertEqual(result["covered"], ["ts/client.ts", "ts/engine.ts", "ts/unrelated.ts"])
        rc, result = self.call(args=("--lang", "ruby"))
        self.assertEqual(rc, 3)
        self.assertEqual(result["edges"], [])

    def test_records_and_covered_are_valid_and_deterministic(self):
        covered = self.repo / "covered"
        rc, records = self.call(args=("--format", "records", "--covered", str(covered)))
        self.assertEqual(rc, 0)
        edges = []
        for line in records.splitlines():
            columns = line.split("\t")
            if columns[0] == "2":
                self.assertEqual(len(columns), 7)
                attrs = json.loads("{" + columns[6] + "}")
                self.assertEqual(attrs["method"], "scip")
                edges.append((columns[1], columns[2]))
            elif columns[0] == "1":
                json.loads("{" + columns[5] + "}")
            elif columns[1] != "note":
                json.loads(columns[2])
        self.assertEqual(len(edges), 3)
        self.assertEqual(covered.read_text().splitlines(), sorted(doc["relative_path"] for doc in self.index["documents"]))
        _, second = self.call(args=("--format", "records"))
        self.assertEqual(records, second)

    def test_shell_records_and_coverage_use_lf_bytes_on_every_platform(self):
        self.index_file.write_bytes(encode(self.index))
        covered = self.repo / "coverage-for-awk"
        result = subprocess.run([sys.executable, str(HELPER), "--repo", str(self.repo), "--index", str(self.index_file),
                                 "--tracked", str(self.tracked), "--covered", str(covered), "--format", "records"],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8"))
        self.assertNotIn(b"\r\n", result.stdout)
        self.assertNotIn(b"\r", covered.read_bytes())
        self.assertEqual(covered.read_bytes().splitlines(), sorted(document["relative_path"].encode("utf-8") for document in self.index["documents"]))

    def test_truncated_and_malformed_protobuf_is_reported_without_traceback(self):
        for raw in (b"", b"\x00", b"\x0a\x80", b"\x0a\x10short", b"\x0a\xff" * 10):
            with self.subTest(raw=raw):
                rc, result = self.call(raw=raw)
                self.assertEqual(rc, 3)
                self.assertEqual(result["covered"], [])
                self.assertEqual(result["edges"], [])

    def test_future_unknown_fields_are_skipped(self):
        baseline = encode(self.index)
        unknowns = number(99, 123) + blob(100, b"future") + bytes([0xAD, 0x06]) + bytes(4) + bytes([0xB1, 0x06]) + bytes(8)
        _, expected = self.call(raw=baseline)
        _, actual = self.call(raw=baseline + unknowns)
        self.assertEqual(expected, actual)

    def test_malformed_document_does_not_leave_partial_coverage(self):
        malformed = copy.deepcopy(self.index)
        malformed["documents"].append({"relative_path": "ts/client.ts", "occurrences": None})
        # A separate tracked file avoids being intentionally ignored as a duplicate.
        malformed["documents"][-1]["relative_path"] = "bad.ts"
        (self.repo / "bad.ts").write_text("bad\n")
        self.tracked.write_bytes(self.tracked.read_bytes() + b"bad.ts\0")
        rc, result = self.call(malformed, json_format=True)
        self.assertEqual(rc, 3)
        self.assertEqual(result["covered"], [])
        self.assertEqual(result["edges"], [])

    def test_missing_index_is_structured_diagnostic(self):
        result = subprocess.run([sys.executable, str(HELPER), "--repo", str(self.repo), "--tracked", str(self.tracked), "--index", str(self.repo / "missing.scip")], capture_output=True, text=True)
        self.assertEqual(result.returncode, 3)
        self.assertEqual(result.stderr, "")
        self.assertEqual(json.loads(result.stdout)["diagnostics"][0]["code"], "scip-index-invalid")

    def test_indexer_guide_uses_argument_arrays_and_never_executes(self):
        for language, executable in (("ts", "scip-typescript"), ("js", "scip-typescript"), ("python", "scip-python"), ("java", "scip-java"), ("kotlin", "scip-java")):
            result = subprocess.run([sys.executable, str(HELPER), "--guide", language, "--project-name", "name with spaces"], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0)
            guide = json.loads(result.stdout)
            self.assertEqual(guide["executable"], executable)
            self.assertIsInstance(guide["arguments"], list)
            self.assertTrue(guide["documentation"].startswith("https://github.com/"))
        self.assertIn("--project-name=name with spaces", json.loads(subprocess.check_output([sys.executable, str(HELPER), "--guide", "python", "--project-name", "name with spaces"]))["arguments"])

    def test_actual_cli_merges_binary_index_reference_edges(self):
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        subprocess.run(["git", "-C", str(self.repo), "add", "--", *[doc["relative_path"] for doc in self.index["documents"]]], check=True)
        self.index_file.write_bytes(encode(self.index))
        home = self.repo / "isolated-home"
        home.mkdir()
        environment = dict(os.environ, HOME=str(home), GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1",
                           XDG_CONFIG_HOME=str(home / "config"), XDG_STATE_HOME=str(home / "state"),
                           XDG_CACHE_HOME=str(home / "cache"), GITCH_CONFIG=str(home / "config/gitch/config"),
                           GITCH_SWIFT_DESCRIBE="0", GITCH_SWIFT_INDEX="")
        result = subprocess.run([bash_executable(), str(HELPER.parent / "gitch"), "g", "files", "--index", str(self.index_file), "--json"],
                                env=environment, cwd=str(self.repo), capture_output=True, text=True, encoding="utf-8", timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        graph = json.loads(result.stdout)
        references = [edge for edge in graph["edges"] if edge["kind"] == "reference"]
        self.assertEqual(len(references), 3)
        self.assertEqual(sum(edge["weight"] for edge in references), 10)
        self.assertTrue(all(edge["method"] == "scip" and edge["evidence"] for edge in references))
        self.assertEqual(len({node["id"] for node in graph["nodes"]}), len(graph["nodes"]))


if __name__ == "__main__":
    unittest.main(verbosity=2)
