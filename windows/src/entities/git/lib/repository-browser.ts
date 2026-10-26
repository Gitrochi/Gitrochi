import { t } from "@/shared/i18n";
import { git, gitBytes } from "@/shared/platform";
import { fullObjectID, validRevisionInput } from "./history-tools";

export interface RepositoryTreeEntry { path: string; mode: string; oid: string; size: number; kind: "file" | "symlink" | "submodule" }
export interface RepositoryTree { revision: string; entries: RepositoryTreeEntry[]; truncated: boolean }
export interface RepositoryBlob { text?: string; image?: string; notice?: string }
export const browserTextLimit = 2_000_000, browserImageLimit = 8_000_000, browserEntryLimit = 25_000;
export function safeRepositoryPath(path: string): boolean { return !!path && !path.startsWith("/") && !path.includes("\\") && !/[\x00-\x1f\x7f]/.test(path) && path.split("/").every((part) => part !== ".." && part !== "." && !!part); }
export function parseRepositoryTree(output: string): RepositoryTreeEntry[] {
  return output.split("\0").flatMap((record) => {
    const tab = record.indexOf("\t"); if (tab < 0) return [];
    const [mode, type, oid, bytes] = record.slice(0, tab).trim().split(/\s+/), path = record.slice(tab + 1), size = bytes === "-" ? 0 : Number(bytes);
    if (!safeRepositoryPath(path) || !fullObjectID(oid) || !["100644", "100755", "120000", "160000"].includes(mode) || !["blob", "commit"].includes(type) || !Number.isSafeInteger(size) || size < 0) return [];
    return [{ path, mode, oid, size, kind: mode === "120000" ? "symlink" as const : mode === "160000" ? "submodule" as const : "file" as const }];
  });
}
export function repositoryImageMime(bytes: Uint8Array): string | null {
  if ([137,80,78,71,13,10,26,10].every((value, i) => bytes[i] === value)) return "image/png";
  if (bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255) return "image/jpeg";
  const first = String.fromCharCode(...bytes.slice(0, 12));
  if (first.startsWith("GIF87a") || first.startsWith("GIF89a")) return "image/gif";
  if (first.startsWith("RIFF") && first.slice(8) === "WEBP") return "image/webp";
  return null;
}
/** 첫 화면은 커밋된 일반 문서/소스만 선택한다. 링크·서브모듈·대형 파일은 자동으로 읽지 않는다. */
export function initialRepositoryFile(entries: RepositoryTreeEntry[]): RepositoryTreeEntry | null {
  const safe = entries.filter(entry => entry.kind === "file" && entry.size <= browserTextLimit);
  const readme = safe.find(entry => /^readme(?:\.(?:md|markdown|rst|txt))?$/i.test(entry.path));
  const manifest = safe.find(entry => /^(?:package\.json|Package\.swift|Cargo\.toml|CONTRIBUTING\.md)$/i.test(entry.path));
  return readme ?? manifest ?? safe.find(entry => /\.(?:md|txt|rst|swift|tsx?|jsx?|rs|py|go|kt|java|cs|cpp|c|h)$/i.test(entry.path)) ?? null;
}
export function repositoryFolderCount(entries: RepositoryTreeEntry[]): number {
  const folders = new Set<string>(); for (const entry of entries) { const parts=entry.path.split("/"); for(let i=1;i<parts.length;i++)folders.add(parts.slice(0,i).join("/")); } return folders.size;
}
export async function loadRepositoryTree(cwd: string, ref: string): Promise<RepositoryTree> {
  if (!validRevisionInput(ref)) throw new Error(t("Enter a valid branch, tag or commit."));
  const revision = (await git(["rev-parse", "--verify", ref + "^{commit}"], cwd)).stdout.trim();
  if (!fullObjectID(revision)) throw new Error(t("Enter a valid branch, tag or commit."));
  const entries = parseRepositoryTree((await git(["ls-tree", "-r", "-z", "-l", revision, "--"], cwd)).stdout);
  return { revision, entries: entries.slice(0, browserEntryLimit), truncated: entries.length > browserEntryLimit };
}
export async function loadRepositoryBlob(cwd: string, entry: RepositoryTreeEntry): Promise<RepositoryBlob> {
  if (!safeRepositoryPath(entry.path) || !fullObjectID(entry.oid)) throw new Error(t("This file cannot be displayed safely."));
  if (entry.kind === "submodule") return { notice: t("Submodule commit"), text: entry.oid };
  if (entry.size > browserImageLimit) return { notice: t("This file exceeds the 8 MB preview limit.") };
  const size = Number((await git(["cat-file", "-s", entry.oid], cwd)).stdout.trim());
  if (!Number.isSafeInteger(size) || size !== entry.size || size > browserImageLimit) throw new Error(t("The file size changed. Reload this revision."));
  const base64 = await gitBytes(["cat-file", "blob", entry.oid], cwd); if (base64 == null) throw new Error(t("Couldn't read this file."));
  const bytes = Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
  if (bytes.length !== size) throw new Error(t("Couldn't read this file."));
  const mime = entry.kind === "file" ? repositoryImageMime(bytes) : null;
  if (mime) return { image: `data:${mime};base64,${base64}` };
  if (entry.size > browserTextLimit) return { notice: t("This text file exceeds the 2 MB preview limit.") };
  if (bytes.includes(0)) return { notice: t("Binary file. Text preview is unavailable.") };
  return { text: new TextDecoder("utf-8", { fatal: true }).decode(bytes), notice: entry.kind === "symlink" ? t("Symbolic link target. The link is never followed.") : undefined };
}
