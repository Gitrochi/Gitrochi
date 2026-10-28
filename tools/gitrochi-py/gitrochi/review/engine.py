"""Run the AI part of a review: chunks in parallel (bounded), then one synthesis call."""

from __future__ import annotations

import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Sequence, Tuple

from gitrochi import redact
from gitrochi.review import prompts
from gitrochi.review.findings import FileIndex, Finding, extract_json, normalize_severity, validate
from gitrochi.review.providers import Provider, ProviderError

VERDICTS = ("approve", "comment", "request_changes")


@dataclass
class ChunkResult:
    index: int
    paths: List[str]
    findings: List[Finding] = field(default_factory=list)
    error: Optional[str] = None
    refused: bool = False
    repaired: bool = False
    dropped: int = 0
    redactions: int = 0
    attempts: int = 0
    seconds: float = 0.0
    stop_reason: Optional[str] = None


@dataclass
class AIResult:
    provider: str
    model: str
    chunks: List[ChunkResult]
    findings: List[Finding]
    summary: Optional[str] = None
    verdict: Optional[str] = None
    synthesis: str = "skipped"
    synthesis_error: Optional[str] = None

    @property
    def failed_chunks(self) -> int:
        return sum(1 for c in self.chunks if c.error)

    @property
    def all_failed(self) -> bool:
        return bool(self.chunks) and self.failed_chunks == len(self.chunks)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "enabled": True, "provider": self.provider, "model": self.model, "chunks": len(self.chunks),
            "failedChunks": self.failed_chunks, "synthesis": self.synthesis,
            "redactions": sum(c.redactions for c in self.chunks),
            "droppedFindings": sum(c.dropped for c in self.chunks),
            "errors": [{"chunk": c.index, "paths": c.paths, "message": c.error, "refused": c.refused} for c in self.chunks if c.error]
                      + ([{"chunk": None, "paths": [], "message": self.synthesis_error, "refused": False}] if self.synthesis_error else []),
            "parts": [{"chunk": c.index, "paths": c.paths, "findings": len(c.findings), "attempts": c.attempts,
                       "seconds": round(c.seconds, 2), "repaired": c.repaired, "stopReason": c.stop_reason} for c in self.chunks],
        }


class Engine:
    def __init__(self, provider: Provider, jobs: int = 4, rules: Sequence[str] = (), secrets: Sequence[str] = ()):
        self.provider = provider
        self.jobs = max(1, jobs)
        self.rules = list(rules)
        self.secrets = [s for s in secrets if s]

    def review(self, chunks: Sequence[prompts.Chunk], files: FileIndex, notes_for: Any,
               change: Dict[str, Any], local: Sequence[Finding]) -> AIResult:
        system = prompts.with_rules(prompts.REVIEW_SYSTEM, self.rules)
        total = len(chunks)

        def one(chunk: prompts.Chunk) -> ChunkResult:
            result = ChunkResult(chunk.index, chunk.paths)
            started = time.monotonic()
            prompt, result.redactions = prompts.chunk_prompt(chunk, total, notes_for(chunk.paths), self.secrets)
            try:
                completion = self.provider.complete(system, prompt)
                result.attempts = completion.attempts
                result.stop_reason = completion.stop_reason
                parsed, result.repaired = extract_json(completion.text)
                result.findings, result.dropped = validate(parsed, files, "ai", allowed_files=chunk.paths)
            except ProviderError as exc:
                result.error = redact.mask(exc.message, self.secrets)
                result.refused = exc.refused
            except ValueError as exc:
                result.error = f"the model's reply was not usable JSON ({exc})"
            except Exception as exc:  # one broken chunk must not lose the others
                result.error = redact.mask(f"{type(exc).__name__}: {exc}", self.secrets)
            result.seconds = time.monotonic() - started
            return result

        with ThreadPoolExecutor(max_workers=min(self.jobs, max(1, total))) as pool:
            results = list(pool.map(one, chunks))
        findings = [f for r in results for f in r.findings]
        outcome = AIResult(self.provider.name, self.provider.model, results, findings)
        if results and not outcome.all_failed:
            self._synthesize(outcome, change, local)
        return outcome

    def _synthesize(self, outcome: AIResult, change: Dict[str, Any], local: Sequence[Finding]) -> None:
        for index, f in enumerate(outcome.findings, start=1):
            f.id = f"A{index}"
        local_dicts = []
        for index, f in enumerate(local, start=1):
            item = f.to_dict()
            item["id"] = f"L{index}"
            local_dicts.append(item)
        prompt = prompts.synthesis_prompt(change, [f.to_dict() for f in outcome.findings], local_dicts, self.secrets)
        system = prompts.with_rules(prompts.SYNTHESIS_SYSTEM, self.rules)
        try:
            completion = self.provider.complete(system, prompt)
            parsed, _ = extract_json(completion.text)
        except ProviderError as exc:
            outcome.synthesis = "failed"
            outcome.synthesis_error = redact.mask(exc.message, self.secrets)
            return
        except ValueError as exc:
            outcome.synthesis = "failed"
            outcome.synthesis_error = f"the synthesis reply was not usable JSON ({exc})"
            return
        if not isinstance(parsed, dict):
            outcome.synthesis = "failed"
            outcome.synthesis_error = "the synthesis reply was not a JSON object"
            return
        summary = parsed.get("summary")
        if isinstance(summary, str) and summary.strip():
            outcome.summary = redact.mask(summary.strip()[:2000], self.secrets)
        verdict = str(parsed.get("verdict") or "").strip().lower().replace(" ", "_").replace("-", "_")
        outcome.verdict = verdict if verdict in VERDICTS else None
        keep = parsed.get("keep")
        if isinstance(keep, list):
            by_id = {f.id: f for f in outcome.findings}
            kept: List[Finding] = []
            for item in keep:
                ident = item.get("id") if isinstance(item, dict) else item
                finding = by_id.pop(str(ident), None) if ident is not None else None
                if finding is None:
                    continue
                if isinstance(item, dict) and item.get("severity"):
                    finding.severity = normalize_severity(item.get("severity"), finding.severity)
                kept.append(finding)
            outcome.findings = kept
        outcome.synthesis = "ok"


def fallback_summary(files: int, additions: int, deletions: int, counts: Dict[str, int]) -> Tuple[str, str]:
    """A summary and verdict without AI, from the numbers alone."""
    verdict = "request_changes" if counts.get("error") else ("comment" if counts.get("warning") else "approve")
    def n(count: int, word: str) -> str:
        return f"{count} {word}{'' if count == 1 else 's'}"
    text = (f"{n(files, 'file')} changed (+{additions} -{deletions}); {n(counts.get('error', 0), 'error')}, "
            f"{n(counts.get('warning', 0), 'warning')}, {n(counts.get('info', 0), 'note')}.")
    return text, verdict
