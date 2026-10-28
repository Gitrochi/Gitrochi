"""review with AI providers, against loopback mock servers only (no real network, no real keys)."""

import json
import os
import unittest

from testkit import DAY, NOW, MockServer, Repo, Sandbox, anthropic_stream, build_index, run_cli

from gitrochi import config, credentials
from gitrochi.review import providers
from gitrochi.util import Failure

FAKE_KEY = "sk-ant-test-" + "k" * 32
# AWS's documented example key, split so the repository's secret check does not flag it.
PLANTED = "AKIA" + "IOSFODNN7EXAMPLE"


def review_reply(findings):
    return "Here is my review.\n```json\n" + json.dumps({"findings": findings}) + "\n```"


class AnthropicReviewTests(unittest.TestCase):
    def setUp(self):
        self.sb = Sandbox()
        os.environ["ANTHROPIC_API_KEY"] = FAKE_KEY
        self.repo = Repo(self.sb.path("repo"))
        self.repo.write("src/calc.py", "def add(a, b):\n    return a + b\n")
        self.repo.write("src/units.py", "UNIT = 1\n")
        self.repo.commit("Add calc", when=NOW - 20 * DAY)
        self.repo.git("checkout", "-q", "-b", "feature")
        self.repo.write("src/calc.py", "def add(a, b):\n    return a + b\ndef div(a, b):\n    return a / b\n")
        self.repo.write("src/settings.py", f"AWS_ACCESS_KEY_ID = \"{PLANTED}\"\n")
        self.repo.commit("Add div")
        build_index(self.repo.common_dir() / "gitrochi" / "index.sqlite3", [
            {"author": ("Dev A", "dev-a@example.com"), "time": NOW - (60 - i) * DAY,
             "files": [("src/calc.py", "M", 2, 1), ("src/units.py", "M", 1, 1)]} for i in range(3)])
        self.server = None

    def tearDown(self):
        if self.server:
            self.server.close()
        self.sb.close()

    def _serve(self, synth_status=200, chunk_status=200):
        def respond(method, path, headers, body):
            system = body.get("system", "")
            if system.startswith("You are the lead reviewer"):
                if synth_status != 200:
                    return synth_status, {"content-type": "application/json"}, json.dumps({"error": {"type": "api_error", "message": "boom"}})
                payload = json.loads(body["messages"][0]["content"])
                first = payload["aiFindings"][0]["id"]
                text = json.dumps({"summary": "Adds a division helper without a zero check.", "verdict": "request_changes",
                                   "keep": [{"id": first, "severity": "error"}]})
                return 200, {"content-type": "text/event-stream"}, anthropic_stream(text)
            if chunk_status != 200:
                return chunk_status, {"content-type": "application/json"}, json.dumps(
                    {"type": "error", "error": {"type": "authentication_error", "message": f"invalid x-api-key {headers.get('x-api-key')}"}})
            return 200, {"content-type": "text/event-stream"}, anthropic_stream(review_reply([
                {"file": "src/calc.py", "line": 4, "severity": "high", "category": "bug",
                 "message": "Division by zero is not handled.", "suggestion": "Raise a clear error when b == 0."},
                {"file": "src/calc.py", "line": 3, "severity": "nit", "category": "style", "message": "Missing docstring."},
            ]))
        self.server = MockServer(respond)
        return self.server

    def _run(self, *extra):
        code, out, err = run_cli("review", "--json", "--repo", self.repo.path, "--base-url", self.server.url, *extra)
        self.assertNotIn("Traceback", err)
        return code, json.loads(out)

    def test_request_shape_redaction_context_and_synthesis(self):
        self._serve()
        code, doc = self._run()
        self.assertEqual(code, 1)
        requests = self.server.requests
        self.assertEqual(len(requests), 2, "one chunk review and one synthesis")
        chunk = requests[0]
        self.assertEqual(chunk["path"], "/v1/messages")
        self.assertEqual(chunk["headers"]["x-api-key"], FAKE_KEY)
        self.assertEqual(chunk["headers"]["anthropic-version"], providers.ANTHROPIC_VERSION)
        self.assertEqual(chunk["headers"]["anthropic-beta"], "server-side-fallback-2026-07-01")
        body = chunk["body"]
        self.assertEqual(body["model"], "claude-opus-5-5")
        self.assertTrue(body["stream"])
        self.assertEqual(body["thinking"], {"type": "adaptive"})
        self.assertEqual(body["output_config"], {"effort": "high"})
        self.assertEqual(body["fallbacks"], "default")
        self.assertEqual(body["messages"][0]["role"], "user")
        prompt = body["messages"][0]["content"]
        self.assertIn("usually changes together with src/units.py", prompt)
        self.assertIn("Dev A", prompt)
        self.assertIn("     4 +     return a / b", prompt)
        for request in requests:
            self.assertNotIn(PLANTED.encode(), request["raw"], "secrets must be redacted before sending")
            self.assertNotIn(b"dev-a@example.com", request["raw"], "author emails are not sent")
            self.assertNotIn(FAKE_KEY.encode(), request["raw"])
        self.assertIn("[REDACTED:", prompt)
        ai = [f for f in doc["findings"] if f["source"] == "ai"]
        self.assertEqual([(f["file"], f["line"], f["severity"]) for f in ai], [("src/calc.py", 4, "error")],
                         "synthesis keeps only the first finding")
        self.assertEqual(doc["summary"], "Adds a division helper without a zero check.")
        self.assertEqual(doc["verdict"], "request_changes")
        self.assertEqual(doc["ai"]["synthesis"], "ok")
        self.assertGreaterEqual(doc["ai"]["redactions"], 1)
        self.assertTrue(any(f["rule"] == "secret-added" for f in doc["findings"]))
        self.assertTrue(any(f["rule"] == "cochange-missing" for f in doc["findings"]))

    def test_synthesis_failure_keeps_chunk_findings(self):
        self._serve(synth_status=500)
        code, doc = self._run("--retries", "0", "--fail-on", "never")
        self.assertEqual(code, 0)
        self.assertEqual(doc["ai"]["synthesis"], "failed")
        self.assertEqual(len([f for f in doc["findings"] if f["source"] == "ai"]), 2)

    def test_auth_failure_fails_without_leaking_the_key(self):
        self._serve(chunk_status=401)
        code, doc = self._run("--retries", "0")
        self.assertEqual(code, 1)
        reasons = " ".join(doc["failReasons"])
        self.assertIn("AI review failed", reasons)
        self.assertIn("HTTP 401", reasons)
        self.assertNotIn(FAKE_KEY, json.dumps(doc))
        self.assertTrue(any(f["source"] == "local" for f in doc["findings"]), "local checks still report")

    def test_missing_key_is_a_clear_failure(self):
        os.environ.pop("ANTHROPIC_API_KEY")
        self._serve()
        code, doc = self._run()
        self.assertEqual(code, 1)
        self.assertIn("no Anthropic API key", " ".join(doc["failReasons"]))
        self.assertEqual(self.server.requests, [])


class OtherProviderTests(unittest.TestCase):
    def setUp(self):
        self.sb = Sandbox()
        self.repo = Repo(self.sb.path("repo"))
        self.repo.write("main.go", "package main\n")
        self.repo.commit("Init")
        self.repo.git("checkout", "-q", "-b", "feature")
        self.repo.write("main.go", "package main\n\nfunc main() { panic(nil) }\n")
        self.repo.commit("Panic")
        self.server = None

    def tearDown(self):
        if self.server:
            self.server.close()
        self.sb.close()

    def test_compatible_chat_completions_without_key(self):
        reply = review_reply([{"file": "main.go", "line": 3, "severity": "warning", "category": "bug", "message": "panic(nil) panics."}])

        def respond(method, path, headers, body):
            content = reply if not body["messages"][0]["content"].startswith("You are the lead reviewer") else json.dumps({"summary": "ok"})
            return 200, {"content-type": "application/json"}, json.dumps({"model": body["model"], "choices": [{"message": {"content": content}}]})
        self.server = MockServer(respond)
        code, out, _ = run_cli("review", "--json", "--repo", self.repo.path, "--provider", "compatible", "--model", "qwen2.5-coder",
                               "--base-url", self.server.url + "/v1")
        doc = json.loads(out)
        self.assertEqual(code, 0)
        first = self.server.requests[0]
        self.assertEqual(first["path"], "/v1/chat/completions")
        self.assertNotIn("authorization", first["headers"])
        self.assertEqual([m["role"] for m in first["body"]["messages"]], ["system", "user"])
        self.assertEqual([(f["file"], f["line"]) for f in doc["findings"] if f["source"] == "ai"], [("main.go", 3)])

    def test_gemini_generate_content(self):
        os.environ["GEMINI_API_KEY"] = "gemini-test-key-0000"

        def respond(method, path, headers, body):
            text = json.dumps({"findings": []}) if "lead reviewer" not in body["systemInstruction"]["parts"][0]["text"] else json.dumps({"summary": "Fine."})
            return 200, {"content-type": "application/json"}, json.dumps({"candidates": [{"content": {"parts": [{"text": text}]}, "finishReason": "STOP"}]})
        self.server = MockServer(respond)
        code, out, _ = run_cli("review", "--json", "--repo", self.repo.path, "--provider", "gemini", "--base-url", self.server.url)
        doc = json.loads(out)
        self.assertEqual(code, 0)
        first = self.server.requests[0]
        self.assertEqual(first["path"], "/models/gemini-2.5-flash:generateContent")
        self.assertEqual(first["headers"]["x-goog-api-key"], "gemini-test-key-0000")
        self.assertEqual(first["body"]["contents"][0]["role"], "user")
        self.assertEqual(doc["summary"], "Fine.")


class ProviderUnitTests(unittest.TestCase):
    def setUp(self):
        self.sb = Sandbox()
        self.server = None

    def tearDown(self):
        if self.server:
            self.server.close()
        self.sb.close()

    def test_retries_on_429_and_529_then_succeeds(self):
        replies = [(429, {"retry-after": "0"}, json.dumps({"error": {"message": "slow down"}})),
                   (529, {}, json.dumps({"error": {"message": "overloaded"}}))]

        def respond(method, path, headers, body):
            if replies:
                status, extra, payload = replies.pop(0)
                return status, dict(extra, **{"content-type": "application/json"}), payload
            return 200, {"content-type": "text/event-stream"}, anthropic_stream('{"findings": []}')
        self.server = MockServer(respond)
        slept = []
        provider = providers.make("anthropic", None, FAKE_KEY, self.server.url, retries=3, backoff=0.01, sleep=slept.append)
        result = provider.complete("system", "prompt")
        self.assertEqual(result.text, '{"findings": []}')
        self.assertEqual(result.attempts, 3)
        self.assertEqual(len(slept), 2)
        self.assertEqual(slept[0], 0.0, "Retry-After is honoured")

    def test_gives_up_after_retries_and_does_not_retry_400(self):
        def respond(method, path, headers, body):
            return 503, {"content-type": "application/json"}, json.dumps({"error": {"message": "unavailable"}})
        self.server = MockServer(respond)
        provider = providers.make("anthropic", None, FAKE_KEY, self.server.url, retries=2, backoff=0.0, sleep=lambda s: None)
        with self.assertRaises(providers.ProviderError) as ctx:
            provider.complete("s", "p")
        self.assertEqual(ctx.exception.status, 503)
        self.assertEqual(len(self.server.requests), 3)
        self.server.close()
        self.server = MockServer(lambda m, p, h, b: (400, {"content-type": "application/json"}, json.dumps({"error": {"message": "bad"}})))
        provider = providers.make("anthropic", None, FAKE_KEY, self.server.url, retries=3, backoff=0.0, sleep=lambda s: None)
        with self.assertRaises(providers.ProviderError):
            provider.complete("s", "p")
        self.assertEqual(len(self.server.requests), 1)

    def test_refusal_and_stream_error(self):
        self.server = MockServer(lambda m, p, h, b: (200, {"content-type": "text/event-stream"}, anthropic_stream("", stop_reason="refusal")))
        provider = providers.make("anthropic", None, FAKE_KEY, self.server.url, retries=0)
        with self.assertRaises(providers.ProviderError) as ctx:
            provider.complete("s", "p")
        self.assertTrue(ctx.exception.refused)
        self.server.close()
        error_stream = ["event: error\ndata: " + json.dumps({"type": "error", "error": {"type": "overloaded_error", "message": "Overloaded"}}) + "\n\n"]
        self.server = MockServer(lambda m, p, h, b: (200, {"content-type": "text/event-stream"}, error_stream))
        provider = providers.make("anthropic", None, FAKE_KEY, self.server.url, retries=1, backoff=0.0, sleep=lambda s: None)
        with self.assertRaises(providers.ProviderError) as ctx:
            provider.complete("s", "p")
        self.assertTrue(ctx.exception.retryable)
        self.assertEqual(len(self.server.requests), 2)

    def test_older_and_haiku_models_skip_unsupported_fields(self):
        headers, body = providers.AnthropicProvider("claude-haiku-4-5", FAKE_KEY).request_body("s", "p")
        self.assertNotIn("thinking", body)
        self.assertNotIn("fallbacks", body)
        self.assertNotIn("anthropic-beta", headers)
        headers, body = providers.AnthropicProvider("claude-opus-5-5", FAKE_KEY, effort="max").request_body("s", "p")
        self.assertEqual(body["output_config"], {"effort": "max"})
        self.assertEqual(body["fallbacks"], "default")
        # An older Opus keeps adaptive thinking but gets no server-side fallback field.
        headers, body = providers.AnthropicProvider("claude-opus-4-8", FAKE_KEY).request_body("s", "p")
        self.assertEqual(body["thinking"], {"type": "adaptive"})
        self.assertNotIn("fallbacks", body)
        self.assertNotIn("anthropic-beta", headers)
        headers, body = providers.AnthropicProvider("claude-sonnet-5-5", FAKE_KEY).request_body("s", "p")
        self.assertEqual(body["fallbacks"], "default")
        # Sampling fields are refused on anthropic-version 2026-10-21.
        for field in ("temperature", "top_p", "top_k"):
            self.assertNotIn(field, body)
        self.assertEqual(headers["anthropic-version"], "2026-10-21")


class KeysAndConfigTests(unittest.TestCase):
    def setUp(self):
        self.sb = Sandbox()

    def tearDown(self):
        self.sb.close()

    def test_env_order_and_chain(self):
        store = credentials.EnvKeyStore({"GITROCHI_AI_KEY": "generic", "ANTHROPIC_API_KEY": "specific"})
        self.assertEqual(store.get("anthropic"), "specific")
        self.assertEqual(store.get("compatible"), "generic")

        class Fake(credentials.KeyStore):
            name = "fake store"

            def get(self, provider):
                return "from-store" if provider == "openai" else None
        chain = credentials.ChainKeyStore([credentials.EnvKeyStore({}), Fake()])
        self.assertEqual(chain.get("openai"), "from-store")
        self.assertEqual(chain.source, "fake store")
        self.assertIsNone(chain.get("gemini"))
        self.assertEqual([s.name for s in credentials.default_store().stores], ["environment"], "GITROCHI_NO_KEYCHAIN=1 skips OS stores")

    def test_credential_blob_decoding(self):
        self.assertEqual(credentials.decode_credential_blob("sk-test-1".encode("utf-16-le")), "sk-test-1")
        self.assertEqual(credentials.decode_credential_blob(b"abc"), "abc")
        self.assertIsNone(credentials.decode_credential_blob(b""))

    def test_config_rejects_secrets_and_repo_base_url(self):
        repo = Repo(self.sb.path("repo"))
        (repo.path / ".gitrochi").mkdir()
        (repo.path / ".gitrochi" / "gitrochi-py.json").write_text(json.dumps(
            {"review": {"provider": "compatible", "baseUrl": "http://attacker.example.com/v1", "model": "m"}}), encoding="utf-8")
        cfg = config.load(repo.path)
        self.assertEqual(cfg.get("review", "provider"), "compatible")
        self.assertIsNone(cfg.get("review", "baseUrl"), "a repository may not choose where keys are sent")
        self.assertTrue(cfg.notes)
        user = self.sb.path("user.json")
        user.write_text(json.dumps({"review": {"apiKey": "sk-should-not-be-here"}}), encoding="utf-8")
        with self.assertRaises(Failure) as ctx:
            config.load(repo.path, str(user))
        self.assertNotIn("sk-should-not-be-here", ctx.exception.message)


if __name__ == "__main__":
    unittest.main()
