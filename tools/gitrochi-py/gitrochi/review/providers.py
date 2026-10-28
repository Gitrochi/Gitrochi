"""AI providers over plain HTTPS (standard library only), mirroring the request shapes of macos/Sources/Services/AI.swift.

- anthropic: Messages API (`/v1/messages`), streamed, with server-side refusal fallbacks like the app.
- openai / compatible: `/chat/completions` (Ollama, LM Studio, OpenRouter and the like for `compatible`).
- gemini: `generateContent`.
Errors never contain the API key: messages are built from the status and a redacted excerpt of the reply.
"""

from __future__ import annotations

import json
import random
import socket
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, Iterator, List, Optional, Tuple

from gitrochi import redact

PROVIDERS = ("anthropic", "openai", "compatible", "gemini")
DEFAULT_MODELS = {"anthropic": "claude-opus-5-5", "openai": "gpt-5", "gemini": "gemini-2.5-flash", "compatible": ""}
DEFAULT_BASE_URLS = {
    "anthropic": "https://api.anthropic.com",
    "openai": "https://api.openai.com/v1",
    "compatible": "http://localhost:11434/v1",
    "gemini": "https://generativelanguage.googleapis.com/v1beta",
}
ANTHROPIC_VERSION = "2026-10-21"
FALLBACK_BETA = "server-side-fallback-2026-07-01"
FALLBACK_MODELS = ("claude-fable-5", "claude-mythos-5", "claude-opus-5", "claude-sonnet-5-5")
RETRY_STATUS = {408, 409, 425, 429, 500, 502, 503, 504, 529}
USER_AGENT = "gitrochi-py"


class ProviderError(Exception):
    def __init__(self, message: str, status: Optional[int] = None, retryable: bool = False, refused: bool = False,
                 retry_after: Optional[float] = None):
        super().__init__(message)
        self.message = message
        self.status = status
        self.retryable = retryable
        self.refused = refused
        self.retry_after = retry_after


@dataclass
class Completion:
    text: str
    model: str
    stop_reason: Optional[str] = None
    usage: Dict[str, Any] = field(default_factory=dict)
    attempts: int = 1


@dataclass
class HttpResponse:
    status: int
    headers: Dict[str, str]
    body: bytes = b""
    stream: Any = None  # an open response for streaming reads


def _is_loopback(url: str) -> bool:
    host = (urllib.parse.urlsplit(url).hostname or "").lower()
    return host in ("localhost", "127.0.0.1", "::1") or host.endswith(".localhost")


class Transport:
    """urllib with a timeout per socket operation; loopback servers bypass any configured proxy."""

    def __init__(self, timeout: float = 300):
        self.timeout = timeout

    def _opener(self, url: str) -> urllib.request.OpenerDirector:
        handlers: List[Any] = [_NoRedirect()]
        if _is_loopback(url):
            handlers.append(urllib.request.ProxyHandler({}))
        return urllib.request.build_opener(*handlers)

    def post(self, url: str, headers: Dict[str, str], body: Dict[str, Any], stream: bool = False) -> HttpResponse:
        data = json.dumps(body).encode("utf-8")
        request = urllib.request.Request(url, data=data, method="POST")
        request.add_header("content-type", "application/json")
        request.add_header("user-agent", USER_AGENT)
        for key, value in headers.items():
            request.add_header(key, value)
        try:
            response = self._opener(url).open(request, timeout=self.timeout)
        except urllib.error.HTTPError as exc:
            payload = b""
            try:
                payload = exc.read()
            except Exception:
                pass
            return HttpResponse(exc.code, {k.lower(): v for k, v in (exc.headers or {}).items()}, payload)
        except (urllib.error.URLError, socket.timeout, ConnectionError, ssl.SSLError, OSError) as exc:
            reason = getattr(exc, "reason", exc)
            raise ProviderError(f"cannot reach {urllib.parse.urlsplit(url).netloc}: {reason}", retryable=True)
        head = {k.lower(): v for k, v in response.headers.items()}
        if stream:
            return HttpResponse(response.status, head, b"", response)
        try:
            payload = response.read()
        except (socket.timeout, OSError) as exc:
            raise ProviderError(f"reading the response failed: {exc}", retryable=True)
        finally:
            response.close()
        return HttpResponse(response.status, head, payload)


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    # An API key must never follow a redirect to another host.
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: D401
        return None


def _retry_after(headers: Dict[str, str]) -> Optional[float]:
    value = headers.get("retry-after")
    if not value:
        return None
    try:
        return max(0.0, float(value))
    except ValueError:
        return None


def _error_message(who: str, status: int, body: bytes, secrets: List[Optional[str]]) -> str:
    text = body.decode("utf-8", "replace")
    message = ""
    try:
        doc = json.loads(text)
        if isinstance(doc, list) and doc:
            doc = doc[0]
        err = doc.get("error") if isinstance(doc, dict) else None
        if isinstance(err, dict):
            message = str(err.get("message") or err.get("type") or "")
        elif isinstance(err, str):
            message = err
    except ValueError:
        message = text[:300]
    message = redact.mask(message.strip()[:500], secrets)
    hint = {401: "the API key is invalid", 403: "the API key lacks permission", 404: "model or address not found",
            429: "usage limit reached"}.get(status)
    parts = [f"{who} request failed (HTTP {status})"]
    if hint:
        parts.append(hint)
    if message:
        parts.append(message)
    return ": ".join(parts[:1]) + (" - " + "; ".join(parts[1:]) if len(parts) > 1 else "")


class Provider:
    name = "provider"
    label = "AI"

    def __init__(self, model: str, key: Optional[str], base_url: Optional[str] = None, timeout: float = 300,
                 retries: int = 3, backoff: float = 1.0, max_backoff: float = 30.0, effort: str = "high",
                 transport: Optional[Transport] = None, sleep: Callable[[float], None] = time.sleep,
                 max_tokens: Optional[int] = None):
        self.model = model
        self.key = key
        self.base_url = (base_url or DEFAULT_BASE_URLS.get(self.name, "")).rstrip("/")
        self.timeout = timeout
        self.retries = max(0, retries)
        self.backoff = backoff
        self.max_backoff = max_backoff
        self.effort = effort
        self.transport = transport or Transport(timeout)
        self.sleep = sleep
        self.max_tokens = max_tokens

    def complete(self, system: str, prompt: str) -> Completion:
        attempt = 0
        while True:
            attempt += 1
            try:
                result = self._complete_once(system, prompt)
                result.attempts = attempt
                return result
            except ProviderError as exc:
                if not exc.retryable or attempt > self.retries:
                    raise
                delay = exc.retry_after if exc.retry_after is not None else self.backoff * (2 ** (attempt - 1))
                delay = min(self.max_backoff, delay) * (1.0 if exc.retry_after is not None else random.uniform(0.75, 1.25))
                self.sleep(delay)

    def _complete_once(self, system: str, prompt: str) -> Completion:  # pragma: no cover - interface
        raise NotImplementedError

    def _check(self, response: HttpResponse) -> None:
        if 200 <= response.status < 300:
            return
        body = response.body
        if response.stream is not None:
            try:
                body = response.stream.read()
            finally:
                response.stream.close()
        raise ProviderError(_error_message(self.label, response.status, body, [self.key]), status=response.status,
                            retryable=response.status in RETRY_STATUS, retry_after=_retry_after(response.headers))

    def _json(self, response: HttpResponse) -> Dict[str, Any]:
        try:
            doc = json.loads(response.body.decode("utf-8", "replace"))
        except ValueError:
            raise ProviderError(f"{self.label} returned a reply that is not JSON", retryable=True)
        if not isinstance(doc, dict):
            raise ProviderError(f"{self.label} returned an unexpected reply", retryable=False)
        return doc


def _supports_adaptive_thinking(model: str) -> bool:
    lowered = model.lower()
    old = ("claude-3", "claude-2", "claude-instant", "-4-0", "-4-1", "-4-5", "opus-4-2", "sonnet-4-2", "claude-haiku-4", "claude-sonnet-4-2")
    return lowered.startswith("claude") and not any(marker in lowered for marker in old)


class AnthropicProvider(Provider):
    name = "anthropic"
    label = "Claude"

    def request_body(self, system: str, prompt: str) -> Tuple[Dict[str, str], Dict[str, Any]]:
        headers = {"x-api-key": self.key or "", "anthropic-version": ANTHROPIC_VERSION, "accept": "text/event-stream"}
        body: Dict[str, Any] = {
            "model": self.model,
            "max_tokens": self.max_tokens or 64000,
            "system": system,
            "messages": [{"role": "user", "content": prompt}],
            "stream": True,
        }
        if _supports_adaptive_thinking(self.model):
            body["thinking"] = {"type": "adaptive"}
            body["output_config"] = {"effort": self.effort}
        # Like the app: a request the safety classifier declines is retried server-side on the recommended model.
        # The "default" form is documented for these model lines only (Haiku has no server-side fallback).
        if self.model.lower().startswith(FALLBACK_MODELS):
            body["fallbacks"] = "default"
            headers["anthropic-beta"] = FALLBACK_BETA
        return headers, body

    def _complete_once(self, system: str, prompt: str) -> Completion:
        if not self.key:
            raise ProviderError("no Anthropic API key (set ANTHROPIC_API_KEY or save one in Gitrochi's Settings > AI)")
        headers, body = self.request_body(system, prompt)
        response = self.transport.post(self.base_url + "/v1/messages", headers, body, stream=True)
        self._check(response)
        return self._read_stream(response)

    def _read_stream(self, response: HttpResponse) -> Completion:
        texts: Dict[int, List[str]] = {}
        stop_reason: Optional[str] = None
        model = self.model
        usage: Dict[str, Any] = {}
        event = ""
        data_lines: List[str] = []
        stream = response.stream
        try:
            for raw in _lines(stream):
                if raw == "":
                    if data_lines:
                        stop_reason, model = self._event(event, "\n".join(data_lines), texts, usage, stop_reason, model)
                    event, data_lines = "", []
                    continue
                if raw.startswith(":"):
                    continue
                if raw.startswith("event:"):
                    event = raw[6:].strip()
                elif raw.startswith("data:"):
                    data_lines.append(raw[5:].lstrip())
            if data_lines:
                stop_reason, model = self._event(event, "\n".join(data_lines), texts, usage, stop_reason, model)
        except (socket.timeout, OSError) as exc:
            raise ProviderError(f"Claude stream interrupted: {exc}", retryable=True)
        finally:
            try:
                stream.close()
            except Exception:
                pass
        if stop_reason == "refusal":
            raise ProviderError("Claude declined this request", refused=True)
        text = "".join("".join(texts[i]) for i in sorted(texts)).strip()
        if not text:
            raise ProviderError("Claude returned an empty response", retryable=stop_reason is None)
        return Completion(text, model, stop_reason, usage)

    def _event(self, event: str, data: str, texts: Dict[int, List[str]], usage: Dict[str, Any],
               stop_reason: Optional[str], model: str) -> Tuple[Optional[str], str]:
        try:
            doc = json.loads(data)
        except ValueError:
            return stop_reason, model
        kind = doc.get("type") or event
        if kind == "message_start":
            message = doc.get("message") or {}
            model = message.get("model") or model
            usage.update(message.get("usage") or {})
        elif kind == "content_block_start":
            block = doc.get("content_block") or {}
            if block.get("type") == "text" and block.get("text"):
                texts.setdefault(int(doc.get("index", 0)), []).append(block["text"])
        elif kind == "content_block_delta":
            delta = doc.get("delta") or {}
            if delta.get("type") == "text_delta":
                texts.setdefault(int(doc.get("index", 0)), []).append(delta.get("text") or "")
        elif kind == "message_delta":
            delta = doc.get("delta") or {}
            stop_reason = delta.get("stop_reason") or stop_reason
            usage.update(doc.get("usage") or {})
        elif kind == "error":
            err = doc.get("error") or {}
            err_type = str(err.get("type") or "")
            message = redact.mask(str(err.get("message") or err_type or "stream error"), [self.key])
            raise ProviderError(f"Claude stream error: {message}",
                                retryable=err_type in ("overloaded_error", "api_error", "rate_limit_error", "timeout_error"))
        return stop_reason, model


def _lines(stream: Any) -> Iterator[str]:
    while True:
        raw = stream.readline()
        if not raw:
            return
        yield raw.decode("utf-8", "replace").rstrip("\r\n")


class ChatCompletionsProvider(Provider):
    name = "openai"
    label = "ChatGPT"

    def __init__(self, *args: Any, name: str = "openai", **kwargs: Any):
        self.name = name
        self.label = "ChatGPT" if name == "openai" else "AI server"
        super().__init__(*args, **kwargs)

    def _complete_once(self, system: str, prompt: str) -> Completion:
        if not self.model:
            raise ProviderError(f"{self.label}: choose a model with --model")
        if self.name == "openai" and not self.key:
            raise ProviderError("no OpenAI API key (set OPENAI_API_KEY or save one in Gitrochi's Settings > AI)")
        headers = {"authorization": f"Bearer {self.key}"} if self.key else {}
        body: Dict[str, Any] = {"model": self.model, "messages": [{"role": "system", "content": system}, {"role": "user", "content": prompt}]}
        if self.max_tokens:
            body["max_tokens"] = self.max_tokens
        response = self.transport.post(self.base_url + "/chat/completions", headers, body)
        self._check(response)
        doc = self._json(response)
        choices = doc.get("choices") or []
        message = (choices[0] or {}).get("message") if choices and isinstance(choices[0], dict) else None
        message = message or {}
        if message.get("refusal"):
            raise ProviderError(f"{self.label} declined this request", refused=True)
        content = message.get("content")
        if isinstance(content, list):
            content = "".join(part.get("text", "") for part in content if isinstance(part, dict))
        text = (content or "").strip()
        if not text:
            raise ProviderError(f"{self.label} returned an empty response", retryable=True)
        finish = (choices[0] or {}).get("finish_reason") if choices else None
        return Completion(text, doc.get("model") or self.model, finish, doc.get("usage") or {})


class GeminiProvider(Provider):
    name = "gemini"
    label = "Gemini"

    def _complete_once(self, system: str, prompt: str) -> Completion:
        if not self.key:
            raise ProviderError("no Gemini API key (set GEMINI_API_KEY or save one in Gitrochi's Settings > AI)")
        body: Dict[str, Any] = {
            "systemInstruction": {"parts": [{"text": system}]},
            "contents": [{"role": "user", "parts": [{"text": prompt}]}],
            "generationConfig": {"responseMimeType": "application/json"},
        }
        if self.max_tokens:
            body["generationConfig"]["maxOutputTokens"] = self.max_tokens
        model = urllib.parse.quote(self.model, safe="")
        response = self.transport.post(f"{self.base_url}/models/{model}:generateContent", {"x-goog-api-key": self.key}, body)
        self._check(response)
        doc = self._json(response)
        if (doc.get("promptFeedback") or {}).get("blockReason"):
            raise ProviderError("Gemini declined this request", refused=True)
        candidates = doc.get("candidates") or []
        candidate = candidates[0] if candidates and isinstance(candidates[0], dict) else {}
        parts = ((candidate.get("content") or {}).get("parts")) or []
        text = "".join(p.get("text", "") for p in parts if isinstance(p, dict)).strip()
        if not text:
            if candidate.get("finishReason") == "SAFETY":
                raise ProviderError("Gemini declined this request", refused=True)
            raise ProviderError("Gemini returned an empty response", retryable=True)
        return Completion(text, self.model, candidate.get("finishReason"), doc.get("usageMetadata") or {})


def make(name: str, model: Optional[str], key: Optional[str], base_url: Optional[str] = None, **kwargs: Any) -> Provider:
    if name not in PROVIDERS:
        raise ValueError(f"unknown provider {name!r} (choose {', '.join(PROVIDERS)})")
    chosen = model or DEFAULT_MODELS.get(name, "")
    if name == "anthropic":
        return AnthropicProvider(chosen, key, base_url, **kwargs)
    if name == "gemini":
        return GeminiProvider(chosen, key, base_url, **kwargs)
    provider = ChatCompletionsProvider(chosen, key, base_url or DEFAULT_BASE_URLS[name], name=name, **kwargs)
    return provider
