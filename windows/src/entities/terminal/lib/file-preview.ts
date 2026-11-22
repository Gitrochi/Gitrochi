/**
 * How a file opens in a browser tab: the webview shows media, PDF and HTML itself; text formats are turned into a page
 * here (SQL highlighted, CSV/TSV as a table, JSON as a folding tree, source code in the code reader's colours, anything
 * else as plain text). The pages carry no script. macOS: Core/FilePreview.swift
 */
import { sourceLanguage, sourceSegments, sourceTokens } from "@/shared/lib";

export type PreviewKind = { kind: "native"; mime: string } | { kind: "sql" } | { kind: "table"; separator: string } | { kind: "json" } | { kind: "code"; language: string } | { kind: "text" };

/** Larger text files are cut, so a log or a dump cannot stall the tab */
export const textLimit = 2 * 1024 * 1024;
export const tableRowLimit = 5000;

const nativeTypes: Record<string, string> = {
  pdf: "application/pdf",
  png: "image/png",
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  gif: "image/gif",
  webp: "image/webp",
  bmp: "image/bmp",
  ico: "image/x-icon",
  svg: "image/svg+xml",
  html: "text/html",
  htm: "text/html",
  mp4: "video/mp4",
  m4v: "video/mp4",
  webm: "video/webm",
  mov: "video/quicktime",
  mp3: "audio/mpeg",
  m4a: "audio/mp4",
  wav: "audio/wav",
  aac: "audio/aac",
  ogg: "audio/ogg",
  flac: "audio/flac",
};

export function previewKind(path: string): PreviewKind {
  const name = path.split(/[\\/]/).pop() ?? "";
  const ext = name.includes(".") ? name.slice(name.lastIndexOf(".") + 1).toLowerCase() : "";
  if (nativeTypes[ext]) return { kind: "native", mime: nativeTypes[ext] };
  if (["sql", "psql", "mysql", "ddl", "dml"].includes(ext)) return { kind: "sql" };
  if (ext === "csv") return { kind: "table", separator: "," };
  if (ext === "tsv" || ext === "tab") return { kind: "table", separator: "\t" };
  if (["json", "geojson", "jsonc"].includes(ext)) return { kind: "json" };
  const language = sourceLanguage(name);
  if (!["Plain text", "Markdown", "HTML", "XML"].includes(language)) return { kind: "code", language };
  return { kind: "text" };
}

export function escapeHtml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

/** Escaped HTML with the code reader's token colours, in the page's own classes (macOS: FilePreview.highlightCode) */
export function highlightCode(text: string, language: string): string {
  return sourceSegments(text, sourceTokens(text, language))
    .map((seg) => (seg.kind ? `<span class="${seg.kind}">${escapeHtml(seg.text)}</span>` : escapeHtml(seg.text)))
    .join("");
}

// MARK: SQL

export const sqlKeywords = new Set(
  "add all alter and as asc autoincrement begin between by cascade case check commit constraint create cross database default delete desc distinct drop else end exists foreign from full grant group having if in index inner insert into is join key left like limit not null offset on or order outer primary references returning revoke right rollback select set table then transaction trigger truncate union unique update using values view when where with".split(" "),
);
export const sqlTypes = new Set("bigint blob boolean char date datetime decimal double float int integer json jsonb numeric real serial smallint text time timestamp timestamptz uuid varchar".split(" "));

const isLetter = (c: string) => /[\p{L}_]/u.test(c);
const isDigit = (c: string) => c >= "0" && c <= "9";

/** Escaped HTML with spans for comments, strings, numbers, keywords and types */
export function highlightSql(text: string): string {
  const chars = Array.from(text);
  let out = "";
  let i = 0;
  const span = (cls: string, s: string) => (out += `<span class="${cls}">${escapeHtml(s)}</span>`);
  while (i < chars.length) {
    const c = chars[i];
    const next = chars[i + 1];
    if (c === "-" && next === "-") {
      let j = i;
      while (j < chars.length && chars[j] !== "\n") j++;
      span("comment", chars.slice(i, j).join(""));
      i = j;
    } else if (c === "/" && next === "*") {
      let j = i + 2;
      while (j + 1 < chars.length && !(chars[j] === "*" && chars[j + 1] === "/")) j++;
      j = Math.min(chars.length, j + 2);
      span("comment", chars.slice(i, j).join(""));
      i = j;
    } else if (c === "'" || c === '"' || c === "`") {
      let j = i + 1;
      while (j < chars.length) {
        if (chars[j] === c) {
          if (chars[j + 1] === c) {
            j += 2;
            continue;
          }
          j++;
          break;
        }
        j++;
      }
      span(c === "'" ? "string" : "ident", chars.slice(i, j).join(""));
      i = j;
    } else if (isDigit(c) && (i === 0 || !(isLetter(chars[i - 1]) || isDigit(chars[i - 1])))) {
      let j = i;
      while (j < chars.length && (isDigit(chars[j]) || chars[j] === ".")) j++;
      span("number", chars.slice(i, j).join(""));
      i = j;
    } else if (isLetter(c)) {
      let j = i;
      while (j < chars.length && (isLetter(chars[j]) || isDigit(chars[j]))) j++;
      const word = chars.slice(i, j).join("");
      const lower = word.toLowerCase();
      if (sqlKeywords.has(lower)) span("keyword", word);
      else if (sqlTypes.has(lower)) span("type", word);
      else out += escapeHtml(word);
      i = j;
    } else {
      out += escapeHtml(c);
      i++;
    }
  }
  return out;
}

// MARK: CSV / TSV

/** RFC 4180 rows: quoted fields may hold the separator, doubled quotes and line breaks */
export function parseDelimited(text: string, separator: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [];
  let field = "";
  let quoted = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (quoted) {
      if (c === '"') {
        if (text[i + 1] === '"') {
          field += '"';
          i++;
        } else quoted = false;
      } else field += c;
    } else if (c === '"' && field === "") quoted = true;
    else if (c === separator) {
      row.push(field);
      field = "";
    } else if (c === "\n" || c === "\r") {
      if (c === "\r" && text[i + 1] === "\n") i++;
      row.push(field);
      field = "";
      rows.push(row);
      row = [];
    } else field += c;
  }
  if (field !== "" || row.length) {
    row.push(field);
    rows.push(row);
  }
  return rows;
}

export function previewTable(rows: string[][], words: { empty: string; size: (rows: number, columns: number) => string }): string {
  const head = rows[0];
  if (!head) return `<p class="note">${escapeHtml(words.empty)}</p>`;
  const width = Math.max(...rows.map((r) => r.length));
  const cell = (r: string[], i: number) => escapeHtml(r[i] ?? "");
  let html = `<p class="note">${escapeHtml(words.size(rows.length - 1, width))}</p><table><thead><tr><th class="n"></th>`;
  for (let i = 0; i < width; i++) html += `<th>${cell(head, i)}</th>`;
  html += "</tr></thead><tbody>";
  rows.slice(1, tableRowLimit + 1).forEach((r, n) => {
    html += `<tr><td class="n">${n + 1}</td>`;
    for (let i = 0; i < width; i++) html += `<td>${cell(r, i)}</td>`;
    html += "</tr>";
  });
  return html + "</tbody></table>";
}

// MARK: JSON

export function jsonTree(value: unknown, key: string | null = null, depth = 0): string {
  const label = key === null ? "" : `<span class="key">${escapeHtml(key)}</span>: `;
  const open = depth < 2 ? " open" : "";
  if (Array.isArray(value)) {
    const items = value.map((v, i) => jsonTree(v, String(i), depth + 1)).join("");
    return `<details${open}><summary>${label}<span class="punct">[</span> <span class="count">${value.length}</span> <span class="punct">]</span></summary>${items}</details>`;
  }
  if (value !== null && typeof value === "object") {
    const keys = Object.keys(value).sort();
    const items = keys.map((k) => jsonTree((value as Record<string, unknown>)[k], k, depth + 1)).join("");
    return `<details${open}><summary>${label}<span class="punct">{</span> <span class="count">${keys.length}</span> <span class="punct">}</span></summary>${items}</details>`;
  }
  const leaf =
    value === null || typeof value === "boolean"
      ? `<span class="keyword">${String(value)}</span>`
      : typeof value === "number"
        ? `<span class="number">${value}</span>`
        : `<span class="string">"${escapeHtml(String(value))}"</span>`;
  return `<div class="leaf">${label}${leaf}</div>`;
}

// MARK: Page

export type PreviewWords = { cut: string; empty: string; size: (rows: number, columns: number) => string };

/** The page for a text file's contents */
export function previewPage(name: string, text: string, kind: PreviewKind, cut: boolean, words: PreviewWords): string {
  let body: string;
  if (kind.kind === "sql") body = `<pre class="code">${highlightSql(text)}</pre>`;
  else if (kind.kind === "table") body = previewTable(parseDelimited(text, kind.separator), words);
  else if (kind.kind === "json") {
    try {
      if (cut) throw new Error("cut");
      body = `<div class="tree">${jsonTree(JSON.parse(text))}</div>`;
    } catch {
      body = `<pre class="code">${escapeHtml(text)}</pre>`;
    }
  } else if (kind.kind === "code") body = `<pre class="code">${highlightCode(text, kind.language)}</pre>`;
  else body = `<pre class="code">${escapeHtml(text)}</pre>`;
  return previewDocument(name, (cut ? `<p class="note">${escapeHtml(words.cut)}</p>` : "") + body);
}

export function previewDocument(title: string, body: string): string {
  return `<!doctype html><html><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
<title>${escapeHtml(title)}</title><style>
:root { color-scheme: light dark; --fg: #1d1d1f; --bg: #fff; --muted: #6e6e73; --line: #e5e5ea; --head: #f5f5f7;
  --kw: #af00db; --type: #267f99; --str: #a31515; --num: #098658; --com: #008000; --key: #0e6e8c; --fn: #795e26; --var: #001080; --prop: #0070c1; }
@media (prefers-color-scheme: dark) { :root { --fg: #e6e6e6; --bg: #1e1e1e; --muted: #98989d; --line: #38383a; --head: #2a2a2c;
  --kw: #c586c0; --type: #4ec9b0; --str: #ce9178; --num: #b5cea8; --com: #6a9955; --key: #67b7a4; --fn: #dcdcaa; --var: #9cdcfe; --prop: #4fc1ff; } }
body { margin: 0; padding: 16px 20px; background: var(--bg); color: var(--fg); font: 13px "Segoe UI", -apple-system, sans-serif; }
pre, .tree, table { font: 12px "Cascadia Mono", Consolas, ui-monospace, Menlo, monospace; }
pre { margin: 0; white-space: pre-wrap; word-break: break-word; line-height: 1.5; }
.keyword { color: var(--kw); font-weight: 600; } .type { color: var(--type); } .string { color: var(--str); }
.function { color: var(--fn); } .variable { color: var(--var); } .property { color: var(--prop); }
.number { color: var(--num); } .comment { color: var(--com); font-style: italic; } .ident, .key { color: var(--key); }
.note, .count, .punct { color: var(--muted); } .note { margin: 0 0 10px; font-size: 12px; }
table { border-collapse: collapse; } th, td { border: 1px solid var(--line); padding: 4px 8px; text-align: left; vertical-align: top; white-space: pre-wrap; }
th { position: sticky; top: 0; background: var(--head); font-weight: 600; } td.n, th.n { color: var(--muted); text-align: right; }
tbody tr:hover { background: var(--head); }
.tree details > :not(summary), .tree .leaf { margin-left: 18px; } .tree summary { cursor: default; line-height: 1.6; } .tree .leaf { line-height: 1.6; }
</style></head><body>${body}</body></html>`;
}
