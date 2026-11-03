import type { LedgerSession } from "@/entities/ledger";

// The inspector's read-only Checks row: the latest Flow results recorded for the session's branch head commit. These
// rules are pure; reading the records is LedgerFlowEvidenceStore's job, through the Flows workspace's own engine calls.
// (macOS: Views/Ledger/LedgerFlowEvidence.swift)

/** One finished Flow run as far as the Checks row needs it, from its record (run.json) */
export interface LedgerFlowRun {
  runId: string;
  flow: string;
  /** The engine's run state: SUCCEEDED, FAILED, REJECTED, CANCELLED, ROLLED_BACK, ROLLBACK_FAILED … */
  state: string;
  /** The commit the run was recorded for (`git.sha`) */
  sha: string;
  /** When it finished, in milliseconds; null while it runs */
  finishedAt: number | null;
}

/** How a finished run reads in the Ledger: passed, failed, or held for a person */
export type LedgerFlowOutcome = "passed" | "failed" | "held" | "canceled";

export interface LedgerFlowResult { run: LedgerFlowRun; outcome: LedgerFlowOutcome }

/** Null for a run that has not finished: only recorded results are evidence */
export function flowOutcome(state: string): LedgerFlowOutcome | null {
  switch (state) {
    case "SUCCEEDED": return "passed";
    case "FAILED": case "ROLLED_BACK": return "failed";
    // refused before running (trust, gate, production guard), or a rollback that failed and put the environment on hold
    case "REJECTED": case "ROLLBACK_FAILED": return "held";
    case "CANCELLED": return "canceled";
    default: return null;
  }
}

/**
 * The newest finished run of each flow recorded for `head`, newest first. Runs for other commits never count, so a
 * result always belongs to exactly the commit the branch points at.
 */
export function latestFlowResults(runs: readonly LedgerFlowRun[], head: string): LedgerFlowResult[] {
  if (!head) return [];
  const seen = new Set<string>(), out: LedgerFlowResult[] = [];
  const mine = runs.filter((r) => r.sha.toLowerCase() === head.toLowerCase() && r.finishedAt != null)
    .sort((a, b) => (b.finishedAt ?? 0) - (a.finishedAt ?? 0) || (a.runId < b.runId ? 1 : a.runId > b.runId ? -1 : 0));
  for (const run of mine) {
    const outcome = flowOutcome(run.state);
    if (!outcome || seen.has(run.flow)) continue;
    seen.add(run.flow);
    out.push({ run, outcome });
  }
  return out;
}

const folder = (p: string) => p.replace(/\\/g, "/").replace(/\/+$/, "").toLowerCase();
const shortBranch = (b: string) => b.replace(/^refs\/heads\//, "");

/** Whether the session's folder is the open repository or one of its worktrees; without a folder, whether its project is the repository's */
export function sessionInRepository(s: LedgerSession, repo: { path: string | null; worktrees: readonly { path: string }[]; project: string | null }): boolean {
  if (!repo.path) return false;
  const linked = s.links.repoPath ?? s.links.worktree ?? s.links.cwd;
  if (!linked) return !!repo.project && s.project === repo.project;
  return [repo.path, ...repo.worktrees.map((w) => w.path)].some((p) => folder(p) === folder(linked));
}

/**
 * The folders whose run records can hold the branch's results: the repository, and its worktrees that have the branch
 * checked out or that the session names (runs are recorded per worktree)
 */
export function flowEvidenceFolders(repoPath: string, worktrees: readonly { path: string; branch: string | null; prunable: boolean }[], branch: string, sessionWorktree?: string): string[] {
  const others = worktrees.filter((w) => !w.prunable && folder(w.path) !== folder(repoPath) && ((w.branch && shortBranch(w.branch) === shortBranch(branch)) || (!!sessionWorktree && folder(sessionWorktree) === folder(w.path))));
  return [repoPath, ...others.map((w) => w.path)];
}
