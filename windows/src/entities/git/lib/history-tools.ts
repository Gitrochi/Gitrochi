import { ipc } from "@/shared/api";
import { joinPath } from "@/shared/config";
import { t } from "@/shared/i18n";

export type BatchCommitAction = "cherry-pick" | "revert" | "squash" | "drop";
export interface BatchCommitItem { sha: string; parents: string[]; subject: string; author: string; message: string }
export interface LineHistoryEntry { sha: string; author: string; date: string; subject: string; patch: string }
/** 입력은 rev-parse로 한 번만 해석하고 이후 작업에는 고정된 객체 ID만 사용한다. */
export function validRevisionInput(value: string): boolean {
  return !!value.trim() && value.length <= 1024 && !value.startsWith("-") && !/[\x00-\x20\x7f]/.test(value);
}
export const fullObjectID = (value: string) => /^(?:[a-f0-9]{40}|[a-f0-9]{64})$/i.test(value);
export function lineHistoryRange(path: string, start: number, end: number, functionName = ""): string {
  if (!path || /[\x00\r\n]/.test(path)) throw new Error(t("Choose a committed file."));
  if (functionName.trim()) {
    if (functionName.length > 200 || /[:\r\n\x00]/.test(functionName)) throw new Error(t("Enter a function name without colons or newlines."));
    const escaped = functionName.trim().replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    return `:${escaped}:${path}`;
  }
  if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 1 || end < start || end > 10_000_000) throw new Error(t("Enter a valid line range (1 or greater)."));
  return `${start},${end}:${path}`;
}
export function parseLineHistory(output: string): LineHistoryEntry[] {
  return output.split("\x1e").flatMap((record) => {
    const nl = record.indexOf("\n");
    const fields = (nl < 0 ? record : record.slice(0, nl)).trim().split("\x1f");
    if (fields.length < 4 || !fullObjectID(fields[0])) return [];
    return [{ sha: fields[0], author: fields[1], date: fields[2], subject: fields.slice(3).join("\x1f"), patch: nl < 0 ? "" : record.slice(nl + 1) }];
  });
}
/** A commit on the Compare page's Commits tab; date in seconds. macOS: ComparisonCommit */
export interface ComparisonCommit { id: string; author: string; date: number | null; subject: string }
/** A branch or tag the Compare page offers to compare with the current branch. macOS: ComparisonReference */
export interface ComparisonReference { name: string; kind: "branch" | "remote" | "tag" }
/** The Compare page's Commits tab lists this many and counts "200+" past it */
export const comparisonCommitLimit = 200;
/** The commits To has that the base lacks, newest first, and one more so the count knows there are more. macOS: HistoryTools.comparisonLogArgs */
export const comparisonLogArgs = (base: string, right: string): string[] =>
  ["log", "-n", String(comparisonCommitLimit + 1), "--format=%H%x1f%an%x1f%ct%x1f%s%x1e", `${base}..${right}`, "--"];
export function parseComparisonCommits(output: string): ComparisonCommit[] {
  return output.split("\x1e").flatMap((record) => {
    const fields = record.replace(/^[\r\n]+|[\r\n]+$/g, "").split("\x1f");
    if (fields.length < 4 || !fullObjectID(fields[0])) return [];
    return [{ id: fields[0], author: fields[1], date: /^\d+$/.test(fields[2]) ? Number(fields[2]) : null, subject: fields.slice(3).join("\x1f") }];
  });
}
export const commitCountLabel = (count: number): string => (count > comparisonCommitLimit ? `${comparisonCommitLimit}+` : String(count));
/**
 * The list beside "Compare with the current branch": the usual bases first, then local branches, remote branches and
 * tags, without the current branch or a remote's HEAD. macOS: HistoryTools.comparisonReferences
 */
export function comparisonReferences(local: string[], remote: string[], tags: string[], current: string | null): ComparisonReference[] {
  const found: ComparisonReference[] = [
    ...local.filter((name) => name !== current).map((name) => ({ name, kind: "branch" as const })),
    ...remote.filter((name) => !name.endsWith("/HEAD")).map((name) => ({ name, kind: "remote" as const })),
    ...tags.map((name) => ({ name, kind: "tag" as const })),
  ];
  const usual = ["origin/main", "main", "origin/master", "master"];
  const rank = (reference: ComparisonReference) => {
    const index = reference.kind === "tag" ? -1 : usual.indexOf(reference.name);
    return index >= 0 ? index : usual.length + (reference.kind === "branch" ? 0 : reference.kind === "remote" ? 1 : 2);
  };
  return found.map((reference, index) => ({ reference, index })).sort((a, b) => rank(a.reference) - rank(b.reference) || a.index - b.index).map(({ reference }) => reference);
}
export const referenceMatches = (name: string, filter: string): boolean => !filter.trim() || name.toLowerCase().includes(filter.trim().toLowerCase());
/**
 * What a comparison depends on: both sides, the mode, and where HEAD and the two sides' refs point, so a branch that
 * moves compares again. macOS: HistoryTools.comparisonKey
 */
export const comparisonKey = (repository: string, left: string, right: string, mergeBase: boolean, head: string | null, targets: ReadonlyMap<string, string>): string =>
  [repository, left, right, mergeBase ? "ancestor" : "direct", head ?? "", targets.get(left) ?? "", targets.get(right) ?? ""].join("\0");
/** 그래프 순서와 무관하게 사용자가 실행 순서를 검토하고 바꿀 수 있다. */
export function toggleGraphSelection(ids: string[], selected: string[], anchor: string | null, sha: string, extend: boolean, toggle: boolean): string[] {
  if (extend && anchor && ids.includes(anchor) && ids.includes(sha)) {
    const a = ids.indexOf(anchor), b = ids.indexOf(sha);
    const range = ids.slice(Math.min(a, b), Math.max(a, b) + 1);
    return toggle ? [...new Set([...selected, ...range])] : range;
  }
  if (toggle) return selected.includes(sha) ? selected.filter((id) => id !== sha) : [...selected, sha];
  return [sha];
}
export function batchArguments(action: BatchCommitAction, items: BatchCommitItem[]): string[] {
  if (!items.length || items.some((item) => !fullObjectID(item.sha))) throw new Error(t("Select at least one commit."));
  if (items.some((item) => item.parents.length > 1)) throw new Error(t("Merge commits need a mainline choice. Select non-merge commits."));
  if (action === "cherry-pick") return ["cherry-pick", ...items.map((item) => item.sha)];
  if (action === "revert") return ["revert", "--no-edit", ...items.map((item) => item.sha)];
  throw new Error(t("Use the cleanup plan for squash or drop."));
}

/** 캐시된 화면 상태와 별개로 진행 중 작업의 실제 표식을 확인한다. */
export async function historyOperationInProgress(gitDir: string): Promise<boolean> {
  const flags = await Promise.all(["rebase-merge", "rebase-apply", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "sequencer"].map((name) => ipc.exists(joinPath(gitDir, name))));
  return flags.some(Boolean);
}
