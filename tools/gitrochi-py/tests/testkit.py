"""Hermetic fixtures for the gitrochi-py tests: temporary git repositories, index databases built from
crates/gitrochi-index/src/schema.sql, loopback mock HTTP servers, and an in-process CLI runner.

Nothing here touches the network, the real Keychain, the user's git configuration or installed gitch tools.
"""

import contextlib
import hashlib
import io
import json
import os
import shutil
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from socketserver import TCPServer
from unittest import mock

PACKAGE_DIR = Path(__file__).resolve().parents[1]
REPO_ROOT = Path(__file__).resolve().parents[3]
SCHEMA_SQL = REPO_ROOT / "crates" / "gitrochi-index" / "src" / "schema.sql"
if str(PACKAGE_DIR) not in sys.path:
    sys.path.insert(0, str(PACKAGE_DIR))

SECRET_ENV = ("ANTHROPIC_API_KEY", "OPENAI_API_KEY", "GEMINI_API_KEY", "GITROCHI_AI_KEY", "GITROCHI_AI_BASE_URL",
              "GITROCHI_INDEX", "GITROCHI_INDEX_DB", "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "PYTHONPATH")
DAY = 86400
NOW = 1_790_000_000  # a fixed "now" (2026-09) for reproducible analyses


class Sandbox:
    """A temporary folder plus an environment that isolates git and the gitrochi tools."""

    def __init__(self):
        self.dir = Path(tempfile.mkdtemp(prefix="gitrochi-py-test-")).resolve()
        self.home = self.dir / "home"
        self.home.mkdir()
        self.gitconfig = self.dir / "empty.gitconfig"
        self.gitconfig.write_text("", encoding="utf-8")
        self.env = {
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": str(self.gitconfig),
            "HOME": str(self.home),
            "XDG_CONFIG_HOME": str(self.home / ".config"),
            "GIT_TERMINAL_PROMPT": "0",
            # Explicit settings that point nowhere: the code must not fall back to installed tools.
            "GITROCHI_INDEX_BIN": str(self.dir / "missing-gitrochi-index"),
            "GITCH": str(self.dir / "missing-gitch"),
            "GITCH_FLOW": str(self.dir / "missing-gitch-flow"),
            "GITROCHI_NO_KEYCHAIN": "1",
            "GITROCHI_PY_CONFIG": str(self.dir / "missing-config.json"),
        }
        self._patch = mock.patch.dict(os.environ, self.env)
        self._patch.start()
        for name in SECRET_ENV:
            os.environ.pop(name, None)

    def path(self, *parts):
        return self.dir.joinpath(*parts)

    def close(self):
        self._patch.stop()
        shutil.rmtree(self.dir, ignore_errors=True)


class Repo:
    """A git repository in the sandbox. Identities are set with `git config` inside the repository."""

    def __init__(self, path, branch="main"):
        self.path = Path(path)
        self.path.mkdir(parents=True, exist_ok=True)
        self.git("init", "-q")
        self.git("symbolic-ref", "HEAD", f"refs/heads/{branch}")
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "core.autocrlf", "false")
        self.author("Test Author", "author@example.com")

    def git(self, *args, env=None, check=True):
        full = dict(os.environ)
        full.update(env or {})
        proc = subprocess.run(["git"] + list(args), cwd=str(self.path), env=full, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, check=False)
        if check and proc.returncode != 0:
            raise AssertionError(f"git {' '.join(args)} failed: {proc.stderr.decode('utf-8', 'replace')}")
        return proc.stdout.decode("utf-8", "replace").strip()

    def author(self, name, email):
        self.git("config", "user.name", name)
        self.git("config", "user.email", email)

    def write(self, rel, text):
        target = self.path / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(text.encode("utf-8") if isinstance(text, str) else text)
        return target

    def remove(self, rel):
        (self.path / rel).unlink()

    def commit(self, message, when=None):
        env = {}
        if when is not None:
            env = {"GIT_AUTHOR_DATE": f"{int(when)} +0000", "GIT_COMMITTER_DATE": f"{int(when)} +0000"}
        self.git("add", "-A")
        self.git("commit", "-q", "--no-verify", "-m", message, env=env)
        return self.git("rev-parse", "HEAD")

    def common_dir(self):
        out = self.git("rev-parse", "--git-common-dir")
        path = Path(out)
        return path if path.is_absolute() else (self.path / path).resolve()


def build_index(db_path, commits, max_files=30, wal=True):
    """An index database like crates/gitrochi-index writes, from
    commits = [{"author": (name, email), "time": unix, "subject": str, "files": [(path, status, adds, dels)], "parents": 1}].
    Derived tables (path_stats, cochange) follow the README: cochange only for commits with <= max_files files."""
    if not SCHEMA_SQL.is_file():
        raise AssertionError(f"{SCHEMA_SQL} is missing: the fixtures need the index schema")
    db_path = Path(db_path)
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(db_path))
    if wal:
        conn.execute("PRAGMA journal_mode=WAL")
    conn.executescript(SCHEMA_SQL.read_text(encoding="utf-8"))
    conn.execute("PRAGMA user_version = 1")
    newest = max((c["time"] for c in commits), default=0)
    for key, value in (("schema", "1"), ("created", str(newest)), ("last_sync", str(newest)), ("max_files", str(max_files)), ("shallow", "0")):
        conn.execute("INSERT INTO meta (key, value) VALUES (?, ?)", (key, value))
    path_ids = {}

    def pid(path):
        if path not in path_ids:
            cur = conn.execute("INSERT INTO paths (path) VALUES (?)", (path,))
            path_ids[path] = cur.lastrowid
        return path_ids[path]

    stats = {}
    pairs = {}
    for number, c in enumerate(commits, start=1):
        sha = c.get("sha") or hashlib.sha1(f"commit-{number}".encode()).hexdigest()
        name, email = c["author"]
        files = c.get("files", [])
        adds = sum(f[2] or 0 for f in files)
        dels = sum(f[3] or 0 for f in files)
        parents = c.get("parents", 1)
        cur = conn.execute(
            "INSERT INTO commits (sha, tree, author_name, author_email, author_time, committer_name, committer_email, commit_time, "
            "subject, body, parent_count, files_changed, additions, deletions) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (sha, "t" + sha[1:], name, email, c["time"], name, email, c["time"], c.get("subject", f"Commit {number}"), "",
             parents, len(files), adds, dels))
        cid = cur.lastrowid
        ids = []
        for path, status, a, d in files:
            p = pid(path)
            ids.append(p)
            conn.execute("INSERT INTO file_changes (commit_id, path_id, status, old_path_id, similarity, additions, deletions) "
                         "VALUES (?, ?, ?, NULL, NULL, ?, ?)", (cid, p, status, a, d))
            s = stats.setdefault(p, {"commits": 0, "coupling": 0, "additions": 0, "deletions": 0, "first": c["time"], "last": c["time"]})
            s["commits"] += 1
            s["additions"] += a or 0
            s["deletions"] += d or 0
            s["first"] = min(s["first"], c["time"])
            s["last"] = max(s["last"], c["time"])
        ids = sorted(set(ids))
        if len(ids) <= max_files:
            for p in ids:
                stats[p]["coupling"] += 1
            for i, a in enumerate(ids):
                for b in ids[i + 1:]:
                    entry = pairs.setdefault((a, b), [0, 0])
                    entry[0] += 1
                    entry[1] = max(entry[1], c["time"])
    for p, s in stats.items():
        conn.execute("INSERT INTO path_stats (path_id, commits, coupling_commits, additions, deletions, first_time, last_time) "
                     "VALUES (?, ?, ?, ?, ?, ?, ?)", (p, s["commits"], s["coupling"], s["additions"], s["deletions"], s["first"], s["last"]))
    for (a, b), (count, last) in pairs.items():
        conn.execute("INSERT INTO cochange (a, b, commits, last_time) VALUES (?, ?, ?, ?)", (a, b, count, last))
    conn.commit()
    conn.close()
    return db_path


class _LoopbackServer(ThreadingHTTPServer):
    daemon_threads = True

    def server_bind(self):
        # Skip HTTPServer's reverse DNS lookup of the bound name; it can stall on some machines.
        TCPServer.server_bind(self)
        self.server_name = "127.0.0.1"
        self.server_port = self.server_address[1]


class MockServer:
    """A loopback HTTP server. `respond(method, path, headers, body)` returns (status, headers, payload);
    payload is bytes, str or a list of str chunks (written one by one, for SSE streams)."""

    def __init__(self, respond):
        self.respond = respond
        self.requests = []
        outer = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args):
                pass

            def _handle(self, method):
                length = int(self.headers.get("content-length") or 0)
                raw = self.rfile.read(length) if length else b""
                try:
                    body = json.loads(raw.decode("utf-8")) if raw else None
                except ValueError:
                    body = raw.decode("utf-8", "replace")
                headers = {k.lower(): v for k, v in self.headers.items()}
                outer.requests.append({"method": method, "path": self.path, "headers": headers, "body": body, "raw": raw})
                status, extra, payload = outer.respond(method, self.path, headers, body)
                chunks = payload if isinstance(payload, list) else [payload]
                chunks = [c.encode("utf-8") if isinstance(c, str) else c for c in chunks]
                self.send_response(status)
                for key, value in (extra or {}).items():
                    self.send_header(key, value)
                self.send_header("content-length", str(sum(len(c) for c in chunks)))
                self.send_header("connection", "close")
                self.end_headers()
                for chunk in chunks:
                    self.wfile.write(chunk)
                    self.wfile.flush()
                self.close_connection = True

            def do_POST(self):
                self._handle("POST")

            def do_GET(self):
                self._handle("GET")

        self.server = _LoopbackServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    @property
    def url(self):
        return f"http://127.0.0.1:{self.server.server_address[1]}"

    def close(self):
        self.server.shutdown()
        self.server.server_close()


def anthropic_stream(text, stop_reason="end_turn", model="claude-opus-5-5", pieces=3):
    """A Messages API SSE stream: a thinking block, then the text in a few deltas."""
    events = [
        ("message_start", {"type": "message_start", "message": {"id": "msg_test", "type": "message", "role": "assistant",
                                                                 "model": model, "content": [], "usage": {"input_tokens": 12, "output_tokens": 1}}}),
        ("ping", {"type": "ping"}),
        ("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "thinking", "thinking": ""}}),
        ("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": ""}}),
        ("content_block_stop", {"type": "content_block_stop", "index": 0}),
        ("content_block_start", {"type": "content_block_start", "index": 1, "content_block": {"type": "text", "text": ""}}),
    ]
    size = max(1, len(text) // pieces + 1)
    for start in range(0, len(text), size):
        events.append(("content_block_delta", {"type": "content_block_delta", "index": 1,
                                               "delta": {"type": "text_delta", "text": text[start:start + size]}}))
    events += [
        ("content_block_stop", {"type": "content_block_stop", "index": 1}),
        ("message_delta", {"type": "message_delta", "delta": {"stop_reason": stop_reason}, "usage": {"output_tokens": 42}}),
        ("message_stop", {"type": "message_stop"}),
    ]
    return [f"event: {name}\ndata: {json.dumps(data)}\n\n" for name, data in events]


def run_cli(*argv):
    """Run the CLI in this process; returns (exit code, stdout, stderr)."""
    from gitrochi import cli
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = cli.main([str(a) for a in argv])
    return code, out.getvalue(), err.getvalue()


def free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def wait_for(predicate, timeout=10.0, interval=0.05):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(interval)
    return predicate()


def write_script(path, text):
    """An executable Python script with this interpreter in its shebang (fake tools for tests)."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"#!{sys.executable}\n" + text, encoding="utf-8")
    path.chmod(0o755)
    return path
