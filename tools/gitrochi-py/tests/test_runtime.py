"""runtime: manifest rules, version checks, log rotation, the supervisor (restarts, health, signals) and blue/green deploys."""

import json
import os
import signal
import subprocess
import sys
import threading
import unittest
import urllib.request
from pathlib import Path

import testkit
from testkit import Sandbox, free_port, run_cli, wait_for, write_script

from gitrochi import procs
from gitrochi.runtime import manifest as mf
from gitrochi.runtime import supervisor as sv
from gitrochi.runtime import versions

PY = sys.executable
POSIX = os.name != "nt"
APP = """import http.server, os
version = os.environ.get("VERSION", "none")
print("serving", version, "on", os.environ["PORT"], flush=True)
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = version.encode()
        self.send_response(500 if version == "bad" else 200)
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass
http.server.HTTPServer(("127.0.0.1", int(os.environ["PORT"])), Handler).serve_forever()
"""


def get(port, timeout=1.0):
    try:
        with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(f"http://127.0.0.1:{port}/health", timeout=timeout) as r:
            return r.read().decode()
    except Exception:
        return None


def write_manifest(folder, services, requires=None):
    path = Path(folder) / "gitrochi-runtime.json"
    path.write_text(json.dumps({"version": 1, "requires": requires or {}, "services": services}), encoding="utf-8")
    return path


class ManifestTests(unittest.TestCase):
    def setUp(self):
        self.sb = Sandbox()

    def tearDown(self):
        self.sb.close()

    def _load(self, services):
        return mf.load(write_manifest(self.sb.dir, services), str(self.sb.path("state")))

    def test_secrets_are_refused(self):
        with self.assertRaises(mf.ManifestError) as ctx:
            self._load({"hub": {"command": ["hub"], "env": {"API_TOKEN": "abc123"}}})
        self.assertIn("passEnv", ctx.exception.message)
        with self.assertRaises(mf.ManifestError):
            self._load({"hub": {"command": ["hub"], "env": {"UPSTREAM": "ghp_" + "a1B2" * 9}}})
        with self.assertRaises(mf.ManifestError) as ctx:
            self._load({"hub": {"command": ["hub", "--port", "${PROT}"]}})
        self.assertIn("unknown variable", ctx.exception.message)
        with self.assertRaises(mf.ManifestError):
            self._load({"hub": {"command": ["hub"], "deploy": {"slots": {"blue": 8000, "green": 8000}}}})
        with self.assertRaises(mf.ManifestError):
            self._load({"hub": {"command": ["hub"], "restart": {"policy": "sometimes"}}})

    def test_child_env_passes_only_named_variables(self):
        manifest = self._load({"hub": {"command": ["hub", "--addr", "127.0.0.1:${PORT}"], "port": 8787, "env": {"LEVEL": "info"},
                                       "passEnv": ["HUB_TOKEN"]}})
        service = manifest.services["hub"]
        values = manifest.variables(service)
        env = mf.child_env(service, values, {"PATH": "/usr/bin", "HUB_TOKEN": "t-1", "OTHER_SECRET": "nope"})
        self.assertEqual(env["HUB_TOKEN"], "t-1")
        self.assertNotIn("OTHER_SECRET", env)
        self.assertEqual((env["PORT"], env["LEVEL"], env["GITROCHI_SERVICE"]), ("8787", "info", "hub"))
        self.assertEqual([mf.expand(p, values) for p in service.command], ["hub", "--addr", "127.0.0.1:8787"])

    def test_versions(self):
        self.assertEqual(versions.parse_version("go version go1.22.3 darwin/arm64"), (1, 22, 3))
        self.assertEqual(versions.parse_version("v20.11.1"), (20, 11, 1))
        self.assertTrue(versions.satisfies((1, 22, 3), ">=1.22"))
        self.assertFalse(versions.satisfies((18, 19, 0), "^20"))
        self.assertTrue(versions.satisfies((20, 1, 0), "^20"))
        self.assertTrue(versions.satisfies((3, 9, 6), ">=3.9,<4"))
        self.assertFalse(versions.satisfies((1, 3, 0), "~1.2"))

    def test_check_command(self):
        bin_dir = self.sb.path("bin")
        write_script(bin_dir / "node", "print('v18.19.0')\n")
        write_script(bin_dir / "faketool", "print('faketool version 1.4.2')\n")
        os.environ["PATH"] = str(bin_dir) + os.pathsep + os.environ.get("PATH", "")
        path = write_manifest(self.sb.dir, {"svc": {"command": ["faketool", "serve"], "requires": {"faketool": ">=1.2"}}},
                              requires={"node": ">=20", "missingtool": ">=1"})
        code, out, _ = run_cli("runtime", "check", "--json", "--manifest", path)
        doc = json.loads(out)
        self.assertEqual(code, 1)
        by_tool = {r["tool"]: r for r in doc["requirements"]}
        self.assertEqual((by_tool["node"]["version"], by_tool["node"]["ok"]), ("18.19.0", False))
        self.assertTrue(by_tool["faketool"]["ok"])
        self.assertEqual(by_tool["faketool"]["neededBy"], ["svc"])
        self.assertFalse(by_tool["missingtool"]["found"])
        self.assertEqual(doc["commands"][0]["found"], True)
        path = write_manifest(self.sb.dir, {"svc": {"command": ["faketool", "serve"]}}, requires={"node": ">=18"})
        code, out, _ = run_cli("runtime", "check", "--json", "--manifest", path)
        self.assertEqual(code, 0, out)


@unittest.skipUnless(POSIX, "process groups and signals are POSIX here")
class PumpTests(unittest.TestCase):
    def setUp(self):
        self.sb = Sandbox()

    def tearDown(self):
        self.sb.close()

    def test_rotation_and_exit_status(self):
        log = self.sb.path("logs", "svc.log")
        status = self.sb.path("status.json")
        code = subprocess.call([PY, sv.PUMP, "--log", str(log), "--max-bytes", "2048", "--keep", "2", "--status", str(status), "--",
                                PY, "-c", "import sys\nfor i in range(300): print('line %04d ' % i + 'x' * 40)\nsys.exit(3)"])
        self.assertEqual(code, 3)
        self.assertEqual(json.loads(status.read_text())["exitCode"], 3)
        self.assertTrue(log.is_file() and Path(str(log) + ".1").is_file() and Path(str(log) + ".2").is_file())
        self.assertFalse(Path(str(log) + ".3").exists(), "only `keep` old files are kept")
        for path in (log, Path(str(log) + ".1"), Path(str(log) + ".2")):
            self.assertLessEqual(path.stat().st_size, 2048)
        self.assertIn("exit 3", log.read_text())


@unittest.skipUnless(POSIX, "process groups and signals are POSIX here")
class SupervisorTests(unittest.TestCase):
    def setUp(self):
        self.sb = Sandbox()
        self.state = self.sb.path("state")
        self.threads = []

    def tearDown(self):
        for sup, thread in self.threads:
            sup.stopping.set()
            thread.join(timeout=20)
        self.sb.close()

    def _start(self, services):
        manifest = mf.load(write_manifest(self.sb.dir, services), str(self.state))
        lines = []
        sup = sv.Supervisor(manifest, poll=0.05, out=lines.append)
        result = {}
        thread = threading.Thread(target=lambda: result.setdefault("code", sup.run(install_signals=False)), daemon=True)
        thread.start()
        self.threads.append((sup, thread))
        return manifest, sup, thread, result, lines

    def _state(self, name):
        path = self.state / "services" / f"{name}.json"
        return json.loads(path.read_text()) if path.is_file() else {}

    def test_restarts_with_backoff_then_gives_up(self):
        manifest, sup, thread, result, lines = self._start({"flappy": {
            "command": [PY, "-c", "import sys; print('boom'); sys.exit(3)"],
            "restart": {"policy": "on-failure", "maxRestarts": 2, "window": 60, "backoff": {"initial": 0.05, "max": 1, "factor": 2}}}})
        thread.join(timeout=20)
        self.assertFalse(thread.is_alive())
        self.assertEqual(result["code"], 1)
        state = self._state("flappy")
        self.assertEqual((state["state"], state["restarts"], state["lastExit"]), ("failed", 2, 3))
        self.assertIn("gave up after 2 restarts", state["message"])
        starts = manifest.log_path(manifest.services["flappy"]).read_text().count(" start: ")
        self.assertEqual(starts, 3)
        self.assertTrue(any("restart 2 in 0.10s" in line for line in lines), lines)

    def test_never_and_success_exit(self):
        manifest, sup, thread, result, _ = self._start({
            "once": {"command": [PY, "-c", "print('done')"], "restart": "on-failure"},
            "never": {"command": [PY, "-c", "import sys; sys.exit(5)"], "restart": "never"}})
        thread.join(timeout=20)
        self.assertEqual(self._state("once")["state"], "exited")
        self.assertEqual(self._state("never")["state"], "failed")

    def test_failing_health_check_restarts_the_process_group(self):
        manifest, sup, thread, result, _ = self._start({"stuck": {
            "command": [PY, "-c", "import subprocess, sys, time; subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)']); time.sleep(60)"],
            "health": {"command": [PY, "-c", "import sys; sys.exit(1)"], "interval": 0.1, "timeout": 5, "retries": 2, "startPeriod": 0},
            "restart": {"policy": "on-failure", "maxRestarts": 1, "window": 60, "backoff": {"initial": 0.05}},
            "stopTimeout": 2}})
        first = wait_for(lambda: self._state("stuck").get("pgid"), timeout=10)
        self.assertTrue(first)
        thread.join(timeout=30)
        state = self._state("stuck")
        self.assertEqual(state["state"], "failed")
        self.assertIn("health check failed", state["message"])
        self.assertFalse(procs.group_alive(first), "the whole first process group (including its child) was stopped")

    def test_a_slow_start_stays_starting_until_the_first_passing_check(self):
        # The check fails until the service has created its marker file, as a server does
        # before it listens; that is starting, not unhealthy.
        marker = self.sb.path("ready")
        check = f"import os, sys; sys.exit(0 if os.path.exists({str(marker)!r}) else 1)"
        manifest, sup, thread, result, _ = self._start({"slow": {
            "command": [PY, "-c", f"import time; time.sleep(0.6); open({str(marker)!r}, 'w').close(); time.sleep(60)"],
            "health": {"command": [PY, "-c", check], "interval": 0.1, "timeout": 5, "retries": 50, "startPeriod": 0},
            "stopTimeout": 2}})
        seen = set()

        def healthy():
            seen.add(self._state("slow").get("state"))
            return "healthy" in seen
        self.assertTrue(wait_for(healthy, timeout=15), seen)
        self.assertIn("starting", seen)
        self.assertNotIn("unhealthy", seen)
        sup.stopping.set()

    def test_periodic_job(self):
        manifest, sup, thread, result, _ = self._start({"sync": {"command": [PY, "-c", "print('synced')"], "every": 0.2}})
        log = manifest.log_path(manifest.services["sync"])
        self.assertTrue(wait_for(lambda: log.is_file() and log.read_text().count("synced") >= 3, timeout=10))
        self.assertIn(self._state("sync")["state"], ("waiting", "running"))
        self.assertEqual(self._state("sync")["lastExit"], 0)
        sup.stopping.set()
        thread.join(timeout=10)
        self.assertEqual(self._state("sync")["state"], "stopped")


@unittest.skipUnless(POSIX, "process groups and signals are POSIX here")
class SupervisorProcessTests(unittest.TestCase):
    """The supervisor as its own process: background start, restart, logs, SIGTERM, down."""

    def setUp(self):
        self.sb = Sandbox()
        self.state = self.sb.path("state")
        self.port = free_port()
        app = self.sb.path("app.py")
        app.write_text(APP, encoding="utf-8")
        self.manifest = write_manifest(self.sb.dir, {"web": {
            "command": [PY, str(app)], "port": self.port, "env": {"VERSION": "plain"},
            "health": {"http": "http://127.0.0.1:${PORT}/health", "interval": 0.2, "timeout": 1, "retries": 3, "startPeriod": 0},
            "stopTimeout": 3}})
        self.env = dict(os.environ, PYTHONPATH=str(testkit.PACKAGE_DIR))
        self.proc = None

    def tearDown(self):
        if self.proc and self.proc.poll() is None:
            self.proc.kill()
        run_cli("runtime", "down", "--manifest", self.manifest, "--state-dir", self.state)
        self.sb.close()

    def _web(self):
        path = self.state / "services" / "web.json"
        return json.loads(path.read_text()) if path.is_file() else {}

    def test_foreground_supervisor_stops_cleanly_on_sigterm(self):
        with open(self.sb.path("supervisor.out"), "wb") as out:
            self.proc = subprocess.Popen([PY, "-m", "gitrochi", "runtime", "up", "--foreground", "--manifest", str(self.manifest),
                                          "--state-dir", str(self.state)], env=self.env, cwd=str(self.sb.dir), stdout=out,
                                         stderr=subprocess.STDOUT)
        self.assertTrue(wait_for(lambda: self._web().get("state") == "healthy", timeout=15), self._web())
        pgid = self._web()["pgid"]
        self.assertEqual(get(self.port), "plain")
        code, out, _ = run_cli("runtime", "status", "--json", "--manifest", self.manifest, "--state-dir", self.state)
        status = json.loads(out)
        self.assertTrue(status["supervisor"]["running"])
        self.assertEqual(status["services"][0]["state"], "healthy")
        self.proc.send_signal(signal.SIGTERM)
        self.assertEqual(self.proc.wait(timeout=15), 0)
        self.assertFalse(procs.group_alive(pgid), "SIGTERM stopped the service's process group")
        self.assertEqual(self._web()["state"], "stopped")
        self.assertFalse((self.state / "supervisor.json").exists())
        self.assertIsNone(get(self.port))

    def test_background_up_restart_logs_down(self):
        code, out, err = run_cli("runtime", "up", "--json", "--manifest", self.manifest, "--state-dir", self.state)
        self.assertEqual(code, 0, out + err)
        self.assertTrue(json.loads(out)["supervisor"]["running"])
        self.assertTrue(wait_for(lambda: self._web().get("state") == "healthy", timeout=15), self._web())
        first = self._web()["pid"]
        code, out, _ = run_cli("runtime", "restart", "web", "--json", "--manifest", self.manifest, "--state-dir", self.state)
        self.assertEqual(code, 0)
        self.assertTrue(wait_for(lambda: self._web().get("pid") not in (None, first) and self._web().get("state") == "healthy", timeout=15))
        self.assertFalse(procs.pid_alive(first))
        code, out, _ = run_cli("runtime", "logs", "web", "--json", "--manifest", self.manifest, "--state-dir", self.state)
        lines = json.loads(out)["services"][0]["lines"]
        self.assertEqual(sum(1 for line in lines if line.startswith("serving plain")), 2)
        pgid = self._web()["pgid"]
        code, out, _ = run_cli("runtime", "down", "--json", "--manifest", self.manifest, "--state-dir", self.state)
        self.assertEqual(code, 0, out)
        self.assertFalse(json.loads(out)["supervisor"]["running"])
        self.assertFalse(procs.group_alive(pgid))


@unittest.skipUnless(POSIX, "process groups and signals are POSIX here")
class DeployTests(unittest.TestCase):
    def setUp(self):
        self.sb = Sandbox()
        self.state = self.sb.path("state")
        self.blue, self.green = free_port(), free_port()
        for version in ("v1", "v2", "bad"):
            folder = self.sb.path("releases", version)
            folder.mkdir(parents=True)
            (folder / "app.py").write_text(APP, encoding="utf-8")
        self.path = write_manifest(self.sb.dir, {"app": {
            "command": [PY, "app.py"], "cwd": "${RELEASE_DIR}",
            "health": {"http": "http://127.0.0.1:${PORT}/health", "interval": 0.1, "timeout": 1, "retries": 2, "startPeriod": 0},
            "restart": {"policy": "on-failure", "maxRestarts": 3, "window": 60, "backoff": {"initial": 0.05}},
            "stopTimeout": 3,
            "deploy": {"slots": {"blue": self.blue, "green": self.green}, "release": "releases/${VERSION}", "healthTimeout": 5}}})
        self.threads = []

    def tearDown(self):
        for sup, thread in self.threads:
            sup.stopping.set()
            thread.join(timeout=20)
        run_cli("runtime", "down", "--manifest", self.path, "--state-dir", self.state)
        self.sb.close()

    def _deploy(self, version, *extra):
        code, out, err = run_cli("runtime", "deploy", "app", "--version", version, "--json", "--manifest", self.path,
                                 "--state-dir", self.state, *extra)
        self.assertNotIn("Traceback", err)
        return code, json.loads(out)

    def _current(self):
        return json.loads((self.state / "deploy" / "app.json").read_text())["current"]

    def test_blue_green_switch_and_rollback(self):
        code, doc = self._deploy("v1")
        self.assertEqual((code, doc["result"]), (0, "deployed"), doc)
        self.assertEqual(get(self.blue), "v1")
        v1 = self._current()
        self.assertEqual((v1["slot"], v1["port"]), ("blue", self.blue))
        code, doc = self._deploy("v2")
        self.assertEqual((code, doc["result"]), (0, "deployed"), doc)
        self.assertEqual(doc["from"]["version"], "v1")
        self.assertEqual(get(self.green), "v2")
        self.assertIsNone(get(self.blue), "the old release was stopped")
        self.assertFalse(procs.group_alive(v1["pgid"]))
        link = self.state / "deploy" / "app" / "current"
        self.assertEqual(Path(os.readlink(link)).name, "v2")
        code, doc = self._deploy("bad", "--health-timeout", "1.5")
        self.assertEqual((code, doc["result"]), (1, "rolled_back"), doc)
        self.assertEqual(self._current()["version"], "v2", "a failed health check keeps the old release")
        self.assertEqual(get(self.green), "v2")
        self.assertIsNone(get(self.blue), "the bad release was stopped")
        self.assertEqual(Path(os.readlink(link)).name, "v2")
        history = json.loads((self.state / "deploy" / "app.json").read_text())["history"]
        self.assertEqual([h["result"] for h in history], ["deployed", "deployed", "rolled_back"])
        code, doc = self._deploy("v9")
        self.assertEqual((code, doc["result"]), (1, "failed"))
        self.assertIn("does not exist", doc["steps"][0]["detail"])

    def test_supervisor_follows_deploys_and_restarts_the_current_release(self):
        code, doc = self._deploy("v1")
        self.assertEqual(code, 0, doc)
        manifest = mf.load(self.path, str(self.state))
        sup = sv.Supervisor(manifest, poll=0.05, out=lambda line: None)
        thread = threading.Thread(target=lambda: sup.run(install_signals=False), daemon=True)
        thread.start()
        self.threads.append((sup, thread))
        state = lambda: json.loads((self.state / "services" / "app.json").read_text()) if (self.state / "services" / "app.json").is_file() else {}
        self.assertTrue(wait_for(lambda: state().get("state") == "healthy" and state().get("pid") == self._current()["pid"], timeout=10),
                        "the supervisor adopts the deployed process")
        code, doc = self._deploy("v2")
        self.assertEqual(code, 0, doc)
        self.assertTrue(wait_for(lambda: state().get("version") == "v2" and state().get("pid") == self._current()["pid"], timeout=10),
                        state())
        procs.signal_group(self._current()["pgid"], signal.SIGKILL)
        self.assertTrue(wait_for(lambda: get(self.green) == "v2" and state().get("restarts", 0) >= 1, timeout=15), state())
        self.assertEqual(self._current()["slot"], "green")


if __name__ == "__main__":
    unittest.main()
