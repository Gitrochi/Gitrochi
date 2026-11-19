/**
 * What a Ctrl-click in a terminal points at: web addresses and words that look like file paths (`schema.sql`,
 * `src/app.ts:12`, `C:\work\notes.md`). Whether such a file exists is asked later, from the shell's folder.
 * macOS: Core/TerminalWord.swift
 */

/** Characters that end a word: spaces, quotes and brackets around a path in tool output */
const boundary = /[\s"'`()[\]{}<>|,;\u0000-\u001f\u007f]/;

export type LinkToken = { start: number; end: number; text: string };

/** The clickable words of a line, as [start, end) indices into it */
export function linkTokens(line: string): LinkToken[] {
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
