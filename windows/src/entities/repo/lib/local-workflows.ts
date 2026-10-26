/** 로컬 복구·대용량 파일·하위 저장소·문제 커밋 찾기의 양쪽 화면 계약. */
export interface RecoveryEntry { id: string; worktree: string; index: string; head: string; created: string }
export interface ReflogEntry { sha: string; selector: string; message: string; date: string }
export interface SubmoduleEntry { path: string; sha: string; status: string; url: string; configName: string }
export interface LfsLock { id: string; path: string; owner: string }
export interface LocalWorkflowState {
  loading: boolean; error: string | null; notice: string | null;
  recovery: RecoveryEntry[]; reflog: ReflogEntry[]; preview: string;
  lfsAvailable: boolean; lfsFiles: string; lfsPatterns: string; lfsLocks: LfsLock[];
  submodules: SubmoduleEntry[]; bisectActive: boolean; bisectLog: string; bisectCurrent: string; bisectResult: string;
}
export const emptyLocalWorkflows = (): LocalWorkflowState => ({ loading: false, error: null, notice: null, recovery: [], reflog: [], preview: "", lfsAvailable: false, lfsFiles: "", lfsPatterns: "", lfsLocks: [], submodules: [], bisectActive: false, bisectLog: "", bisectCurrent: "", bisectResult: "" });
export function safeRepoPath(path: string): boolean {
  return !!path && !path.startsWith("-") && !/^(?:[A-Za-z]:|[\\/])/.test(path) && !path.includes("\\") && !/[\u0000-\u001f]/.test(path) && !path.split("/").some((p) => !p || p === "." || p === ".." || p.toLowerCase() === ".git");
}
export function safeSubmoduleURL(url: string): boolean {
  if (!url || /[\s\0]/.test(url) || url.startsWith("-") || /^(?:file|ext):/i.test(url) || url.includes("%")) return false;
  if (/^https:\/\//i.test(url)) { try { const parsed = new URL(url); return !!parsed.hostname && !parsed.username && !parsed.password; } catch { return false; } }
  if (url.includes("://")) return /^ssh:\/\/(?:[A-Za-z0-9_.-]+@)?[A-Za-z0-9][A-Za-z0-9.-]*(?::[0-9]+)?\/.+/.test(url);
  return /^(?:[A-Za-z0-9_.-]+@)?[A-Za-z0-9][A-Za-z0-9.-]*:.+/.test(url);
}
export function parseReflog(output: string): ReflogEntry[] {
  return output.split("\n").flatMap((line) => { const [sha, selector, message, date] = line.split("\x1f"); return /^[a-f0-9]{40,64}$/.test(sha ?? "") && date ? [{ sha, selector, message, date }] : []; });
}
export function parseRecoveryRefs(output: string): RecoveryEntry[] {
  const groups = new Map<string, Partial<RecoveryEntry>>();
  for (const line of output.split("\n")) { const [ref, oid] = line.split(" "); const match = /^refs\/gitrochi\/safety\/(?:[a-f0-9]{40,64}\/)?([0-9]+-[a-z0-9-]+)\/(worktree|index|head)$/.exec(ref); if (!match || !/^[a-f0-9]{40,64}$/.test(oid ?? "")) continue; const value = groups.get(match[1]) ?? { id: match[1], created: new Date(Number(match[1].split("-")[0])).toISOString() }; value[match[2] as "worktree" | "index" | "head"] = oid; groups.set(match[1], value); }
  return [...groups.values()].filter((p): p is RecoveryEntry => !!p.id && !!p.worktree && !!p.index && !!p.head && !!p.created).sort((a, b) => b.id.localeCompare(a.id));
}
