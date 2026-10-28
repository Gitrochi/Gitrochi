"""`gitrochi-py review`: collect the change, run local checks, optionally the AI review, and report."""

from __future__ import annotations

import argparse
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

from gitrochi import config as configmod
from gitrochi import credentials, gitutil, redact
from gitrochi.index import Index
from gitrochi.review import checks, diff, engine, prompts, providers, report
from gitrochi.review.findings import SEVERITY_RANK, FileIndex, assign_ids, counts, dedupe, sort_findings
from gitrochi.util import UsageError, emit, envelope

EFFORTS = ("low", "medium", "high", "xhigh", "max")
FORMATS = ("text", "markdown", "json", "sarif")


def register(sub: Any, common: argparse.ArgumentParser, index_opts: argparse.ArgumentParser) -> None:
    p = sub.add_parser("review", parents=[common, index_opts], help="AI code review of a change",
                       description="Review a change: deterministic local checks always, an AI review unless --no-ai. "
                                   "Default change: merge-base with the default branch ... HEAD.")
    what = p.add_argument_group("what to review")
    what.add_argument("--base", help="base commit (default: merge-base with the default branch)")
    what.add_argument("--head", help="head commit (default: HEAD)")
    what.add_argument("--staged", action="store_true", help="review the staged changes")
    what.add_argument("--worktree", action="store_true", help="review all uncommitted changes, including untracked files")
    what.add_argument("--no-untracked", action="store_true", help="with --worktree, leave untracked files out")
    what.add_argument("--exclude", action="append", default=[], metavar="GLOB", help="leave matching files out of the AI review")
    what.add_argument("--context", type=int, default=3, metavar="N", help="unchanged lines around each change (default 3)")
    ai = p.add_argument_group("AI")
    ai.add_argument("--no-ai", action="store_true", help="run only the local checks")
    ai.add_argument("--provider", choices=providers.PROVIDERS, help="anthropic (default), openai, compatible or gemini")
    ai.add_argument("--model", help="model name (default: claude-opus-5-5 for anthropic)")
    ai.add_argument("--base-url", help="API address (compatible: default http://localhost:11434/v1)")
    ai.add_argument("--effort", choices=EFFORTS, help="Claude effort level (default high)")
    ai.add_argument("--jobs", type=int, help="parallel AI requests (default 4)")
    ai.add_argument("--timeout", type=float, help="seconds to wait on the AI server per read (default 300)")
    ai.add_argument("--retries", type=int, help="retries on 429/5xx and network errors (default 3)")
    ai.add_argument("--max-diff-bytes", type=int, help="total diff size sent to the AI (default 400000)")
    ai.add_argument("--max-chunk-bytes", type=int, help="diff size per AI request (default 48000)")
    ai.add_argument("--no-keychain", action="store_true", help="do not read the key from the Keychain / Credential Manager")
    out = p.add_argument_group("output")
    out.add_argument("--format", choices=FORMATS, help="text (default), markdown, json or sarif")
    out.add_argument("--fail-on", choices=("error", "warning", "never"), help="exit 1 when findings reach this severity (default error)")
    out.add_argument("--out", metavar="FILE", help="write the report to FILE")
    out.add_argument("--config", metavar="FILE", help="settings file (default: the user's gitrochi-py.json)")
    p.set_defaults(func=run)


def _int(value: Any, default: int, low: int = 1) -> int:
    try:
        return max(low, int(value))
    except (TypeError, ValueError):
        return default


def run(args: argparse.Namespace, keystore: Optional[credentials.KeyStore] = None,
        transport: Optional[providers.Transport] = None, sleep: Any = time.sleep) -> int:
    root = gitutil.repo_root(Path(args.repo))
    cfg = configmod.load(root, args.config)
    rc = cfg.section("review")
    fmt = "json" if args.json else (args.format or rc.get("format") or "text")
    if fmt not in FORMATS:
        raise UsageError(f"unknown format {fmt!r}")
    fail_on = args.fail_on or rc.get("failOn") or "error"
    excludes = list(rc.get("exclude") or []) + list(args.exclude or [])

    changes = diff.collect(root, args.base, args.head, args.staged, args.worktree,
                           include_untracked=not args.no_untracked, context=args.context)
    files = changes.files
    paths = [f.path for f in files]
    notes: List[str] = list(cfg.notes)
    if not files and changes.mode == "range" and gitutil.is_dirty(root):
        notes.append(f"no committed changes since {changes.base_ref}; use --worktree or --staged to review uncommitted work")

    index = Index(root, args.index_bin, args.index_db, enabled=not args.no_index)
    impact = index.impact(paths) if paths and index.enabled else None
    file_info: Dict[str, Optional[Dict[str, Any]]] = {}
    if index.enabled and paths:
        for path in [f.path for f in files if f.status != "A"][:50]:
            file_info[path] = index.file_info(path, limit=5)
    local = checks.run(files, impact)

    chunks, skipped = prompts.plan(files, _int(args.max_chunk_bytes or rc.get("maxChunkBytes"), 48_000, 4_000),
                                   _int(args.max_diff_bytes or rc.get("maxDiffBytes"), 400_000, 4_000), excludes)
    skipped_by_path = {s["path"]: s["reason"] for s in skipped}

    ai_doc: Dict[str, Any] = {"enabled": False}
    ai_failed: Optional[str] = None
    ai_result: Optional[engine.AIResult] = None
    use_ai = not args.no_ai and not rc.get("noAI", False)
    if use_ai and chunks:
        provider_name = args.provider or rc.get("provider") or "anthropic"
        if provider_name not in providers.PROVIDERS:
            raise UsageError(f"unknown provider {provider_name!r}")
        store = keystore or credentials.default_store(use_os_store=not args.no_keychain)
        key = store.get(provider_name)
        # Only the user (flag, environment, own settings file) chooses where a key is sent; see config.USER_ONLY.
        base_url = args.base_url or _env_base_url() or rc.get("baseUrl")
        provider = providers.make(
            provider_name, args.model or rc.get("model"), key, base_url,
            timeout=float(args.timeout or rc.get("timeout") or 300), retries=_int(args.retries if args.retries is not None else rc.get("retries"), 3, 0),
            effort=args.effort or rc.get("effort") or "high", transport=transport, sleep=sleep)
        rules = [str(r) for r in ([rc.get("instructions")] if isinstance(rc.get("instructions"), str) else rc.get("instructions") or [])]
        eng = engine.Engine(provider, jobs=_int(args.jobs or rc.get("jobs"), 4), rules=rules, secrets=[key] if key else [])
        change_summary = _change_summary(root, changes)

        def notes_for(chunk_paths: List[str]) -> str:
            return prompts.context_notes(chunk_paths, file_info, impact, time.time())

        ai_result = eng.review(chunks, FileIndex(files), notes_for, change_summary, local)
        ai_doc = ai_result.to_dict()
        if ai_result.all_failed:
            first = next((c.error for c in ai_result.chunks if c.error), "unknown error")
            ai_failed = f"AI review failed: {first}"
    elif use_ai and files and not chunks:
        notes.append("nothing to send to the AI (only binary, deleted, lock, generated or excluded files changed)")

    all_findings = sort_findings(dedupe(local + (ai_result.findings if ai_result else [])))
    assign_ids(all_findings)
    tally = counts(all_findings)
    additions = sum(f.additions for f in files)
    deletions = sum(f.deletions for f in files)
    summary, verdict = engine.fallback_summary(len(files), additions, deletions, tally)
    if ai_result and ai_result.summary:
        summary = ai_result.summary
    if ai_result and ai_result.verdict:
        verdict = ai_result.verdict
    if tally["error"] and verdict == "approve":
        verdict = "request_changes"

    threshold = SEVERITY_RANK.get(fail_on)
    findings_fail = threshold is not None and any(SEVERITY_RANK[f.severity] >= threshold for f in all_findings)
    failed = findings_fail or ai_failed is not None
    notes += index.notes
    if not index.enabled and not index.switched_off:
        notes.append("index disabled (--no-index)")
    doc = envelope(
        "review",
        range=changes.range_dict(),
        stats={"files": len(files), "additions": additions, "deletions": deletions, "chunks": len(chunks),
               "reviewedFiles": len({p for c in chunks for p in c.paths}), "skippedFiles": len(skipped),
               "bytes": sum(c.size for c in chunks)},
        files=[dict(f.to_dict(), skipped=skipped_by_path.get(f.path), firstLine=_first_line(f)) for f in files],
        summary=summary,
        verdict=verdict,
        findings=[dict(f.to_dict(), fingerprint=f.fingerprint()) for f in all_findings],
        counts=tally,
        ai=ai_doc,
        index={"source": index.source if index.enabled else "disabled", "missingPartners": len((impact or {}).get("suggestions") or [])},
        failOn=fail_on,
        failed=failed,
        failReasons=([f"findings at or above {fail_on}"] if findings_fail else []) + ([ai_failed] if ai_failed else []),
        notes=notes,
    )
    index.close()
    emit(report.render(doc, fmt), args.out)
    return 1 if failed else 0


def _env_base_url() -> Optional[str]:
    import os
    return os.environ.get("GITROCHI_AI_BASE_URL") or None


def _first_line(f: diff.FileDiff) -> Optional[int]:
    added = [ln.new for ln in f.added_lines() if ln.new]
    if added:
        return added[0]
    visible = sorted(f.new_side_lines())
    return visible[0] if visible else None


def _change_summary(root: Path, changes: diff.ChangeSet) -> Dict[str, Any]:
    subjects: List[str] = []
    if changes.mode == "range" and changes.merge_base and changes.head:
        out = gitutil.git_ok(root, "log", "--no-color", "--format=%s", "-n", "30", f"{changes.merge_base}..{changes.head}")
        subjects = [redact.redact(s) for s in (out or "").splitlines() if s.strip()]
    return {
        "mode": changes.mode,
        "files": [{"path": f.path, "status": f.status, "additions": f.additions, "deletions": f.deletions} for f in changes.files[:150]],
        "moreFiles": max(0, len(changes.files) - 150),
        "commitSubjects": subjects,
    }
