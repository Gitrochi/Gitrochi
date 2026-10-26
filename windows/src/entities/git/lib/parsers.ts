import { runCore, runCoreAsync } from "@/shared/core";
import { t } from "@/shared/i18n";
import type { BlameLine, Branch, Commit, CommitDetail, DiffDocument, FileChange, FileHistoryEntry, LineStat, Stash, Tag, WorkingStatus, Worktree } from "../model/types";
import { rememberDiff, type SplitRow } from "./diff";

export const logFormat = "%H%x1f%P%x1f%an%x1f%ae%x1f%ct%x1f%s%x1f%b%x1e";
export const refFormat = "%(refname)%1f%(objectname)%1f%(*objectname)%1f%(upstream:short)%1f%(upstream:track,nobracket)%1f%(HEAD)";
export const detailFormat = "%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%cn%x1f%ce%x1f%ct%x1f%B";
export const stashFormat = "%gd%x1f%H%x1f%gs";
export const fileHistoryFormat = "%x1e%H%x1f%P%x1f%an%x1f%ae%x1f%ct%x1f%s";

/** 출력 해석은 Rust에 모으고 번역과 운영체제의 자연 정렬만 화면에 남긴다. */
export const parseLog = (text: string): Commit[] => runCore({ op: "log", text });
export const parseLogAsync = (text: string): Promise<Commit[]> => runCoreAsync({ op: "log", text });
export const bodyPreview = (text: string): string => runCore({ op: "bodyPreview", text });
export const parseCommitDetail = (text: string): CommitDetail | null => runCore({ op: "detail", text });
export const parseTrack = (text: string): { ahead: number; behind: number; gone: boolean } => runCore({ op: "track", text });
export function parseRefs(text: string): { locals: Branch[]; remotes: Branch[]; tags: Tag[] } {
  const refs = runCore<{ locals: Branch[]; remotes: Branch[]; tags: Tag[] }>({ op: "refs", text });
  refs.tags.sort((a, b) => b.name.localeCompare(a.name, undefined, { numeric: true, sensitivity: "base" }));
  return refs;
}
export const parseStashes = (text: string): Stash[] => runCore({ op: "stashes", text });
export const parseRemotes = (text: string): { names: string[]; urls: Record<string, string> } => runCore({ op: "remotes", text });
export const parseWorktrees = (text: string): Worktree[] => runCore({ op: "worktrees", text });
export const parseStatus = (text: string): WorkingStatus => runCore({ op: "status", text });
export const parseNameStatus = (text: string): FileChange[] => runCore({ op: "nameStatus", text });
export const parseNumstat = (text: string): Record<string, LineStat> => runCore({ op: "numstat", text });
export const parseFileHistory = (text: string): FileHistoryEntry[] => runCore({ op: "fileHistory", text });
export const parseBlame = (text: string): BlameLine[] => runCore({ op: "blame", text });
export const parseBlameAsync = (text: string): Promise<BlameLine[]> => runCoreAsync({ op: "blame", text });
export const parseFileHistoryAsync = (text: string): Promise<FileHistoryEntry[]> => runCoreAsync({ op: "fileHistory", text });

interface DiffBundle { doc: DiffDocument; rows: SplitRow[]; sides: { old: boolean; new: boolean } }
function hydrate(bundle: DiffBundle): DiffDocument {
  for (const line of bundle.doc.lines) if (line.kind === "meta") line.text = t("No newline at end of file");
  rememberDiff(bundle.doc.lines, bundle.rows, bundle.sides);
  return bundle.doc;
}
export const parseDiff = (text: string, maxLines = 20000): DiffDocument => hydrate(runCore({ op: "diffBundle", text, maxLines }));
export const parseDiffAsync = async (text: string, maxLines = 20000, signal?: AbortSignal): Promise<DiffDocument> => hydrate(await runCoreAsync({ op: "diffBundle", text, maxLines }, signal));
export const newFileDiff = (text: string, truncated: boolean, maxLines = 20000): DiffDocument => runCore({ op: "newFile", text, truncated, maxLines });
export const newFileDiffAsync = (text: string, truncated: boolean, maxLines = 20000, signal?: AbortSignal): Promise<DiffDocument> => runCoreAsync({ op: "newFile", text, truncated, maxLines }, signal);
