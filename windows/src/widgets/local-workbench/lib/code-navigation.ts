export type CodeViewMode = "Source" | "File history" | "Blame" | "Working changes";
export interface CodeLocation { path: string; mode: CodeViewMode }
export interface CodeNavigation { tabs: CodeLocation[]; recent: string[]; history: CodeLocation[]; cursor: number }
export interface CodeSymbol { name: string; line: number; kind: "function" | "type" | "heading" }
export const codeTabLimit = 12, codeRecentLimit = 20, codeHistoryLimit = 50, quickOpenLimit = 50, codeSymbolLimit = 200;

export const emptyCodeNavigation = (): CodeNavigation => ({ tabs: [], recent: [], history: [], cursor: -1 });
const sameLocation = (a: CodeLocation | undefined, b: CodeLocation) => a?.path === b.path && a.mode === b.mode;

/** macOS: RepositoryCodeNavigation mirrors these session-only bounds and branching rules. */
export function visitCodeLocation(state: CodeNavigation, location: CodeLocation, recordHistory = true): CodeNavigation {
  const tabs = state.tabs.some((tab) => tab.path === location.path)
    ? state.tabs.map((tab) => tab.path === location.path ? location : tab)
    : [...state.tabs, location].slice(-codeTabLimit);
  const recent = [location.path, ...state.recent.filter((path) => path !== location.path)].slice(0, codeRecentLimit);
  if (!recordHistory || sameLocation(state.history[state.cursor], location)) return { ...state, tabs, recent };
  const history = [...state.history.slice(0, state.cursor + 1), location].slice(-codeHistoryLimit);
  return { tabs, recent, history, cursor: history.length - 1 };
}

export function stepCodeHistory(state: CodeNavigation, delta: number): { state: CodeNavigation; location: CodeLocation | null } {
  const cursor = state.cursor + delta;
  if (cursor < 0 || cursor >= state.history.length) return { state, location: null };
  return { state: { ...state, cursor }, location: state.history[cursor] };
}

export function closeCodeFile(state: CodeNavigation, path: string, activePath: string | null): { state: CodeNavigation; next: CodeLocation | null } {
  const index = state.tabs.findIndex((tab) => tab.path === path), tabs = state.tabs.filter((tab) => tab.path !== path);
  return { state: { ...state, tabs }, next: path === activePath ? tabs[Math.min(Math.max(0, index), tabs.length - 1)] ?? null : null };
}

/** Empty queries show recent files; named queries favor the basename before directory matches. */
export function rankCodeFiles<T extends { path: string }>(entries: T[], query: string, recent: string[]): T[] {
  const needle = query.trim().toLowerCase();
  if (!needle) {
    const byPath = new Map(entries.map((entry) => [entry.path, entry]));
    return recent.flatMap((path) => byPath.get(path) ? [byPath.get(path)!] : []).slice(0, quickOpenLimit);
  }
  const words = needle.split(/\s+/);
  return entries.flatMap((entry) => {
    const path = entry.path.toLowerCase(), name = path.split("/").at(-1)!;
    const score = name === needle ? 0 : name.startsWith(needle) ? 1 : name.includes(needle) ? 2 : path.includes(needle) ? 3 : words.every((word) => path.includes(word)) ? 4 : -1;
    return score < 0 ? [] : [{ entry, score }];
  }).sort((a, b) => a.score - b.score || a.entry.path.length - b.entry.path.length || a.entry.path.localeCompare(b.entry.path)).slice(0, quickOpenLimit).map(({ entry }) => entry);
}

export function codeLineRange(text: string, line: number): { start: number; end: number } | null {
  if (!Number.isSafeInteger(line) || line < 1 || !text) return null;
  let current = 1, start = 0;
  while (current < line) {
    const newline = text.indexOf("\n", start);
    if (newline < 0 || newline + 1 >= text.length) return null;
    start = newline + 1; current++;
  }
  const newline = text.indexOf("\n", start);
  return { start, end: newline < 0 ? text.length : newline + 1 };
}

interface OutlineLexicalState { blockComment: boolean; quote: string }
const hashCommentLanguages = new Set(["Python", "Ruby", "Shell", "YAML", "TOML"]);

function outlineCodeLine(line: string, state: OutlineLexicalState, language: string): string {
  let result = "";
  for (let i = 0; i < line.length;) {
    if (state.blockComment) {
      const end = line.indexOf("*/", i);
      if (end < 0) break;
      state.blockComment = false; i = end + 2; continue;
    }
    if (state.quote) {
      if (line[i] === "\\") { i += 2; continue; }
      if (line.startsWith(state.quote, i)) { i += state.quote.length; state.quote = ""; continue; }
      i++; continue;
    }
    if (line.startsWith("//", i) || (line[i] === "#" && hashCommentLanguages.has(language))) break;
    if (line.startsWith("/*", i)) { state.blockComment = true; i += 2; continue; }
    const quote = line.startsWith('"""', i) ? '"""' : line.startsWith("'''", i) ? "'''" : ['"', "'", "`"].includes(line[i]) ? line[i] : "";
    if (quote) { state.quote = quote; if (result.length < 2000) result += " "; i += quote.length; continue; }
    if (result.length < 2000) result += line[i];
    i++;
  }
  if (state.quote.length === 1 && state.quote !== "`") state.quote = "";
  return result.trim();
}

/** A compact declaration outline, not a language parser; skips strings, comments and fenced examples. */
export function codeOutline(text: string, language: string): CodeSymbol[] {
  if (["Plain text", "JSON", "CSS", "SCSS", "HTML", "XML", "YAML", "TOML"].includes(language)) return [];
  const symbols: CodeSymbol[] = [], lexical: OutlineLexicalState = { blockComment: false, quote: "" };
  let fence = "", fenceLength = 0, lineNumber = 0, start = 0;
  while (start < text.length && symbols.length < codeSymbolLimit) {
    const newline = text.indexOf("\n", start), end = newline < 0 ? text.length : newline;
    const raw = text.slice(start, end); start = end + 1; lineNumber++;
    let line = raw.trim();
    if (language === "Markdown") {
      const marker = line.match(/^(`{3,}|~{3,})(.*)$/);
      if (marker) {
        if (!fence) { fence = marker[1][0]; fenceLength = marker[1].length; }
        else if (fence === marker[1][0] && marker[1].length >= fenceLength && !marker[2].trim()) fence = "";
        continue;
      }
      const heading = !fence && !/^(?: {4}|	)/.test(raw) && line.slice(0, 2000).match(/^#{1,6}[ 	]+(.+?)(?:[ 	]+#+)?[ 	]*$/);
      if (heading) symbols.push({ name: heading[1].slice(0, 120), line: lineNumber, kind: "heading" });
      continue;
    }
    line = outlineCodeLine(raw, lexical, language);
    if (!line) continue;
    const type = line.match(/^(?:(?:export|default|public|private|protected|internal|open|final|abstract|sealed|data|pub|static)\s+)*(?:class|struct|interface|enum|protocol|type|typealias|trait|extension)\s+([\p{L}_$][\p{L}\p{N}_$.]*)/u);
    const method = line.match(/^(?:(?:export|default|public|private|protected|internal|open|final|override|static|async|pub|unsafe|suspend|mutating|nonmutating)\s+)*(?:function\s*\*?\s*|func\s+|fn\s+|def\s+|fun\s+)([\p{L}_$][\p{L}\p{N}_$]*)/u);
    const arrow = line.match(/^(?:export\s+)?(?:const|let|var)\s+([\p{L}_$][\p{L}\p{N}_$]*)\s*(?::[^=]+)?=\s*(?:async\s+)?(?:function\b|(?:\([^;]*\)|[\p{L}_$][\p{L}\p{N}_$]*)\s*(?::[^=]+)?=>)/u);
    const match = type ?? method ?? arrow;
    if (match) symbols.push({ name: match[1].slice(0, 120), line: lineNumber, kind: type ? "type" : "function" });
  }
  return symbols;
}
