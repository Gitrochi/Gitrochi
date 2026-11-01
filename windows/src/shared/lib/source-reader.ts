export interface SourceToken { start: number; end: number; kind: "comment" | "string" | "keyword" | "number" | "type" }
export interface SourceMatch { start: number; end: number }
export const syntaxCharacterLimit = 200_000, syntaxTokenLimit = 12_000, sourceMatchLimit = 10_000, wrappingLineLimit = 5_000;

const languages: Record<string, string> = {
  swift: "Swift", ts: "TypeScript", tsx: "TypeScript JSX", js: "JavaScript", jsx: "JavaScript JSX",
  mjs: "JavaScript", cjs: "JavaScript", rs: "Rust", py: "Python", go: "Go", java: "Java", kt: "Kotlin",
  cs: "C#", c: "C", h: "C", cpp: "C++", hpp: "C++", json: "JSON", css: "CSS", scss: "SCSS",
  html: "HTML", xml: "XML", md: "Markdown", markdown: "Markdown", yml: "YAML", yaml: "YAML", toml: "TOML",
  sh: "Shell", bash: "Shell", zsh: "Shell", sql: "SQL", rb: "Ruby", php: "PHP", vue: "Vue", svelte: "Svelte",
};
const hashComments = new Set(["Python", "Ruby", "Shell", "YAML", "TOML"]);
const keywords = new Set(("as async await break case catch class const continue default defer do else enum export extension false final finally for from func function guard if impl import in init interface internal is let match module mut namespace new nil null of open override package private protected protocol pub public readonly repeat return self Self static struct super switch throw throws true try type typealias typeof undefined use val var void when where while with yield fn def pass raise except elif lambda None True False and or not select SELECT FROM WHERE INSERT UPDATE DELETE CREATE TABLE INTO VALUES").split(" "));

/** macOS: RepositorySourceView uses the same bounded, lightweight source colors. */
export function sourceLanguage(path: string): string {
  return languages[path.split(".").at(-1)?.toLowerCase() ?? ""] ?? "Plain text";
}

/** Preserve exact UTF-16 offsets so syntax and find ranges compose without changing source. */
export function sourceTokens(text: string, language: string): SourceToken[] {
  if (text.length > syntaxCharacterLimit || ["Plain text", "Markdown", "HTML", "XML"].includes(language)) return [];
  const pattern = hashComments.has(language)
    ? /#[^\r\n]*|"""[\s\S]*?"""|'''[\s\S]*?'''|"(?:\\[\s\S]|[^"\\])*"|'(?:\\[\s\S]|[^'\\])*'|`(?:\\[\s\S]|[^`\\])*`|\b(?:0[xX][\da-fA-F]+|\d+(?:\.\d+)?)\b|\b[A-Za-z_$][\w$]*\b/g
    : /\/\/[^\r\n]*|\/\*[\s\S]*?\*\/|"(?:\\[\s\S]|[^"\\])*"|'(?:\\[\s\S]|[^'\\])*'|`(?:\\[\s\S]|[^`\\])*`|\b(?:0[xX][\da-fA-F]+|\d+(?:\.\d+)?)\b|\b[A-Za-z_$][\w$]*\b/g;
  const tokens: SourceToken[] = [];
  for (const match of text.matchAll(pattern)) {
    const value = match[0], first = value[0];
    const kind = value.startsWith("//") || value.startsWith("/*") || first === "#" ? "comment"
      : first === '"' || first === "'" || first === "`" ? "string"
      : keywords.has(value) ? "keyword" : /^\d/.test(value) ? "number" : /^[A-Z][A-Za-z\d_]*$/.test(value) ? "type" : null;
    if (kind) tokens.push({ start: match.index, end: match.index + value.length, kind });
    if (tokens.length >= syntaxTokenLimit) return [];
  }
  return tokens;
}

/** Literal, case-insensitive search; escaped regex keeps Unicode offsets in the original string. */
export function sourceMatches(text: string, query: string): SourceMatch[] {
  if (!query || query.length > text.length) return [];
  let pattern: RegExp;
  try { pattern = new RegExp(query.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "giu"); }
  catch { return []; }
  const matches: SourceMatch[] = [];
  for (const match of text.matchAll(pattern)) {
    matches.push({ start: match.index, end: match.index + match[0].length });
    if (matches.length >= sourceMatchLimit) break;
  }
  return matches;
}

export function sourceLineCount(text: string): number {
  if (!text) return 0;
  let count = 0;
  for (let i = 0; i < text.length; i++) if (text[i] === "\n") count++;
  return count + (text.endsWith("\n") ? 0 : 1);
}
