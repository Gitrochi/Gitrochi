#!/usr/bin/env python3
"""Exercise an actual live server and tracked-file rebuilds with an isolated CLI."""

import http.client
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import queue
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock
from types import SimpleNamespace
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import Request, urlopen
from helper_test_support import bash_executable, stop_process_tree, write_utf8


HELPER = Path(__file__).resolve().parents[1] / "gitch-graph-watch"


class WatchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.parent = Path(self.temp.name)
        self.repo = self.parent / "work repo"
        self.repo.mkdir()
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        (self.repo / "a.ts").write_text("original")
        (self.repo / "control.txt").write_text("ok")
        subprocess.run(["git", "-C", str(self.repo), "add", "a.ts", "control.txt"], check=True)
        self.output = self.parent / "graph result.html"
        self.output.write_text("<!doctype html><html><body>initial</body></html>")
        self.cli = self.parent / "fake gitch"
        write_utf8(self.cli, '''#!/bin/bash
out=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = --out ]; then shift; out="$1"; fi
  shift
done
if ! mkdir .building 2>/dev/null; then echo concurrent >&2; exit 1; fi
trap 'rmdir .building' EXIT
printf 'call\\n' >> .calls
case "$(cat control.txt)" in
  fail) echo fixture-build-failure >&2; exit 1 ;;
  invalid) printf incomplete > "$out"; exit 0 ;;
  slow) sleep 0.2 ;;
esac
printf '<!doctype html><html><body>' > "$out"
cat a.ts >> "$out"
printf '</body></html>' >> "$out"
''')

    def command(self, *extra):
        return [sys.executable, str(HELPER), "--repo", str(self.repo), "--cli", str(self.cli), "--out", str(self.output),
                "--bash", bash_executable(),
                "--interval", "0.1", "--idle-timeout", "10", "--max-lifetime", "30", *extra]

    def start(self, *extra):
        process = subprocess.Popen(self.command(*extra), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8")
        def cleanup():
            if process.poll() is None:
                stop_process_tree(process.pid)
                try:
                    process.wait(timeout=4)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=2)
            process.stdout.close()
            process.stderr.close()
        self.addCleanup(cleanup)
        lines = queue.Queue()
        threading.Thread(target=lambda: lines.put(process.stdout.readline()), daemon=True).start()
        result = json.loads(lines.get(timeout=5))
        self.assertNotIn("error", result)
        self.assertTrue(result["url"].startswith("http://127.0.0.1:"))
        return process, result

    def state(self, info):
        with urlopen(info["stateUrl"], timeout=2) as response:
            return json.load(response)

    def until(self, predicate, message="watch condition", timeout=5):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            result = predicate()
            if result:
                return result
            time.sleep(0.03)
        self.fail("timed out: " + message)

    def ready(self, info):
        return self.until(lambda: (state if (state := self.state(info))["generation"] >= 2 and state["phase"] == "idle" else None), "initial rebuild")

    def test_tracked_edit_rebuilds_and_serves_polling_client(self):
        _, info = self.start()
        before = self.ready(info)
        (self.repo / "a.ts").write_text("changed source")
        self.until(lambda: self.state(info)["generation"] > before["generation"], "source edit rebuild")
        with urlopen(info["url"], timeout=2) as response:
            html = response.read().decode()
            self.assertEqual(response.headers["Referrer-Policy"], "no-referrer")
        self.assertIn("changed source", html)
        self.assertIn('id="gitch-live-watch"', html)
        self.assertIn(info["stateUrl"], html)
        self.assertIn("gitch:before-live-reload", html)
        self.assertNotIn("gitch-live-watch", self.output.read_text())

    def test_failure_preserves_last_valid_graph_and_recovers_after_edit(self):
        _, info = self.start()
        before = self.ready(info)
        good = self.output.read_bytes()
        (self.repo / "control.txt").write_text("fail")
        failure = self.until(lambda: (state if (state := self.state(info))["phase"] == "error" else None), "build failure")
        self.assertIn("fixture-build-failure", failure["lastError"])
        self.assertEqual(failure["generation"], before["generation"])
        self.assertEqual(self.output.read_bytes(), good)
        (self.repo / "control.txt").write_text("ok")
        (self.repo / "a.ts").write_text("recovered")
        self.until(lambda: self.state(info)["generation"] > before["generation"], "recovery")
        self.assertIsNone(self.state(info)["lastError"])
        self.assertIn("recovered", self.output.read_text())
        self.assertEqual(list(self.parent.glob(".gitch-watch-*.html")), [])

    def test_invalid_success_output_does_not_replace_graph(self):
        _, info = self.start()
        self.ready(info)
        good = self.output.read_bytes()
        (self.repo / "control.txt").write_text("invalid")
        self.until(lambda: self.state(info)["phase"] == "error", "invalid generated HTML")
        self.assertEqual(self.output.read_bytes(), good)

    def test_untracked_edit_does_not_rebuild_but_new_tracked_file_does(self):
        _, info = self.start()
        before = self.ready(info)["generation"]
        (self.repo / "new.ts").write_text("untracked")
        time.sleep(0.35)
        self.assertEqual(self.state(info)["generation"], before)
        subprocess.run(["git", "-C", str(self.repo), "add", "new.ts"], check=True)
        self.until(lambda: self.state(info)["generation"] > before, "index change")

    def test_preserved_mtime_content_edit_is_detected(self):
        _, info = self.start()
        before = self.ready(info)["generation"]
        path = self.repo / "a.ts"
        stamp = path.stat()
        path.write_text("replaced")
        os.utime(path, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
        self.until(lambda: self.state(info)["generation"] > before, "content edit with preserved mtime")

    def test_head_branch_change_without_source_edit_is_detected(self):
        _, info = self.start()
        before = self.ready(info)["generation"]
        subprocess.run(["git", "-C", str(self.repo), "symbolic-ref", "HEAD", "refs/heads/new-branch"], check=True)
        self.until(lambda: self.state(info)["generation"] > before, "HEAD reference change")

    def test_rules_and_selected_index_are_watched(self):
        index = self.parent / "selected.scip"
        index.write_bytes(b"index")
        _, info = self.start("--index", str(index))
        before = self.ready(info)["generation"]
        (self.repo / ".gitch").mkdir()
        (self.repo / ".gitch/graph.rules").write_text("no-cycles")
        self.until(lambda: self.state(info)["generation"] > before, "rules change")
        before = self.state(info)["generation"]
        index.write_bytes(b"new index")
        self.until(lambda: self.state(info)["generation"] > before, "selected SCIP index change")

    def test_precise_mode_watches_new_preferred_default_index(self):
        _, info = self.start("--relation", "precise")
        before = self.ready(info)["generation"]
        (self.repo / ".gitch").mkdir()
        index = self.repo / ".gitch/index.scip"
        index.write_bytes(b"new default index")
        self.until(lambda: self.state(info)["generation"] > before, "preferred default SCIP index creation")

    def test_server_exposes_only_token_protected_graph_and_state(self):
        _, info = self.start()
        self.ready(info)
        parsed = urlsplit(info["url"])
        for path in ("/", "/a.ts", "/.git/config", "/bad-token/graph", parsed.path + "/../../a.ts", parsed.path + "?anything"):
            with self.subTest(path=path):
                with self.assertRaises(HTTPError) as error:
                    urlopen(parsed.scheme + "://" + parsed.netloc + path, timeout=2)
                self.assertEqual(error.exception.code, 404)
        connection = http.client.HTTPConnection(parsed.hostname, parsed.port, timeout=2)
        connection.request("GET", parsed.path, headers={"Host": "attacker.example"})
        response = connection.getresponse()
        self.assertEqual(response.status, 403)
        response.read()
        connection.close()

    def test_manual_refresh_requires_header_and_same_origin(self):
        _, info = self.start()
        before = self.ready(info)["generation"]
        for headers in ({}, {"X-Gitch-Watch": "1", "Origin": "https://attacker.example"}):
            with self.assertRaises(HTTPError) as error:
                urlopen(Request(info["refreshUrl"], method="POST", headers=headers), timeout=2)
            self.assertEqual(error.exception.code, 403)
        with urlopen(Request(info["refreshUrl"], method="POST", headers={"X-Gitch-Watch": "1"}), timeout=2) as response:
            self.assertEqual(response.status, 202)
        self.until(lambda: self.state(info)["generation"] > before, "manual refresh")

    def test_output_symlink_is_never_served_or_overwritten(self):
        _, info = self.start()
        self.ready(info)
        secret = self.parent / "private.html"
        secret.write_text("<!doctype html><html>private secret</html>")
        self.output.unlink()
        try:
            self.output.symlink_to(secret)
        except OSError as exc:
            self.skipTest("symbolic link creation is unavailable: " + str(exc))
        with self.assertRaises(HTTPError) as error:
            urlopen(info["url"], timeout=2)
        self.assertEqual(error.exception.code, 503)
        (self.repo / "a.ts").write_text("trigger")
        self.until(lambda: self.state(info)["phase"] == "error", "output symlink refusal")
        self.assertIn("private secret", secret.read_text())

    def test_detach_returns_ready_url_and_child_has_idle_lease(self):
        result = subprocess.run(self.command("--detach", "--idle-timeout", "0.7"), capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        info = json.loads(result.stdout)
        with urlopen(info["url"], timeout=2) as response:
            self.assertEqual(response.status, 200)
        parsed = urlsplit(info["url"])
        def port_closed():
            # Opening a TCP connection does not refresh the HTTP client lease.
            # Polling state while waiting would keep the watcher alive forever.
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as connection:
                connection.settimeout(0.2)
                return connection.connect_ex((parsed.hostname, parsed.port)) != 0
        self.until(port_closed, "detached watcher idle shutdown", timeout=6)
        with self.assertRaises((URLError, ConnectionError)):
            urlopen(info["url"], timeout=1)

    def test_idle_lease_and_absolute_lifetime_stop_server(self):
        process, info = self.start("--idle-timeout", "0.4")
        process.wait(timeout=6)
        self.assertEqual(process.returncode, 0)
        process, info = self.start("--max-lifetime", "0.6")
        deadline = time.monotonic() + 2
        while process.poll() is None and time.monotonic() < deadline:
            try:
                self.state(info)
            except (URLError, ConnectionError):
                break
            time.sleep(0.05)
        process.wait(timeout=6)
        self.assertEqual(process.returncode, 0)

    def test_rebuilds_are_serial_and_coalesced(self):
        _, info = self.start()
        self.ready(info)
        (self.repo / "control.txt").write_text("slow")
        self.until(lambda: self.state(info)["phase"] == "building")
        for n in range(8):
            (self.repo / "a.ts").write_text("change-%d" % n)
            time.sleep(0.025)
        self.until(lambda: self.state(info)["phase"] == "idle" and "change-7" in self.output.read_text())
        self.assertIsNone(self.state(info)["lastError"])
        self.assertLessEqual(len((self.repo / ".calls").read_text().splitlines()), 4)

    def test_missing_output_is_structured_error_without_background_leak(self):
        self.output.unlink()
        result = subprocess.run(self.command("--detach"), capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 3)
        self.assertEqual(json.loads(result.stdout)["error"], "watch-unavailable")
        self.assertEqual(result.stderr, "")

    def test_reopening_same_watch_reuses_server_and_url(self):
        _, info = self.start()
        self.ready(info)
        result = subprocess.run(self.command("--detach"), capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0)
        second = json.loads(result.stdout)
        self.assertEqual(second["pid"], info["pid"])
        self.assertEqual(second["url"], info["url"])
        self.assertEqual(second["storageStable"], info["storageStable"])
        registries = list((self.repo / ".git/gitch/graph-watch").glob("*.json"))
        self.assertEqual(len(registries), 1)
        if os.name != "nt":
            self.assertEqual(registries[0].stat().st_mode & 0o777, 0o600)

    def test_changed_ui_language_does_not_reuse_existing_watch(self):
        with mock.patch.dict(os.environ, {"GITCH_GRAPH_LANG": "en"}):
            _, original = self.start()
            self.ready(original)
        with mock.patch.dict(os.environ, {"GITCH_GRAPH_LANG": "ja"}):
            _, localized = self.start()
            self.ready(localized)
            reopened = subprocess.run(self.command("--detach"), capture_output=True, text=True, timeout=5)
        self.assertEqual(reopened.returncode, 0, reopened.stdout + reopened.stderr)
        reused = json.loads(reopened.stdout)
        self.assertNotEqual(localized["pid"], original["pid"])
        self.assertNotEqual(localized["url"], original["url"])
        self.assertEqual(reused["pid"], localized["pid"])
        self.assertEqual(reused["url"], localized["url"])

    def test_graph_arguments_preserve_filters_and_reject_output_flags(self):
        # The fake CLI logs argv in separate lines, preserving spaces.
        write_utf8(self.cli, self.cli.read_text(encoding="utf-8").replace('out=""', 'printf "%s\\n" "$@" > .arguments\nout=""'))
        _, info = self.start("--graph-arg=--lang", "--graph-arg=ts,python", "--graph-arg=--since", "--graph-arg=3 months ago", "--graph-arg=--no-external")
        self.ready(info)
        actual = (self.repo / ".arguments").read_text().splitlines()
        self.assertIn("ts,python", actual)
        self.assertIn("3 months ago", actual)
        self.assertIn("--no-external", actual)
        for forbidden in ("--out=other.html", "--open", "--format=json", "--graph-arg", "../../outside", "check"):
            result = subprocess.run(self.command("--detach", "--graph-arg=" + forbidden), capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 3)
            self.assertIn("watch-unavailable", result.stdout)

    def test_actual_cli_watch_rebuilds_after_tracked_edit(self):
        cli = HELPER.parent / "gitch"
        home = self.parent / "isolated home"
        home.mkdir()
        environment = dict(os.environ, HOME=str(home), GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1",
                           XDG_CONFIG_HOME=str(home / "config"), XDG_STATE_HOME=str(home / "state"),
                           XDG_CACHE_HOME=str(home / "cache"), GITSW_CONFIG=str(home / "config/gitsw/config"),
                           GITSW_SWIFT_DESCRIBE="0", GITCH_SWIFT_INDEX="")
        result = subprocess.run([bash_executable(), str(cli), "g", "watch", "files", "--out", str(self.output),
                                 "--interval", "1", "--no-open", "--detach", "--json", "--lang", "ts"],
                                env=environment, cwd=str(self.repo), capture_output=True, text=True, encoding="utf-8", timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        info = json.loads(result.stdout)
        def stop():
            stop_process_tree(info["pid"])
        self.addCleanup(stop)
        before = self.until(lambda: (state if (state := self.state(info))["generation"] >= 2 and state["phase"] == "idle" else None),
                            "actual CLI initial rebuild", timeout=15)
        (self.repo / "a.ts").write_text("edited\nsecond\n")
        self.until(lambda: self.state(info)["generation"] > before["generation"], "actual CLI tracked edit", timeout=15)
        self.assertIn('"lines":2', self.output.read_text(encoding="utf-8"))

    @unittest.skipIf(os.name == "nt", "TerminateProcess bypasses Python signal handlers on Windows")
    def test_stopping_watch_during_build_stops_its_render_tree(self):
        write_utf8(self.cli, self.cli.read_text(encoding="utf-8").replace("slow) sleep 0.2", "slow) sleep 20"))
        (self.repo / "control.txt").write_text("slow")
        process, info = self.start()
        self.until(lambda: self.state(info)["phase"] == "building")
        process.terminate()
        process.wait(timeout=3)
        self.assertEqual(process.returncode, 0)
        self.assertEqual(list(self.parent.glob(".gitch-watch-*.html")), [])

    def test_explicit_bash_path_is_validated(self):
        result = subprocess.run(self.command("--bash", str(self.parent / "missing bash")), capture_output=True, text=True, encoding="utf-8", timeout=5)
        self.assertEqual(result.returncode, 3)
        self.assertEqual(json.loads(result.stdout)["error"], "watch-unavailable")

    def test_shell_fixture_uses_literal_lf_and_utf8(self):
        self.assertNotIn(b"\r\n", self.cli.read_bytes())
        self.assertTrue(self.cli.read_bytes().startswith(b"#!/bin/bash\n"))

    def atomic_watcher(self):
        loader = importlib.machinery.SourceFileLoader("gitch_watch_atomic_test", str(HELPER))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        module = importlib.util.module_from_spec(spec)
        loader.exec_module(module)
        args = SimpleNamespace(repo=str(self.repo), cli=str(self.cli), out=str(self.output), bash=bash_executable(),
                               relation="files", index=None, lang="", base="", since="", no_external=False,
                               graph_arg=[], interval=0.1, idle_timeout=10, max_lifetime=30, build_timeout=10)
        watcher = module.GraphWatch(args)
        self.addCleanup(watcher.server.server_close)
        def build(destination):
            destination.write_text("<!doctype html><html><body>new graph</body></html>", encoding="utf-8")
            return subprocess.CompletedProcess([], 0, b"", b"")
        watcher.run_builder = build
        return module, watcher

    def test_loopback_startup_and_http_never_require_reverse_dns(self):
        # macOS CI can spend over 30 seconds resolving even 127.0.0.1.
        # A loopback-only server must bind and answer without that resolver.
        with mock.patch("socket.getfqdn", side_effect=AssertionError("unexpected reverse DNS")) as resolve:
            _, watcher = self.atomic_watcher()
            ready_file = self.parent / "watch ready.json"
            worker = threading.Thread(target=watcher.run, args=(str(ready_file),), daemon=True)
            worker.start()
            try:
                info = watcher.description()
                self.ready(info)
                self.assertEqual(json.loads(ready_file.read_text(encoding="utf-8"))["url"], info["url"])
                with urlopen(info["url"], timeout=2) as response:
                    self.assertEqual(response.status, 200)
                    self.assertIn(b"new graph", response.read())
                self.assertEqual(watcher.server.server_name, "127.0.0.1")
                self.assertEqual(watcher.server.server_port, watcher.server.server_address[1])
                resolve.assert_not_called()
            finally:
                watcher.stop.set()
                worker.join(timeout=3)
            self.assertFalse(worker.is_alive(), "loopback watcher did not stop")

    def test_served_html_and_generation_snapshot_are_atomic(self):
        _, watcher = self.atomic_watcher()
        entered, release, written = threading.Event(), threading.Event(), threading.Event()
        original_read = watcher.read_html
        replies, errors = [], []
        def paused_read(path):
            html = original_read(path)
            if path == watcher.output:
                entered.set()
                if not release.wait(3):
                    raise ValueError("test reader release timeout")
            return html
        watcher.read_html = paused_read
        def read():
            try:
                replies.append(watcher.injected_html().decode("utf-8"))
            except Exception as exc:
                errors.append(exc)
        def write():
            watcher.rebuild()
            written.set()
        reader = threading.Thread(target=read)
        writer = threading.Thread(target=write)
        reader.start()
        self.assertTrue(entered.wait(2))
        writer.start()
        try:
            self.assertFalse(written.wait(0.15), "rebuild replaced an HTML file while a response was capturing it")
        finally:
            release.set()
            reader.join(timeout=3)
            writer.join(timeout=3)
        self.assertFalse(reader.is_alive() or writer.is_alive())
        self.assertEqual(errors, [])
        self.assertIn('<body>initial<script id="gitch-live-watch">', replies[0])
        self.assertIn("let generation = 1,", replies[0])
        self.assertEqual(watcher.snapshot()["generation"], 2)

    def test_content_change_is_detected_with_unreliable_stat_timestamps(self):
        _, watcher = self.atomic_watcher()
        watcher.cache_can_trust_ctime = False
        source = self.repo / "a.ts"
        original_stat = source.lstat()
        original = watcher.fingerprint_file(source)
        write_utf8(source, "replaced")  # same byte count as "original"
        with mock.patch.object(Path, "lstat", return_value=original_stat):
            changed = watcher.fingerprint_file(source)
        self.assertNotEqual(original, changed)

    def test_output_swap_and_generation_update_are_atomic(self):
        module, watcher = self.atomic_watcher()
        swapped, release, read_done = threading.Event(), threading.Event(), threading.Event()
        original_replace = module.os.replace
        replies, errors = [], []
        def paused_replace(source, destination):
            original_replace(source, destination)
            if Path(destination) == watcher.output:
                swapped.set()
                if not release.wait(3):
                    raise ValueError("test writer release timeout")
        def read():
            try:
                replies.append(watcher.injected_html().decode("utf-8"))
            except Exception as exc:
                errors.append(exc)
            finally:
                read_done.set()
        writer = threading.Thread(target=watcher.rebuild)
        reader = threading.Thread(target=read)
        with mock.patch.object(module.os, "replace", side_effect=paused_replace):
            writer.start()
            self.assertTrue(swapped.wait(2))
            reader.start()
            try:
                self.assertFalse(read_done.wait(0.15), "response observed swapped HTML before its generation changed")
            finally:
                release.set()
                writer.join(timeout=3)
                reader.join(timeout=3)
        self.assertFalse(reader.is_alive() or writer.is_alive())
        self.assertEqual(errors, [])
        self.assertIn('<body>new graph<script id="gitch-live-watch">', replies[0])
        self.assertIn("let generation = 2,", replies[0])


if __name__ == "__main__":
    unittest.main(verbosity=2)
