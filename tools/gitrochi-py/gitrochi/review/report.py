"""Review output: text, Markdown (for a pull request comment), JSON and SARIF 2.1.0 (GitHub code scanning)."""

from __future__ import annotations

from typing import Any, Dict, List

from gitrochi import __version__
from gitrochi.util import dumps, md_escape, plural

SARIF_SCHEMA = "https://json.schemastore.org/sarif-2.1.0.json"
SARIF_LEVEL = {"error": "error", "warning": "warning", "info": "note"}
RULE_TEXT = {
    "local/cochange-missing": "A file that usually changes with the changed files is missing from the change",
    "local/large-diff": "The change is very large",
    "local/large-file": "One file changes a very large number of lines",
    "local/binary-file": "A binary file changed",
    "local/todo-added": "A TODO or FIXME marker was added",
    "local/debug-statement": "A debug statement was added",
    "local/conflict-marker": "A merge conflict marker was added",
    "local/test-deleted": "A test file was deleted",
    "local/lockfile-only": "Only lock files changed",
    "local/lockfile-without-manifest": "A lock file changed without its manifest",
    "local/secret-added": "A probable secret was added",
}


def _short(sha: Any) -> str:
    return str(sha)[:10] if sha else "-"


def _where(f: Dict[str, Any]) -> str:
    if not f.get("file"):
        return "(change)"
    return f"{f['file']}:{f['line']}" if f.get("line") else f["file"]


def _range_text(doc: Dict[str, Any]) -> str:
    rng = doc["range"]
    if rng["mode"] == "staged":
        return "staged changes"
    if rng["mode"] == "worktree":
        return "uncommitted changes"
    return f"{rng.get('baseRef')}...{rng.get('headRef')} ({_short(rng.get('mergeBase'))}..{_short(rng.get('head'))})"


def text(doc: Dict[str, Any]) -> str:
    stats = doc["stats"]
    out = [f"Review of {_range_text(doc)}: {plural(stats['files'], 'file')}, +{stats['additions']} -{stats['deletions']}"]
    if doc.get("summary"):
        out.append(f"Summary: {doc['summary']}")
    out.append(f"Verdict: {doc.get('verdict')}")
    out.append("")
    findings = doc["findings"]
    if not findings:
        out.append("No findings.")
    for f in findings:
        out.append(f"{f['severity']:<8} {_where(f)}  [{f['category']}] {f['message']}")
        if f.get("suggestion"):
            out.append(f"{'':<8} -> {f['suggestion']}")
    c = doc["counts"]
    out.append("")
    ai = doc.get("ai") or {}
    ai_text = (f"AI: {ai.get('provider')} {ai.get('model')}, {plural(ai.get('chunks') or 0, 'chunk')}, synthesis {ai.get('synthesis')}"
               if ai.get("enabled") else "AI: off")
    out.append(f"{plural(len(findings), 'finding')} ({plural(c['error'], 'error')}, {plural(c['warning'], 'warning')}, {c['info']} info) · "
               f"{ai_text} · index: {doc['index']['source']}")
    for err in ai.get("errors") or []:
        out.append(f"AI error (chunk {err.get('chunk')}): {err.get('message')}")
    skipped = [f for f in doc["files"] if f.get("skipped")]
    if skipped:
        out.append("Not reviewed by AI: " + ", ".join(f"{f['path']} ({f['skipped']})" for f in skipped[:20])
                   + (f" and {len(skipped) - 20} more" if len(skipped) > 20 else ""))
    for note in doc.get("notes") or []:
        out.append(f"Note: {note}")
    if doc.get("failed"):
        out.append("FAILED: " + "; ".join(doc.get("failReasons") or ["see above"]))
    return "\n".join(out)


def markdown(doc: Dict[str, Any]) -> str:
    c = doc["counts"]
    out = ["## Gitrochi review", "",
           f"**Verdict:** `{doc.get('verdict')}` · {plural(c['error'], 'error')} · {plural(c['warning'], 'warning')} · {c['info']} info · "
           f"{plural(doc['stats']['files'], 'file')} (+{doc['stats']['additions']} −{doc['stats']['deletions']})", ""]
    if doc.get("summary"):
        out += [md_escape(doc["summary"]), ""]
    if doc["findings"]:
        out += ["| Severity | Location | Finding |", "| --- | --- | --- |"]
        for f in doc["findings"]:
            cell = f"**[{md_escape(f['category'])}]** {md_escape(f['message'])}"
            if f.get("suggestion"):
                cell += f"<br>*Suggestion:* {md_escape(f['suggestion'])}"
            out.append(f"| {f['severity']} | `{md_escape(_where(f))}` | {cell} |")
        out.append("")
    else:
        out += ["No findings.", ""]
    ai = doc.get("ai") or {}
    detail = f"AI: {ai.get('provider')} `{ai.get('model')}`" if ai.get("enabled") else "AI: off (local checks only)"
    out.append(f"<sub>{detail} · index: {doc['index']['source']} · gitrochi-py {__version__}</sub>")
    return "\n".join(out)


def sarif(doc: Dict[str, Any]) -> str:
    rules: List[Dict[str, Any]] = []
    rule_index: Dict[str, int] = {}
    results = []
    first_lines = {item["path"]: item.get("firstLine") for item in doc.get("files") or []}
    anchor_file = next((item["path"] for item in doc.get("files") or [] if item.get("status") != "D"), None)
    for f in doc["findings"]:
        rule_id = f.get("rule") or f"{f['source']}/{f['category']}"
        if rule_id not in rule_index:
            rule_index[rule_id] = len(rules)
            rules.append({
                "id": rule_id,
                "name": "".join(part.capitalize() for part in rule_id.replace("/", "-").split("-")),
                "shortDescription": {"text": RULE_TEXT.get(rule_id, f"{f['category']} ({'AI review' if f['source'] == 'ai' else 'local check'})")},
                "defaultConfiguration": {"level": SARIF_LEVEL.get(f["severity"], "warning")},
                "properties": {"tags": [f["category"], "ai-review" if f["source"] == "ai" else "local-check"]},
            })
        message = f["message"] + (f"\n\nSuggestion: {f['suggestion']}" if f.get("suggestion") else "")
        result: Dict[str, Any] = {
            "ruleId": rule_id,
            "ruleIndex": rule_index[rule_id],
            "level": SARIF_LEVEL.get(f["severity"], "warning"),
            "message": {"text": message},
            "partialFingerprints": {"gitrochiFinding/v1": f.get("fingerprint") or f.get("id")},
            "properties": {"category": f["category"], "source": f["source"]},
        }
        # Code scanning shows only results with a location: change-wide findings go to the first changed line.
        location_file = f.get("file") or anchor_file
        if location_file:
            region = {"startLine": int(f.get("line") or first_lines.get(location_file) or 1)}
            if f.get("endLine") and f.get("line") and int(f["endLine"]) >= int(f["line"]):
                region["endLine"] = int(f["endLine"])
            result["locations"] = [{"physicalLocation": {"artifactLocation": {"uri": location_file, "uriBaseId": "%SRCROOT%"},
                                                         "region": region}}]
        results.append(result)
    log = {
        "$schema": SARIF_SCHEMA,
        "version": "2.1.0",
        "runs": [{
            "tool": {"driver": {"name": "gitrochi-review", "semanticVersion": __version__, "rules": rules}},
            "automationDetails": {"id": "gitrochi-review/"},
            "columnKind": "unicodeCodePoints",
            "results": results,
        }],
    }
    return dumps(log)


def render(doc: Dict[str, Any], fmt: str) -> str:
    if fmt == "json":
        return dumps(doc)
    if fmt == "sarif":
        return sarif(doc)
    if fmt == "markdown":
        return markdown(doc)
    return text(doc)
