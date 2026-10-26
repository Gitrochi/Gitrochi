/** Inline half of the Markdown parser (markdown.ts) */
import type { MdInline, MdRefs } from "./markdown";

export function safeUrl(href: string): string | null {
  const h = href.trim();
  return /^(https?:\/\/|mailto:)/i.test(h) ? h : null;
}

const punctRe = /[!-/:-@[-`{-~]/;
const wordRe = /[\p{L}\p{N}_]/u;
const entities: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: "\u00a0" };

function decode(s: string) {
  return s.replace(/&(#\d{1,7}|#x[0-9a-f]{1,6}|[a-z]+);/gi, (m, e: string) => {
    if (e[0] !== "#") return entities[e.toLowerCase()] ?? m;
    const code = e[1] === "x" || e[1] === "X" ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10);
    return code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : m;
  });
}

/**
 * One string being parsed. Lookups for a closing `, ] or * are cached so text full of
 * unmatched delimiters (pasted logs) stays linear instead of rescanning to the end each time.
 */
class Scan {
  private failedFrom = new Map<string, number>();
  private brackets: Int32Array | null = null;

  constructor(readonly s: string) {}

  ticksAfter(from: number, n: number) {
    const key = "`" + n;
    if ((this.failedFrom.get(key) ?? Infinity) <= from) return -1;
    const s = this.s;
    for (let k = from; k < s.length; k++) {
      if (s[k] !== "`") continue;
      let j = k;
      while (s[j] === "`") j++;
      if (j - k === n) return k;
      k = j;
    }
    this.failedFrom.set(key, from);
    return -1;
  }

  /** Matching ] for the [ at i, skipping escapes */
  bracketFor(i: number) {
    if (!this.brackets) {
      const s = this.s;
      const close = new Int32Array(s.length).fill(-1);
      const open: number[] = [];
      for (let k = 0; k < s.length; k++) {
        if (s[k] === "\\") k++;
        else if (s[k] === "[") open.push(k);
        else if (s[k] === "]" && open.length) close[open.pop()!] = k;
      }
      this.brackets = close;
    }
    return this.brackets[i];
  }

  /** A run of exactly n of c that can close emphasis opened before from */
  closingRun(from: number, c: string, n: number) {
    const key = c + n;
    if ((this.failedFrom.get(key) ?? Infinity) <= from) return -1;
    const s = this.s;
    for (let k = from; k < s.length; k++) {
      const ch = s[k];
      if (ch === "\\") {
        k++;
        continue;
      }
      if (ch === "`") {
        let r = k;
        while (s[r] === "`") r++;
        const end = this.ticksAfter(r, r - k);
        k = end >= 0 ? end + (r - k) - 1 : r - 1;
        continue;
      }
      if (ch !== c) continue;
      let j = k;
      while (s[j] === c) j++;
      const after = s[j];
      if (j - k === n && k > from && !/\s/.test(s[k - 1]) && !(c === "_" && after && wordRe.test(after))) return k;
      k = j - 1;
    }
    this.failedFrom.set(key, from);
    return -1;
  }
}

export function inlines(s: string, refs: MdRefs | undefined, inLink = false): MdInline[] {
  const scan = new Scan(s);
  const out: MdInline[] = [];
  let text = "";
  const flush = () => {
    if (text) out.push({ kind: "text", text: decode(text) });
    text = "";
  };
  const push = (n: MdInline) => {
    flush();
    out.push(n);
  };
  let i = 0;
  while (i < s.length) {
    const c = s[i];
    if (c === "\\" && i + 1 < s.length) {
      if (s[i + 1] === "\n") {
        push({ kind: "break" });
        i += 2;
        continue;
      }
      if (punctRe.test(s[i + 1])) {
        // keep it out of decode(): \&amp; stays literal
        text += s[i + 1] === "&" ? "&amp;" : s[i + 1];
        i += 2;
        continue;
      }
    }
    if (c === "\n") {
      text = text.replace(/ +$/, "");
      push({ kind: "break" });
      i++;
      continue;
    }
    if (c === "`") {
      let r = i;
      while (s[r] === "`") r++;
      const n = r - i;
      const end = scan.ticksAfter(r, n);
      if (end < 0) {
        text += s.slice(i, r);
        i = r;
        continue;
      }
      let code = s.slice(r, end).replace(/\n/g, " ");
      if (code.length > 1 && code.startsWith(" ") && code.endsWith(" ") && code.trim()) code = code.slice(1, -1);
      push({ kind: "code", text: code });
      i = end + n;
      continue;
    }
    if (c === "!" && s[i + 1] === "[") {
      const l = linkAt(scan, i + 1);
      if (l) {
        const src = safeUrl(l.href);
        const alt = plain(inlines(l.text, undefined, true));
        if (src) push({ kind: "image", src, alt });
        else if (alt) push({ kind: "text", text: alt });
        i = l.end;
        continue;
      }
    }
    if (c === "[" && !inLink) {
      const l = linkAt(scan, i);
      if (l) {
        const href = safeUrl(l.href);
        const children = inlines(l.text, refs, true);
        if (href) push({ kind: "link", href, children });
        else {
          flush();
          out.push(...children);
        }
        i = l.end;
        continue;
      }
    }
    if (c === "<") {
      const rest = s.slice(i, i + 2000);
      const auto = /^<((?:https?:\/\/|mailto:)[^\s<>]*)>/i.exec(rest);
      if (auto && !inLink) {
        push({ kind: "link", href: auto[1], children: [{ kind: "text", text: auto[1] }] });
        i += auto[0].length;
        continue;
      }
      if (rest.startsWith("<!--")) {
        const end = s.indexOf("-->", i + 4);
        if (end >= 0) {
          i = end + 3;
          continue;
        }
      }
      const script = /^<(script|style)\b/i.exec(rest);
      if (script) {
        const end = s.toLowerCase().indexOf("</" + script[1].toLowerCase(), i);
        const close = end >= 0 ? s.indexOf(">", end) : -1;
        i = close >= 0 ? close + 1 : s.length;
        continue;
      }
      const br = /^<br\s*\/?>/i.exec(rest);
      if (br) {
        push({ kind: "break" });
        i += br[0].length;
        continue;
      }
      const img = /^<img\b([^>]*)>/i.exec(rest);
      if (img) {
        const src = safeUrl(attr(img[1], "src") ?? "");
        const alt = decode(attr(img[1], "alt") ?? "");
        if (src) push({ kind: "image", src, alt });
        else if (alt) push({ kind: "text", text: alt });
        i += img[0].length;
        continue;
      }
      // any other tag is dropped and its text kept
      const tag = /^<\/?[A-Za-z][A-Za-z0-9-]*(?:\s[^<>]*)?\/?>/.exec(rest);
      if (tag) {
        i += tag[0].length;
        continue;
      }
    }
    if (c === "*" || c === "_" || c === "~") {
      const e = emphasisAt(scan, i, refs, inLink);
      if (e) {
        push(e.node);
        i = e.end;
        continue;
      }
    }
    if (!inLink && (i === 0 || /[\s(*_~]/.test(s[i - 1])) && (c === "h" || c === "H" || c === "w" || c === "W")) {
      const url = /^(?:https?:\/\/|www\.)[^\s<]+/i.exec(s.slice(i, i + 4000));
      if (url) {
        const u = trimUrl(url[0]);
        push({ kind: "link", href: /^www\./i.test(u) ? "http://" + u : u, children: [{ kind: "text", text: u }] });
        i += u.length;
        continue;
      }
    }
    if (refs && !inLink && (c === "#" || c === "!" || c === "@") && (i === 0 || /[\s([{,;:'"]/.test(s[i - 1]))) {
      const rest = s.slice(i, i + 300);
      const ref = /^([#!])(\d+)(?![\p{L}\p{N}_])/u.exec(rest);
      if (ref && (ref[1] === "#" || refs.request)) {
        push({ kind: "link", href: ref[1] === "#" ? refs.issue(ref[2]) : refs.request!(ref[2]), children: [{ kind: "text", text: ref[0] }] });
        i += ref[0].length;
        continue;
      }
      const user = /^@([A-Za-z0-9_](?:[A-Za-z0-9_.-]*[A-Za-z0-9_])?)(?![A-Za-z0-9_@])/.exec(rest);
      if (user) {
        push({ kind: "link", href: refs.user(user[1]), children: [{ kind: "text", text: user[0] }] });
        i += user[0].length;
        continue;
      }
    }
    text += c;
    i++;
  }
  flush();
  return out;
}

/** [text](href "title") starting at s[i] === "[" */
function linkAt(scan: Scan, i: number): { text: string; href: string; end: number } | null {
  const s = scan.s;
  const j = scan.bracketFor(i);
  if (j < 0 || s[j + 1] !== "(") return null;
  let k = j + 2;
  while (s[k] === " ") k++;
  let href = "";
  if (s[k] === "<") {
    const close = s.indexOf(">", k);
    if (close < 0) return null;
    href = s.slice(k + 1, close);
    k = close + 1;
  } else {
    let parens = 0;
    for (; k < s.length; k++) {
      const c = s[k];
      if (/\s/.test(c)) break;
      if (c === "\\" && k + 1 < s.length) {
        href += s[++k];
        continue;
      }
      if (c === "(") parens++;
      if (c === ")" && parens-- === 0) break;
      href += c;
    }
  }
  const title = /^\s*(?:"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\((?:[^)\\]|\\.)*\))?\s*\)/.exec(s.slice(k, k + 2000));
  if (!title) return null;
  return { text: s.slice(i + 1, j), href: decode(href), end: k + title[0].length };
}

/** Same delimiter run on both sides: *em*, **strong**, ***both***, ~strike~, ~~strike~~ */
function emphasisAt(scan: Scan, i: number, refs: MdRefs | undefined, inLink: boolean): { node: MdInline; end: number } | null {
  const s = scan.s;
  const c = s[i];
  let run = 0;
  while (s[i + run] === c) run++;
  const next = s[i + run];
  if (!next || /\s/.test(next)) return null;
  if (c === "_" && i > 0 && wordRe.test(s[i - 1])) return null;
  if (c === "~" && run > 2) return null;
  for (let n = c === "~" ? run : Math.min(run, 3); n >= 1; n--) {
    const end = scan.closingRun(i + n, c, n);
    if (end < 0) continue;
    const inner = inlines(s.slice(i + n, end), refs, inLink);
    let node: MdInline;
    if (c === "~") node = { kind: "strike", children: inner };
    else if (n === 3) node = { kind: "strong", children: [{ kind: "em", children: inner }] };
    else node = { kind: n === 2 ? "strong" : "em", children: inner };
    return { node, end: end + n };
  }
  return null;
}

/** Drop trailing punctuation and unbalanced ")" the way GitHub does */
function trimUrl(u: string) {
  for (;;) {
    const last = u[u.length - 1];
    if (/[?!.,:*_~'";]/.test(last)) u = u.slice(0, -1);
    else if (last === ")" && (u.match(/\(/g) ?? []).length < (u.match(/\)/g) ?? []).length) u = u.slice(0, -1);
    else return u;
  }
}

function attr(attrs: string, name: string) {
  const m = new RegExp(`(?:^|\\s)${name}\\s*=\\s*(?:"([^"]*)"|'([^']*)'|([^\\s"'>]+))`, "i").exec(attrs);
  return m ? (m[1] ?? m[2] ?? m[3]) : null;
}

function plain(nodes: MdInline[]): string {
  return nodes.map((n) => (n.kind === "text" || n.kind === "code" ? n.text : n.kind === "break" ? " " : n.kind === "image" ? n.alt : plain(n.children))).join("");
}

/** Lines holding only tags (<p align="center">) leave nothing or stray line breaks behind */
export function trimBreaks(nodes: MdInline[]) {
  const visible = (n: MdInline) => n.kind !== "break" && !(n.kind === "text" && !n.text.trim());
  let a = 0;
  let b = nodes.length;
  while (a < b && !visible(nodes[a])) a++;
  while (b > a && !visible(nodes[b - 1])) b--;
  return nodes.slice(a, b);
}
