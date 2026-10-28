import type { RepositoryTreeEntry } from "@/entities/git";

export interface RepositoryLanguage { name: string; files: number; bytes: number; share: number; color: string }
export interface RepositoryLanguageSummary { languages: RepositoryLanguage[]; files: number; bytes: number }
const languages: Record<string, string> = {
  ts: "TypeScript", tsx: "TypeScript", mts: "TypeScript", cts: "TypeScript", js: "JavaScript", jsx: "JavaScript", mjs: "JavaScript", cjs: "JavaScript",
  md: "Markdown", markdown: "Markdown", rst: "reStructuredText", txt: "Plain text", log: "Plain text", json: "JSON", jsonc: "JSON", jsonl: "JSON", yml: "YAML", yaml: "YAML", toml: "TOML",
  ini: "Configuration", cfg: "Configuration", conf: "Configuration", properties: "Configuration", html: "HTML", htm: "HTML", css: "CSS", scss: "SCSS", sass: "Sass", less: "Less", xml: "XML", svg: "SVG", vue: "Vue", svelte: "Svelte", csv: "CSV", tsv: "TSV",
  swift: "Swift", rs: "Rust", py: "Python", pyi: "Python", go: "Go", java: "Java", kt: "Kotlin", kts: "Kotlin", cs: "C#", c: "C", h: "C", cpp: "C++", cc: "C++", hpp: "C++", m: "Objective-C", mm: "Objective-C++", rb: "Ruby", php: "PHP", dart: "Dart",
  sh: "Shell", bash: "Shell", zsh: "Shell", fish: "Shell", ps1: "PowerShell", sql: "SQL",
};

/** macOS: RepositoryLanguages normalizes JSX/TSX and counts regular tracked files only. */
export function repositoryLanguage(path: string): string {
  const name = path.split("/").at(-1)?.toLowerCase() ?? "", dot = name.lastIndexOf("."), extension = dot > 0 ? name.slice(dot + 1) : "";
  if (["dockerfile", "containerfile"].includes(name)) return "Dockerfile";
  if (["makefile", "gnumakefile"].includes(name)) return "Makefile";
  if ([".gitignore", ".gitattributes", ".editorconfig", ".npmrc", ".nvmrc"].includes(name)) return "Configuration";
  return languages[extension] ?? "Other files";
}

export function repositoryLanguageColor(name: string): string {
  if (["TypeScript", "Java", "C", "C++"].includes(name)) return "var(--accent)";
  if (["Swift", "JavaScript", "HTML", "Rust"].includes(name)) return "var(--orange)";
  if (["Python", "Go", "Shell", "CSS", "SCSS"].includes(name)) return "var(--green)";
  if (["JSON", "YAML", "TOML", "XML"].includes(name)) return "color-mix(in srgb, var(--accent) 60%, var(--green))";
  if (["Markdown", "Plain text", "Configuration"].includes(name)) return "var(--text-2)";
  if (name === "Other files") return "var(--border-strong)";
  return "color-mix(in srgb, var(--accent) 65%, var(--orange))";
}

export function summarizeRepositoryLanguages(entries: RepositoryTreeEntry[]): RepositoryLanguageSummary {
  const groups = new Map<string, { files: number; bytes: number }>();
  let files = 0, bytes = 0;
  for (const entry of entries) {
    if (entry.kind !== "file") continue;
    const name = repositoryLanguage(entry.path), size = Number.isSafeInteger(entry.size) && entry.size > 0 ? entry.size : 0, value = groups.get(name) ?? { files: 0, bytes: 0 };
    value.files++; value.bytes += size; files++; bytes += size; groups.set(name, value);
  }
  return { files, bytes, languages: [...groups].map(([name, value]) => ({ name, ...value, share: files ? value.files / files : 0, color: repositoryLanguageColor(name) })).sort((a, b) => b.files - a.files || a.name.localeCompare(b.name)) };
}

export function formatRepositoryBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes.toLocaleString()} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toLocaleString(undefined, { maximumFractionDigits: 1 })} KB`;
  return `${(bytes / (1024 * 1024)).toLocaleString(undefined, { maximumFractionDigits: 1 })} MB`;
}
