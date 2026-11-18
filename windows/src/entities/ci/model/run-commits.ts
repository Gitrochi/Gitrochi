import { canPlay, type CIJob, type CIPipeline, type CIStatus, isActiveCI } from "./types";

/**
 * A commit of the branch that already has runs (GitHub) or pipelines (GitLab) on that branch. Hosting APIs start new
 * runs only on a branch's tip, so a chosen commit runs again through one of its own: GitLab presses a job of its
 * pipeline, GitHub re-runs one of its workflow runs. (macOS: Core/RunCommits.swift › RunCommit)
 */
export interface RunCommit {
  sha: string;
  subject: string;
  /** When its newest run was made, in seconds */
  created: number | null;
  /** Its runs on the branch, newest first */
  runs: CIPipeline[];
}

/** The run (GitHub) or pipeline job (GitLab) of a chosen commit that starts again (macOS: CommitRun) */
export interface CommitRun {
  runID: number;
  /** GitLab only */
  jobName: string | null;
}

// Pure, and the same as the macOS RunCommits functions named beside each.

/** How many commits the sheet offers (macOS: RunCommits.limit) */
export const runCommitLimit = 30;

/**
 * The branch's commits with runs on it, newest first, each with its runs. Subjects come from the local log, else from
 * the run's own title. (macOS: RunCommits.commits)
 */
export function runCommits(runs: CIPipeline[], branch: string, subjects: Map<string, string>, limit = runCommitLimit): RunCommit[] {
  const bySha = new Map<string, CIPipeline[]>();
  for (const run of runs) {
    if (run.ref !== branch) continue;
    const list = bySha.get(run.sha);
    if (list) list.push(run);
    else bySha.set(run.sha, [run]);
  }
  return [...bySha].slice(0, limit).map(([sha, list]) => ({
    sha,
    subject: subjects.get(sha) ?? list.find((r) => r.title)?.title ?? "",
    created: list[0].created,
    runs: list,
  }));
}

/** GitHub: the newest run of each workflow, the ones a chosen commit can re-run (macOS: RunCommits.workflowRuns) */
export function commitWorkflowRuns(commit: RunCommit): CIPipeline[] {
  const seen = new Set<string>();
  return commit.runs.filter((r) => !seen.has(r.name) && !!seen.add(r.name));
}

/** GitLab: the pipeline's jobs with the manual ones first, the rest in the server's order (macOS: RunCommits.jobs) */
export const commitJobs = (jobs: CIJob[]): CIJob[] => [...jobs.filter(canPlay), ...jobs.filter((j) => !canPlay(j))];

/** The job the sheet starts on: the first manual one, else the first (macOS: RunCommits.defaultJob) */
export const defaultCommitJob = (jobs: CIJob[]): CIJob | null => jobs.find(canPlay) ?? jobs[0] ?? null;

/** A manual or delayed job is pressed, a finished one retried, a running one left alone (macOS: RunCommits.jobAction) */
export function commitJobAction(status: CIStatus): "play" | "retry" | "busy" | "unavailable" {
  switch (status) {
    case "manual":
    case "scheduled":
      return "play";
    case "success":
    case "failed":
    case "canceled":
      return "retry";
    case "created":
    case "waiting":
    case "pending":
    case "running":
      return "busy";
    default:
      return "unavailable";
  }
}

/** GitHub: a run still going is not re-run a second time (macOS: RunCommits.runBusy) */
export const commitRunBusy = (status: CIStatus) => isActiveCI(status);

/** `log --format=%H%x1f%s` output as subjects by SHA (macOS: RunCommits.subjects) */
export function parseCommitSubjects(output: string): Map<string, string> {
  const out = new Map<string, string>();
  for (const line of output.split("\n")) {
    const cut = line.indexOf("\x1f");
    if (cut >= 7) out.set(line.slice(0, cut), line.slice(cut + 1).replace(/\r$/, ""));
  }
  return out;
}
