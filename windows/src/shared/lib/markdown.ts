/**
 * GitHub-flavored Markdown for PR/MR text and commit bodies, parsed into a tree the UI draws directly.
 * No HTML string is ever built, so raw HTML in someone else's text can't run; only http(s)/mailto links survive.
 * macOS: Core/Markdown.swift has the same structure.
 */
import { inlines, trimBreaks } from "./markdown-inline";

export { safeUrl } from "./markdown-inline";

export type MdInline =
  | { kind: "text"; text: string }
  | { kind: "strong" | "em" | "strike"; children: MdInline[] }
  | { kind: "code"; text: string }
  | { kind: "link"; href: string; children: MdInline[] }
  | { kind: "image"; src: string; alt: string }
  | { kind: "break" };

export type MdAlign = "left" | "center" | "right" | null;

export interface MdListItem {
  /** null = not a task item */
  task: boolean | null;
  blocks: MdBlock[];
}

export type MdBlock =
  | { kind: "paragraph"; inlines: MdInline[] }
  | { kind: "heading"; level: number; inlines: MdInline[] }
  | { kind: "code"; lang: string; text: string }
  | { kind: "quote"; blocks: MdBlock[] }
  | { kind: "list"; ordered: boolean; start: number; items: MdListItem[] }
  | { kind: "table"; align: MdAlign[]; head: MdInline[][]; rows: MdInline[][][] }
  | { kind: "details"; summary: MdInline[]; blocks: MdBlock[] }
  | { kind: "rule" };

/** Where #123, !123 (GitLab) and @name point */
export interface MdRefs {
  issue(n: string): string;
  request?(n: string): string;
  user(name: string): string;
}

export function parseMarkdown(text: string, refs?: MdRefs): MdBlock[] {
  const lines = text
    .replace(/\r\n?/g, "\n")
    .split("\n")
    .map((l) => l.replace(/^\t+/, (m) => "    ".repeat(m.length)));
  return blocks(lines, refs);
}

// MARK: - Blocks

const blankRe = /^[ \t]*$/;
const fenceRe = /^( {0,3})(`{3,}|~{3,})[ \t]*(.*)$/;
const headingRe = /^ {0,3}(#{1,6})(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*$/;
const ruleRe = /^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$/;
const quoteRe = /^ {0,3}> ?/;
const setextRe = /^ {0,3}(=+|-+)[ \t]*$/;
const detailsRe = /^ {0,3}<details(?:\s[^>]*)?>/i;
const commentRe = /^ {0,3}<!--/;
const delimRowRe = /^ {0,3}\|?[ \t]*:?-+:?[ \t]*(?:\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$/;

const isBlank = (l: string) => blankRe.test(l);
const indentOf = (l: string) => l.length - l.trimStart().length;
const dedent = (l: string, n: number) => l.slice(Math.min(n, indentOf(l)));

interface Marker {
  ordered: boolean;
  /** "-", "+", "*", "." or ")" — a different one starts a new list */
  delim: string;
  start: number;
  contentIndent: number;
  rest: string;
}

function marker(line: string): Marker | null {
  const m = /^( {0,3})(?:([-+*])|(\d{1,9})([.)]))([ \t]+|$)(.*)$/.exec(line);
  if (!m) return null;
  const width = m[1].length + (m[2] ?? m[3] + m[4]).length;
  const spaces = m[5].length;
  // 5+ spaces after the marker means indented code inside the item
  const gap = spaces === 0 || spaces > 4 ? 1 : spaces;
  const rest = spaces > 4 ? " ".repeat(spaces - 1) + m[6] : m[6];
  return { ordered: !m[2], delim: m[2] ?? m[4], start: m[3] ? Number(m[3]) : 1, contentIndent: width + gap, rest };
}

const isFence = (l: string) => {
  const m = fenceRe.exec(l);
  return !!m && !(m[2][0] === "`" && m[3].includes("`"));
};

function startsBlock(l: string) {
  return isFence(l) || headingRe.test(l) || ruleRe.test(l) || quoteRe.test(l) || marker(l) !== null || detailsRe.test(l) || commentRe.test(l);
}

/** Only non-empty bullets and lists starting at 1 may cut a paragraph short */
function interruptsParagraph(l: string) {
  if (isFence(l) || headingRe.test(l) || ruleRe.test(l) || quoteRe.test(l) || detailsRe.test(l) || commentRe.test(l)) return true;
  const m = marker(l);
  return !!m && m.rest.trim() !== "" && (!m.ordered || m.start === 1);
}

const startsTable = (lines: string[], i: number) =>
  lines[i].includes("|") && i + 1 < lines.length && lines[i + 1].includes("|") && delimRowRe.test(lines[i + 1]) && cells(lines[i]).length === cells(lines[i + 1]).length;

function blocks(source: string[], refs?: MdRefs): MdBlock[] {
  const lines = [...source];
  const out: MdBlock[] = [];
  const inl = (s: string) => inlines(s, refs);
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    if (isBlank(line)) {
      i++;
      continue;
    }
    if (indentOf(line) >= 4) {
      const body: string[] = [];
      while (i < lines.length && (isBlank(lines[i]) || indentOf(lines[i]) >= 4)) body.push(dedent(lines[i++], 4));
      while (body.length && isBlank(body[body.length - 1])) body.pop();
      out.push({ kind: "code", lang: "", text: body.join("\n") });
      continue;
    }
    if (isFence(line)) {
      const m = fenceRe.exec(line)!;
      const fence = m[2];
      const body: string[] = [];
      i++;
      while (i < lines.length) {
        const close = /^ {0,3}(`{3,}|~{3,})[ \t]*$/.exec(lines[i]);
        if (close && close[1][0] === fence[0] && close[1].length >= fence.length) {
          i++;
          break;
        }
        body.push(dedent(lines[i++], m[1].length));
      }
      out.push({ kind: "code", lang: m[3].trim().split(/\s/)[0] ?? "", text: body.join("\n") });
      continue;
    }
    if (commentRe.test(line)) {
      let j = i;
      while (j < lines.length && !lines[j].includes("-->")) j++;
      const after = j < lines.length ? lines[j].slice(lines[j].indexOf("-->") + 3) : "";
      if (isBlank(after)) i = j + 1;
      else {
        lines[j] = after;
        i = j;
      }
      continue;
    }
    if (detailsRe.test(line)) {
      i = details(lines, i, out, refs);
      continue;
    }
    const h = headingRe.exec(line);
    if (h) {
      out.push({ kind: "heading", level: h[1].length, inlines: inl(h[2] ?? "") });
      i++;
      continue;
    }
    if (ruleRe.test(line)) {
      out.push({ kind: "rule" });
      i++;
      continue;
    }
    if (quoteRe.test(line)) {
      const body: string[] = [];
      while (i < lines.length) {
        const l = lines[i];
        if (quoteRe.test(l)) body.push(l.replace(quoteRe, ""));
        else if (!isBlank(l) && body.length && !isBlank(body[body.length - 1]) && !startsBlock(l)) body.push(l);
        else break;
        i++;
      }
      out.push({ kind: "quote", blocks: blocks(body, refs) });
      continue;
    }
    const first = marker(line);
    if (first) {
      i = list(lines, i, first, out, refs);
      continue;
    }
    if (startsTable(lines, i)) {
      const align = cells(lines[i + 1]).map((d): MdAlign => (d.startsWith(":") ? (d.endsWith(":") ? "center" : "left") : d.endsWith(":") ? "right" : null));
      const head = cells(lines[i]).map(inl);
      const rows: MdInline[][][] = [];
      i += 2;
      while (i < lines.length && !isBlank(lines[i]) && !startsBlock(lines[i])) {
        const row = cells(lines[i++]);
        rows.push(align.map((_, c) => inl(row[c] ?? "")));
      }
      out.push({ kind: "table", align, head, rows });
      continue;
    }
    const para = [line.trim()];
    i++;
    let level = 0;
    while (i < lines.length) {
      const l = lines[i];
      if (isBlank(l)) break;
      const s = setextRe.exec(l);
      if (s) {
        level = s[1][0] === "=" ? 1 : 2;
        i++;
        break;
      }
      if (interruptsParagraph(l) || startsTable(lines, i)) break;
      para.push(l.trim());
      i++;
    }
    const content = trimBreaks(inl(para.join("\n")));
    if (level) out.push({ kind: "heading", level, inlines: content });
    else if (content.length) out.push({ kind: "paragraph", inlines: content });
  }
  return out;
}

function list(lines: string[], i: number, first: Marker, out: MdBlock[], refs?: MdRefs) {
  const items: MdListItem[] = [];
  while (i < lines.length) {
    const m = marker(lines[i]);
    if (!m || m.ordered !== first.ordered || m.delim !== first.delim || ruleRe.test(lines[i])) break;
    const body = [m.rest];
    i++;
    let blankBefore = m.rest.trim() === "";
    while (i < lines.length) {
      const l = lines[i];
      if (isBlank(l)) {
        body.push("");
        blankBefore = true;
      } else if (indentOf(l) >= m.contentIndent) {
        body.push(l.slice(m.contentIndent));
        blankBefore = false;
      } else if (!blankBefore && !startsBlock(l)) {
        // lazy continuation of the item's paragraph
        body.push(l.trim());
      } else break;
      i++;
    }
    while (body.length && isBlank(body[body.length - 1])) body.pop();
    let task: boolean | null = null;
    const t = /^\[([ xX])\](?:[ \t]+|$)/.exec(body[0] ?? "");
    if (t) {
      task = t[1] !== " ";
      body[0] = body[0].slice(t[0].length);
    }
    items.push({ task, blocks: blocks(body, refs) });
  }
  out.push({ kind: "list", ordered: first.ordered, start: first.start, items });
  return i;
}

function details(lines: string[], i: number, out: MdBlock[], refs?: MdRefs) {
  let depth = 0;
  let j = i;
  for (; j < lines.length; j++) {
    depth += (lines[j].match(/<details(?:\s[^>]*)?>/gi) ?? []).length;
    depth -= (lines[j].match(/<\/details\s*>/gi) ?? []).length;
    if (depth <= 0) break;
  }
  let body = lines.slice(i, j + 1).join("\n");
  body = body.replace(/^\s*<details(?:\s[^>]*)?>/i, "");
  const end = body.search(/<\/details\s*>(?![\s\S]*<\/details\s*>)/i);
  if (end >= 0) body = body.slice(0, end);
  let summary: MdInline[] = [{ kind: "text", text: "Details" }];
  const s = /^\s*<summary(?:\s[^>]*)?>([\s\S]*?)<\/summary\s*>/i.exec(body);
  if (s) {
    summary = inlines(s[1].trim(), refs);
    body = body.slice(s[0].length);
  }
  out.push({ kind: "details", summary, blocks: blocks(body.split("\n"), refs) });
  return j + 1;
}

/** Table row cells; `\|` is a literal pipe */
function cells(row: string): string[] {
  let s = row.trim();
  if (s.startsWith("|")) s = s.slice(1);
  if (s.endsWith("|") && !s.endsWith("\\|")) s = s.slice(0, -1);
  const out: string[] = [];
  let cur = "";
  for (let k = 0; k < s.length; k++) {
    if (s[k] === "\\" && s[k + 1] === "|") {
      cur += "|";
      k++;
    } else if (s[k] === "|") {
      out.push(cur.trim());
      cur = "";
    } else cur += s[k];
  }
  out.push(cur.trim());
  return out;
}
