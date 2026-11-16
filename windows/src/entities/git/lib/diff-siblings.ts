import type { DiffSource, FileChange, WorkingStatus } from "../model/types";
import { treeRows } from "./file-tree";

/**
 * The files the open diff was opened among, in the order their list draws them: the working changes (conflicts,
 * unstaged, staged) or the selected commit's files; the header's "2 / 6", J and K follow it. Other diffs have no list
 * beside them. macOS: DiffView.siblings
 */
export function diffSiblings(source: DiffSource, lists: { status: WorkingStatus; detailSha: string | null; detailFiles: FileChange[]; tree: boolean }): DiffSource[] {
  const ordered = (files: FileChange[]) => (lists.tree ? treeRows(files, new Set()).flatMap((row) => (row.kind === "file" ? [row.change] : [])) : files);
  if (source.kind === "working") {
    const { conflicted, unstaged, staged } = lists.status;
    return [...ordered(conflicted), ...ordered(unstaged), ...ordered(staged)].map((change) => ({ kind: "working", change }));
  }
  if (source.kind === "commit" && lists.detailSha === source.sha) return ordered(lists.detailFiles).map((change) => ({ kind: "commit", sha: source.sha, change, parent: source.parent }));
  return [];
}
