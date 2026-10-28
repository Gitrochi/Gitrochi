"""Analysis output: text, Markdown, JSON and one offline HTML file (inline CSP, no scripts, no external resources)."""

from __future__ import annotations

import base64
import hashlib
import html
from typing import Any, Dict, List, Sequence

from gitrochi.util import age_text, day, dumps, md_escape, table, truncate


def _pct(value: Any) -> str:
    try:
        return f"{float(value) * 100:.0f}%"
    except (TypeError, ValueError):
        return "-"


def _owners(authors: Sequence[Dict[str, Any]], limit: int = 3) -> str:
    return ", ".join(f"{a.get('name') or a.get('email')} {_pct(a.get('share'))}" for a in authors[:limit])


def text(doc: Dict[str, Any]) -> str:
    now = doc["now"]
    idx = doc["index"]
    out = [f"Repository analysis · {idx.get('commits')} commits indexed · newest {day(idx.get('newestCommitTime'))}"
           + (f" · since {day(doc['since'])}" if doc.get("since") else "") + (f" · prefix {doc['prefix']}" if doc.get("prefix") else "")]
    sections = doc["sections"]
    if "hotspots" in sections:
        out += ["", "Hotspots (churn x recency)"]
        rows = [(h["path"], h["commits"], h["churn"], h["authors"], age_text(now - h["lastTime"]), h["score"]) for h in doc["hotspots"]]
        out.append(table(rows, ["path", "commits", "churn", "authors", "last", "score"], "lrrrrr") if rows else "  none")
    if "coupling" in sections:
        out += ["", f"Change coupling clusters (>= {doc['coupling']['minCommits']} shared commits, Jaccard >= {doc['coupling']['minJaccard']})"]
        if not doc["coupling"]["clusters"]:
            out.append("  none")
        for c in doc["coupling"]["clusters"]:
            out.append(f"  #{c['id']} {c['size']} files, strength {c['strength']:.2f}: " + ", ".join(c["files"][:8])
                       + (" ..." if c["size"] > 8 else ""))
    if "ownership" in sections:
        out += ["", "Ownership and bus factor"]
        rows = [(d["directory"], d["commits"], d["authorCount"], d["busFactor"], _owners(d["authors"])) for d in doc["ownership"]]
        out.append(table(rows, ["folder", "commits", "authors", "bus factor", "main authors"], "lrrrl") if rows else "  none")
    if "knowledgeLoss" in sections:
        kl = doc["knowledgeLoss"]
        out += ["", f"Knowledge-loss risk (main authors inactive > {kl['inactiveDays']} days): {kl['atRisk']} files"]
        rows = [(f["path"], f["commits"], _pct(f["inactiveShare"]), f["mainAuthor"].get("name"),
                 day(f["mainAuthor"].get("lastActive"))) for f in kl["files"]]
        out.append(table(rows, ["path", "commits", "inactive share", "main author", "last active"], "lrrll") if rows else "  none")
    if "trends" in sections:
        tr = doc["trends"]
        change = f"{tr['change'] * 100:+.0f}%" if tr.get("change") is not None else "n/a"
        out += ["", f"Weekly activity: trend {tr['direction']} (slope {tr['slope']:+.2f} commits/week), last 4 weeks "
                    f"{tr['recentAverage']}/week vs {tr['previousAverage']}/week before ({change})"]
        peak = max([w["commits"] for w in tr["weeks"]] + [1])
        for w in tr["weeks"][-12:]:
            out.append(f"  {w['week']}  {'#' * max(0, round(30 * w['commits'] / peak)):<30} {w['commits']:>4} commits {w['churn']:>7} lines")
    if "outliers" in sections:
        ol = doc["outliers"]
        out += ["", f"Large-commit outliers (robust z >= {ol['threshold']}, median {ol.get('median')} lines)"]
        rows = [(c["sha"][:10], c["size"], c["filesChanged"], c["score"], truncate(c["subject"], 60)) for c in ol["commits"]]
        out.append(table(rows, ["commit", "lines", "files", "z", "subject"], "lrrrl") if rows else "  none")
    for note in doc.get("notes") or []:
        out.append(f"Note: {note}")
    return "\n".join(out)


def markdown(doc: Dict[str, Any]) -> str:
    now = doc["now"]
    sections = doc["sections"]
    out = ["# Repository analysis", "", f"{doc['index'].get('commits')} commits indexed · generated {doc['generatedAt']}", ""]

    def tab(headers: List[str], rows: List[List[Any]]) -> None:
        if not rows:
            out.append("_None._")
            out.append("")
            return
        out.append("| " + " | ".join(headers) + " |")
        out.append("|" + "|".join(" --- " for _ in headers) + "|")
        for row in rows:
            out.append("| " + " | ".join(md_escape(c) for c in row) + " |")
        out.append("")

    if "hotspots" in sections:
        out += ["## Hotspots", ""]
        tab(["Path", "Commits", "Churn", "Authors", "Last change", "Score"],
            [[f"`{h['path']}`", h["commits"], h["churn"], h["authors"], age_text(now - h["lastTime"]), h["score"]] for h in doc["hotspots"]])
    if "coupling" in sections:
        out += ["## Change coupling", ""]
        tab(["#", "Files", "Strength"], [[c["id"], ", ".join(f"`{f}`" for f in c["files"][:10]), f"{c['strength']:.2f}"]
                                         for c in doc["coupling"]["clusters"]])
    if "ownership" in sections:
        out += ["## Ownership and bus factor", ""]
        tab(["Folder", "Commits", "Authors", "Bus factor", "Main authors"],
            [[d["directory"], d["commits"], d["authorCount"], d["busFactor"], _owners(d["authors"])] for d in doc["ownership"]])
    if "knowledgeLoss" in sections:
        kl = doc["knowledgeLoss"]
        out += [f"## Knowledge-loss risk ({kl['atRisk']} files)", ""]
        tab(["Path", "Commits", "Inactive share", "Main author", "Last active"],
            [[f"`{f['path']}`", f["commits"], _pct(f["inactiveShare"]), f["mainAuthor"].get("name"), day(f["mainAuthor"].get("lastActive"))]
             for f in kl["files"]])
    if "trends" in sections:
        tr = doc["trends"]
        out += ["## Weekly activity", "", f"Trend **{tr['direction']}** (slope {tr['slope']:+.2f} commits/week).", ""]
        tab(["Week", "Commits", "Lines", "Authors"], [[w["week"], w["commits"], w["churn"], w["authors"]] for w in tr["weeks"][-12:]])
    if "outliers" in sections:
        out += ["## Large-commit outliers", ""]
        tab(["Commit", "Lines", "Files", "z", "Subject"],
            [[f"`{c['sha'][:10]}`", c["size"], c["filesChanged"], c["score"], c["subject"]] for c in doc["outliers"]["commits"]])
    for note in doc.get("notes") or []:
        out.append(f"> {md_escape(note)}")
    return "\n".join(out)


CSS = """
:root { color-scheme: light dark; --bg: #ffffff; --fg: #1d1d1f; --muted: #6e6e73; --line: #d2d2d7; --bar: #0a84ff; --card: #f5f5f7; }
@media (prefers-color-scheme: dark) { :root { --bg: #1c1c1e; --fg: #f5f5f7; --muted: #a1a1a6; --line: #3a3a3c; --bar: #64a8ff; --card: #2c2c2e; } }
* { box-sizing: border-box; }
body { margin: 0; padding: 24px 16px 48px; background: var(--bg); color: var(--fg); font: 14px/1.5 -apple-system, "Segoe UI", system-ui, sans-serif; }
main { max-width: 1080px; margin: 0 auto; }
h1 { font-size: 22px; margin: 0 0 4px; }
h2 { font-size: 16px; margin: 32px 0 8px; }
p.meta, td.num-muted, .muted { color: var(--muted); }
.wrap { overflow-x: auto; }
table { border-collapse: collapse; width: 100%; }
th, td { text-align: left; padding: 6px 8px; border-bottom: 1px solid var(--line); vertical-align: top; }
th { font-weight: 600; color: var(--muted); }
td.num, th.num { text-align: right; font-variant-numeric: tabular-nums; }
code { font: 12px ui-monospace, SFMono-Regular, Menlo, monospace; word-break: break-all; }
.cluster { background: var(--card); border-radius: 8px; padding: 8px 12px; margin: 8px 0; }
svg .bar { fill: var(--bar); }
svg text { fill: var(--muted); font-size: 10px; }
""".strip()


def _csp_hash(css: str) -> str:
    digest = hashlib.sha256(css.encode("utf-8")).digest()
    return "sha256-" + base64.b64encode(digest).decode("ascii")


def _e(value: Any) -> str:
    return html.escape("" if value is None else str(value), quote=True)


def _html_table(headers: Sequence[str], rows: Sequence[Sequence[Any]], numeric: Sequence[int] = ()) -> str:
    if not rows:
        return '<p class="muted">None.</p>'
    head = "".join(f'<th class="num">{_e(h)}</th>' if i in numeric else f"<th>{_e(h)}</th>" for i, h in enumerate(headers))
    body = []
    for row in rows:
        cells = "".join(f'<td class="num">{_e(c)}</td>' if i in numeric else f"<td>{c}</td>" for i, c in enumerate(row))
        body.append(f"<tr>{cells}</tr>")
    return f'<div class="wrap"><table><thead><tr>{head}</tr></thead><tbody>{"".join(body)}</tbody></table></div>'


def _bars(weeks: Sequence[Dict[str, Any]]) -> str:
    if not weeks:
        return ""
    width, height, gap = 720, 120, 2
    peak = max([w["commits"] for w in weeks] + [1])
    step = width / len(weeks)
    parts = [f'<svg viewBox="0 0 {width} {height + 18}" width="100%" role="img" aria-label="Commits per week">']
    for i, w in enumerate(weeks):
        h = 0 if not w["commits"] else max(1.0, height * w["commits"] / peak)
        x = i * step
        parts.append(f'<rect class="bar" x="{x + gap / 2:.1f}" y="{height - h:.1f}" width="{max(1.0, step - gap):.1f}" height="{h:.1f}">'
                     f'<title>{_e(w["week"])}: {w["commits"]} commits, {w["churn"]} lines</title></rect>')
    parts.append(f'<text x="0" y="{height + 14}">{_e(weeks[0]["week"])}</text>')
    parts.append(f'<text x="{width}" y="{height + 14}" text-anchor="end">{_e(weeks[-1]["week"])}</text>')
    parts.append("</svg>")
    return "".join(parts)


def html_page(doc: Dict[str, Any]) -> str:
    now = doc["now"]
    sections = doc["sections"]
    body: List[str] = ["<main>", "<h1>Repository analysis</h1>",
                       f'<p class="meta">{_e(doc["index"].get("commits"))} commits indexed · generated {_e(doc["generatedAt"])}'
                       + (f" · since {_e(day(doc['since']))}" if doc.get("since") else "")
                       + (f" · prefix <code>{_e(doc['prefix'])}</code>" if doc.get("prefix") else "") + "</p>"]
    if "hotspots" in sections:
        body.append("<h2>Hotspots</h2>")
        body.append(_html_table(["Path", "Commits", "Churn", "Authors", "Last change", "Score"],
                                [[f"<code>{_e(h['path'])}</code>", h["commits"], h["churn"], h["authors"], age_text(now - h["lastTime"]), h["score"]]
                                 for h in doc["hotspots"]], numeric=(1, 2, 3, 4, 5)))
    if "coupling" in sections:
        body.append("<h2>Change coupling</h2>")
        clusters = doc["coupling"]["clusters"]
        if not clusters:
            body.append('<p class="muted">None.</p>')
        for c in clusters:
            files = ", ".join(f"<code>{_e(f)}</code>" for f in c["files"])
            strength = "{:.2f}".format(c["strength"])
            body.append(f'<div class="cluster"><strong>#{_e(c["id"])}</strong> · {_e(c["size"])} files · strength {_e(strength)}<br>{files}</div>')
    if "ownership" in sections:
        body.append("<h2>Ownership and bus factor</h2>")
        body.append(_html_table(["Folder", "Commits", "Authors", "Bus factor", "Main authors"],
                                [[f"<code>{_e(d['directory'])}</code>", d["commits"], d["authorCount"], d["busFactor"], _e(_owners(d["authors"]))]
                                 for d in doc["ownership"]], numeric=(1, 2, 3)))
    if "knowledgeLoss" in sections:
        kl = doc["knowledgeLoss"]
        body.append(f"<h2>Knowledge-loss risk · {_e(kl['atRisk'])} files</h2>")
        body.append(_html_table(["Path", "Commits", "Inactive share", "Main author", "Last active"],
                                [[f"<code>{_e(f['path'])}</code>", f["commits"], _pct(f["inactiveShare"]), _e(f["mainAuthor"].get("name")),
                                  _e(day(f["mainAuthor"].get("lastActive")))] for f in kl["files"]], numeric=(1, 2)))
    if "trends" in sections:
        tr = doc["trends"]
        body.append("<h2>Weekly activity</h2>")
        slope = "{:+.2f}".format(tr["slope"])
        body.append(f'<p class="meta">Trend {_e(tr["direction"])} · slope {_e(slope)} commits/week</p>')
        body.append(_bars(tr["weeks"]))
    if "outliers" in sections:
        body.append("<h2>Large-commit outliers</h2>")
        body.append(_html_table(["Commit", "Lines", "Files", "z", "Subject"],
                                [[f"<code>{_e(c['sha'][:10])}</code>", c["size"], c["filesChanged"], c["score"], _e(c["subject"])]
                                 for c in doc["outliers"]["commits"]], numeric=(1, 2, 3)))
    for note in doc.get("notes") or []:
        body.append(f'<p class="muted">{_e(note)}</p>')
    body.append("</main>")
    csp = f"default-src 'none'; style-src '{_csp_hash(CSS)}'; img-src data:; base-uri 'none'; form-action 'none'"
    return ("<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n"
            f'<meta http-equiv="Content-Security-Policy" content="{csp}">\n'
            '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
            '<meta name="referrer" content="no-referrer">\n'
            "<title>Repository analysis</title>\n"
            f"<style>{CSS}</style>\n</head>\n<body>\n" + "\n".join(body) + "\n</body>\n</html>\n")


def render(doc: Dict[str, Any], fmt: str) -> str:
    if fmt == "json":
        return dumps(doc)
    if fmt == "markdown":
        return markdown(doc)
    if fmt == "html":
        return html_page(doc)
    return text(doc)
