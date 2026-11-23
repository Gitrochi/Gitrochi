/**
 * Which icon and colour a file gets, from its name: a language's own colour for source code, a type's shape for data,
 * images, archives and the like, grey for the rest. (macOS: Core/FileIcons.swift)
 */

export type FileIconKind = "code" | "style" | "json" | "config" | "markdown" | "text" | "sql" | "shell" | "image" | "archive" | "pdf" | "lock" | "git" | "docker" | "file";
export interface FileIcon { kind: FileIconKind; /** A hex colour, or null for the caption grey */ color: string | null }

const code = (color: string): FileIcon => ({ kind: "code", color });
const byExtension: Record<string, FileIcon> = {
  swift: code("#f05138"), ts: code("#3178c6"), tsx: code("#3178c6"), mts: code("#3178c6"), cts: code("#3178c6"),
  js: code("#d4a017"), jsx: code("#d4a017"), mjs: code("#d4a017"), cjs: code("#d4a017"),
  rs: code("#ce422b"), py: code("#3776ab"), go: code("#00add8"), java: code("#b07219"), kt: code("#7f52ff"), kts: code("#7f52ff"),
  c: code("#5c6bc0"), h: code("#5c6bc0"), cpp: code("#00599c"), cc: code("#00599c"), hpp: code("#00599c"), m: code("#438eff"), mm: code("#438eff"),
  cs: code("#239120"), rb: code("#cc342d"), php: code("#777bb4"), dart: code("#0175c2"), scala: code("#dc322f"), lua: code("#51a0cf"),
  vue: code("#41b883"), svelte: code("#ff3e00"), html: code("#e34c26"), htm: code("#e34c26"), xml: code("#e37933"), zig: code("#f7a41d"),
  css: { kind: "style", color: "#663399" }, scss: { kind: "style", color: "#cc6699" }, sass: { kind: "style", color: "#cc6699" }, less: { kind: "style", color: "#4a6fa5" },
  json: { kind: "json", color: "#c09000" }, jsonc: { kind: "json", color: "#c09000" }, json5: { kind: "json", color: "#c09000" },
  yml: { kind: "config", color: "#cb171e" }, yaml: { kind: "config", color: "#cb171e" }, toml: { kind: "config", color: "#9c4221" },
  ini: { kind: "config", color: null }, conf: { kind: "config", color: null }, env: { kind: "config", color: null }, plist: { kind: "config", color: null },
  md: { kind: "markdown", color: "#519aba" }, markdown: { kind: "markdown", color: "#519aba" }, mdx: { kind: "markdown", color: "#519aba" },
  txt: { kind: "text", color: null }, log: { kind: "text", color: null }, csv: { kind: "text", color: "#217346" }, tsv: { kind: "text", color: "#217346" },
  sql: { kind: "sql", color: "#e38c00" },
  sh: { kind: "shell", color: "#4eaa25" }, bash: { kind: "shell", color: "#4eaa25" }, zsh: { kind: "shell", color: "#4eaa25" }, fish: { kind: "shell", color: "#4eaa25" },
  ps1: { kind: "shell", color: "#2671be" }, bat: { kind: "shell", color: "#2671be" }, cmd: { kind: "shell", color: "#2671be" },
  png: { kind: "image", color: "#a074c4" }, jpg: { kind: "image", color: "#a074c4" }, jpeg: { kind: "image", color: "#a074c4" }, gif: { kind: "image", color: "#a074c4" },
  webp: { kind: "image", color: "#a074c4" }, svg: { kind: "image", color: "#ffb13b" }, ico: { kind: "image", color: "#a074c4" }, heic: { kind: "image", color: "#a074c4" },
  zip: { kind: "archive", color: "#8d6e63" }, tar: { kind: "archive", color: "#8d6e63" }, gz: { kind: "archive", color: "#8d6e63" }, tgz: { kind: "archive", color: "#8d6e63" },
  "7z": { kind: "archive", color: "#8d6e63" }, rar: { kind: "archive", color: "#8d6e63" }, dmg: { kind: "archive", color: "#8d6e63" },
  pdf: { kind: "pdf", color: "#e2574c" }, lock: { kind: "lock", color: null },
};
const byName: Record<string, FileIcon> = {
  dockerfile: { kind: "docker", color: "#2496ed" }, "docker-compose.yml": { kind: "docker", color: "#2496ed" }, "compose.yaml": { kind: "docker", color: "#2496ed" },
  makefile: { kind: "config", color: "#6d8086" }, ".gitignore": { kind: "git", color: "#f14e32" }, ".gitattributes": { kind: "git", color: "#f14e32" },
  ".gitmodules": { kind: "git", color: "#f14e32" }, "package-lock.json": { kind: "lock", color: null }, "pnpm-lock.yaml": { kind: "lock", color: null },
  "yarn.lock": { kind: "lock", color: null }, license: { kind: "text", color: null }, ".env": { kind: "config", color: null },
};

export function fileIcon(path: string): FileIcon {
  const name = (path.split(/[\\/]/).pop() ?? "").toLowerCase();
  if (byName[name]) return byName[name];
  if (name.startsWith("dockerfile")) return byName.dockerfile;
  if (name.startsWith(".env")) return byName[".env"];
  const dot = name.lastIndexOf(".");
  return (dot > 0 || (dot === 0 && name.length > 1) ? byExtension[name.slice(dot + 1)] : undefined) ?? { kind: "file", color: null };
}
