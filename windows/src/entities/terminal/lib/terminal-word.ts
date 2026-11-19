/**
 * What a Ctrl-click in a terminal points at: web addresses and words that look like file paths (`schema.sql`,
 * `src/app.ts:12`, `C:\work\notes.md`). Whether such a file exists is asked later, from the shell's folder.
 * macOS: Core/TerminalWord.swift
 */

/** Characters that end a word: spaces, quotes and brackets around a path in tool output */
const boundary = /[\s"'`()[\]{}<>|,;\u0000-\u001f\u007f]/;

/**
 * A clickable span as [start, end) indices into its line. A path with spaces also carries `candidates`, longest
 * first: what the click tries in turn, since only the file system can tell where such a path ends.
 */
export type LinkToken = { start: number; end: number; text: string; candidates?: string[] };

/** The clickable words of a line; a path with spaces takes the place of the words it covers */
export function linkTokens(line: string): LinkToken[] {
  const spaced = spacedPaths(line);
  const words = wordTokens(line).filter((w) => !spaced.some((p) => w.start < p.end && p.start < w.end));
  return [...spaced, ...words].sort((a, b) => a.start - b.start);
}

function wordTokens(line: string): LinkToken[] {
  const tokens: LinkToken[] = [];
  let i = 0;
  while (i < line.length) {
    if (boundary.test(line[i])) {
      i++;
      continue;
    }
    let j = i;
    while (j < line.length && !boundary.test(line[j])) j++;
    let end = j;
    // a sentence's full stop or a trailing colon is not part of the path
    while (end > i && ".:".includes(line[end - 1])) end--;
    const text = line.slice(i, end);
    if (text && looksLinkable(text)) tokens.push({ start: i, end, text });
    i = j;
  }
  return tokens;
}

export function looksLinkable(text: string): boolean {
  if (/^https?:\/\/\S+$/i.test(text)) return true;
  if (/^[\d.:]+$/.test(text)) return false;
  // a path separator, or a name with an extension that has a letter (not v1.2.3)
  return /[\\/]/.test(text) || /\.\p{L}[\p{L}\d]*(?::\d+(?::\d+)?)?$/u.test(text);
}

/** Characters a path with spaces never runs across: quotes, pipes and redirections, tabs and control cells */
const spanStop = /["'`<>|\t\u0000-\u001f\u007f]/;

function rooted(line: string, i: number): boolean {
  if (i >= line.length || (i > 0 && !boundary.test(line[i - 1]))) return false;
  return /^(?:\/(?!\/)|~[\\/]|\.\.?[\\/]|[A-Za-z]:[\\/])/.test(line.slice(i, i + 3));
}

/**
 * Paths with spaces, from a rooted start (`/`, `~/`, `./`, `../`, `C:\`) across single spaces. As in Ghostty, a space
 * before another rooted start ends the path, and the text shown runs to the last file-like word (`name.ext`).
 * The click tries each shorter end too. macOS: TerminalWord.spanned
 */
export function spacedPaths(line: string, limit = 16): LinkToken[] {
  const breaks = (i: number) =>
    spanStop.test(line[i]) || (line[i] === " " && (i + 1 === line.length || line[i + 1] === " " || rooted(line, i + 1)));
  const tokens: LinkToken[] = [];
  let start = 0;
  while (start < line.length) {
    if (!rooted(line, start)) {
      start++;
      continue;
    }
    const ends: string[] = [];
    let end = start + 1;
    for (; end <= line.length && ends.length < limit; end++) {
      if (end === line.length || boundary.test(line[end])) {
        const text = line.slice(start, end).replace(/[.:,;]+$/, "");
        if (text && !ends.includes(text)) ends.push(text);
      }
      if (end === line.length || breaks(end)) break;
    }
    const candidates = ends.reverse();
    const shown = candidates.find((c) => /\.\p{L}[\p{L}\d]*$/u.test(c.split(/[\\/]/).pop() ?? ""));
    if (shown?.includes(" ")) {
      tokens.push({ start, end: start + shown.length, text: shown, candidates: candidates.slice(candidates.indexOf(shown)) });
      start += shown.length;
    } else start = end + 1;
  }
  return tokens;
}
