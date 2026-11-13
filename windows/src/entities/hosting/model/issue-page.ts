import { t } from "@/shared/i18n";

/**
 * What the Issues page says about the issues assigned to you (the redesign's Issues board): which are in review, in
 * progress or not started, and the one step that comes next. Nothing here asks the server: an issue's work is what this
 * repository knows of it, its linked local branches and their requests. (macOS: Core/IssuePage.swift)
 */
export type IssueProgress = "inReview" | "inProgress" | "notStarted";

/** An assigned issue and how far its work is; `branch` is the linked local branch, if there is one */
export interface AssignedIssue {
  number: number;
  progress: IssueProgress;
  branch?: string;
}

/** In review when one of the issue's branches has an open request, in progress when it has a branch, else not started */
export function issueProgress(branches: string[], requestBranches: Set<string>): IssueProgress {
  if (branches.some((branch) => requestBranches.has(branch))) return "inReview";
  return branches.length ? "inProgress" : "notStarted";
}

export interface IssueSummary {
  inReview: number[];
  inProgress: number[];
  notStarted: number[];
}

export function issueSummary(items: AssignedIssue[]): IssueSummary {
  const numbers = (progress: IssueProgress) => items.filter((item) => item.progress === progress).map((item) => item.number);
  return { inReview: numbers("inReview"), inProgress: numbers("inProgress"), notStarted: numbers("notStarted") };
}

/** Which state the summary card is in (macOS: IssuePage.SummaryCard) */
export type IssueSummaryCard = "loading" | "unreachable" | "empty" | "assigned";

/** `read` is false until the assigned issues arrived for this repository and account */
export function issueSummaryCard(read: boolean, failed: boolean, total: number): IssueSummaryCard {
  if (!read) return failed ? "unreachable" : "loading";
  return total === 0 ? "empty" : "assigned";
}

export const issueSummaryTotal = (summary: IssueSummary) => summary.inReview.length + summary.inProgress.length + summary.notStarted.length;

/** "#41", "#41 and #37", then a count: three numbers in a row are not read */
export function issueNumbers(list: number[]): string {
  if (list.length === 1) return `#${list[0]}`;
  if (list.length === 2) return t("{0} and {1}", `#${list[0]}`, `#${list[1]}`);
  return t("{0} issues", list.length);
}

/** The groups that have issues, the furthest along first, each in words: "#42 in review" */
export function issueSummaryLines(summary: IssueSummary): string[] {
  const out: string[] = [];
  if (summary.inReview.length) out.push(t("{0} in review", issueNumbers(summary.inReview)));
  if (summary.inProgress.length) out.push(t("{0} in progress", issueNumbers(summary.inProgress)));
  if (summary.notStarted.length) out.push(t("{0} not started", issueNumbers(summary.notStarted)));
  return out;
}

/** What a screen reader hears for the bar: "1 in review, 2 not started" */
export function issueSummaryCounts(summary: IssueSummary): string {
  const out: string[] = [];
  if (summary.inReview.length) out.push(t("{0} in review", summary.inReview.length));
  if (summary.inProgress.length) out.push(t("{0} in progress", summary.inProgress.length));
  if (summary.notStarted.length) out.push(t("{0} not started", summary.notStarted.length));
  return out.join(", ");
}

export type IssueNext = { kind: "createBranch"; number: number } | { kind: "createRequest"; number: number; branch: string };

/**
 * The one step the summary offers: a request for the issue this branch works on, else a branch for the first issue
 * nobody started (the list is read oldest first)
 */
export function issueNext(items: AssignedIssue[], currentBranch: string | null): IssueNext | null {
  const working = currentBranch ? items.find((item) => item.progress === "inProgress" && item.branch === currentBranch) : undefined;
  if (working && currentBranch) return { kind: "createRequest", number: working.number, branch: currentBranch };
  const idle = items.find((item) => item.progress === "notStarted");
  return idle ? { kind: "createBranch", number: idle.number } : null;
}

/** The count on the "Assigned to you" segment: none when nothing is assigned, "30+" when the server has more */
export function assignedIssueCount(assigned: number, more: boolean): string | null {
  return assigned === 0 ? null : more ? `${assigned}+` : String(assigned);
}
