import type { CIStatus } from "@/entities/ci";
import type { PullRequest } from "@/entities/git";
import type { PullRequestReview, ReviewComment } from "@/entities/hosting";
import { t } from "@/shared/i18n";

// The rules of the Pull requests page, kept apart from the views so they can be tested. macOS: PullRequestPage.swift.

/** The list column, and the strip that stands in for it while it is hidden */
export const listWidth = 312, listStripWidth = 40;
/** At this detail width and below the Changed files tab is drawn compact */
export const compactWidth = 916;
/** Split needs a diff at least this wide */
export const splitMinimumWidth = 1000;
/** Below this detail width the one-row Changed files header cannot hold its title, tabs and actions, so the tall header stays */
export const oneRowMinimumWidth = 720;
/** A longer job log shows only this many last lines until the reader asks for the rest */
export const logTail = 200;

/** Compact: the file tree narrows, Show in graph and Open in browser move into the More menu, and a file row's +/- counts give way */
export const isCompact = (listShown: boolean, width: number) => listShown || width <= compactWidth;
export const treeWidth = (compact: boolean) => (compact ? 280 : 340);
export const splitAllowed = (diffWidth: number) => diffWidth >= splitMinimumWidth;
/** Changed files on the Pull requests page folds its header into one 44px row, when there is room for it */
export const headerInOneRow = (onPage: boolean, tab: string, width: number) => onPage && tab === "files" && width >= oneRowMinimumWidth;

/** docs/design.md › Text: "2h ago" within 24 hours, then "Yesterday", then "Oct 28" */
export const dateStyle = (ageSeconds: number): "relative" | "yesterday" | "day" => (ageSeconds < 86_400 ? "relative" : ageSeconds < 2 * 86_400 ? "yesterday" : "day");

export type RequestSort = "updated" | "newest" | "comments";

/** The list in the chosen order; "updated" is the order the server sent */
export function sorted(requests: PullRequest[], by: RequestSort): PullRequest[] {
  if (by === "newest") return [...requests].sort((a, b) => b.number - a.number);
  // Array.prototype.sort is stable, so equal and unknown counts keep the loaded order
  if (by === "comments") return [...requests].sort((a, b) => (b.comments ?? -1) - (a.comments ?? -1));
  return requests;
}

export const reviewRequestedCount = (requests: PullRequest[]) => requests.filter((request) => request.reviewRequested).length;

/** The comment count a row shows: the list's own, else the open review's; null draws nothing */
export function commentCount(request: PullRequest, review: PullRequestReview | null | undefined): number | null {
  if (request.comments != null) return request.comments;
  if (review && review.number === request.number) return review.comments.filter((comment) => comment.kind !== "system").length;
  return null;
}

/** The request is for the branch that is checked out */
export const isThisBranch = (request: PullRequest, currentBranch: string | null | undefined) => !!currentBranch && !request.fromFork && request.source === currentBranch;

/** "This branch → main", or "source → target" for any other branch */
export function branchLabel(request: PullRequest, currentBranch: string | null | undefined): string {
  const head = isThisBranch(request, currentBranch) ? t("This branch") : request.source;
  return `${head} → ${request.target}${request.fromFork ? ` (${t("fork")})` : ""}`;
}

/** The last two folders of a path, "…/" in front when more were dropped; "" for a file at the root */
export function folderLabel(path: string): string {
  const folders = path.split("/").slice(0, -1);
  if (folders.length <= 2) return folders.join("/");
  return "…/" + folders.slice(-2).join("/");
}

interface Check { status: CIStatus }

/** Failed checks, the ones that have not finished, and the ones that need no attention */
export function checkGroups<T extends Check>(checks: T[]): { failed: T[]; running: T[]; passed: T[] } {
  const passed = (status: CIStatus) => status === "success" || status === "neutral" || status === "skipped";
  return {
    failed: checks.filter((check) => check.status === "failed"),
    running: checks.filter((check) => check.status !== "failed" && !passed(check.status)),
    passed: checks.filter((check) => passed(check.status)),
  };
}

/** What the Checks tab counts: failures first, else what still runs; nothing when everything passed */
export function checksBadge(checks: Check[]): { kind: "failed" | "running"; count: number } | null {
  const groups = checkGroups(checks);
  if (groups.failed.length) return { kind: "failed", count: groups.failed.length };
  if (groups.running.length) return { kind: "running", count: groups.running.length };
  return null;
}

export interface LogLine { n: number; text: string; isError: boolean }

const errorLine = /\berror\b|\bfailed\b|failure|fatal|exit code [1-9]/i;

/** A job log as numbered lines; the ones that report a failure are marked */
export function logLines(body: string): LogLine[] {
  const lines = body.replace(/\r\n?/g, "\n").split("\n");
  if (lines.length > 1 && lines[lines.length - 1] === "") lines.pop();
  return lines.map((text, index) => ({ n: index + 1, text, isError: errorLine.test(text) }));
}

/** The number of the first line that reports a failure */
export const firstError = (lines: LogLine[]): number | null => lines.find((line) => line.isError)?.n ?? null;

/** The lines a log shows: the last `logTail` until the reader asks for all of them */
export function logWindow(lines: LogLine[], all: boolean): { shown: LogLine[]; earlier: number } {
  if (all || lines.length <= logTail) return { shown: lines, earlier: 0 };
  return { shown: lines.slice(-logTail), earlier: lines.length - logTail };
}

/** The issues a description closes ("Closes #42", "fixes #7"), in order and once each */
export function linkedIssues(body: string): number[] {
  const found: number[] = [];
  for (const match of body.matchAll(/\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s*:?\s+#(\d+)/gi)) {
    const number = Number(match[1]);
    if (number > 0 && !found.includes(number)) found.push(number);
  }
  return found;
}

/** How many review threads a file carries */
export function threadCount(comments: ReviewComment[], path: string): number {
  return new Set(comments.filter((comment) => comment.kind !== "system" && comment.path === path).map((comment) => comment.threadID ?? comment.id)).size;
}

/** The key of one request version's "Viewed" marks: a new push starts a new set */
export const viewedKey = (repositoryKey: string, number: number, headSHA: string) => `${repositoryKey}#${number}@${headSHA}`;

/** The stored marks with one file marked or unmarked; only the latest 40 request versions are kept on the device */
export function withViewed(marks: Record<string, string[]>, key: string, path: string, viewed: boolean): Record<string, string[]> {
  const paths = (marks[key] ?? []).filter((item) => item !== path);
  if (viewed) paths.push(path);
  const rest = Object.entries(marks).filter(([item]) => item !== key).slice(-39);
  return Object.fromEntries(paths.length ? [...rest, [key, paths]] : rest);
}

/** The job behind a check, read from its address (GitHub ".../actions/runs/R/job/J", GitLab ".../-/jobs/J") */
export function checkJob(url: string): { run: number | null; job: number } | null {
  const github = /\/actions\/runs\/(\d+)\/jobs?\/(\d+)/.exec(url);
  if (github) return { run: Number(github[1]), job: Number(github[2]) };
  const gitlab = /\/-\/jobs\/(\d+)/.exec(url);
  return gitlab ? { run: null, job: Number(gitlab[1]) } : null;
}
