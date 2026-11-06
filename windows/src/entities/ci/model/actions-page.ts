import { type CIJob, type CIPipeline, type CIStatus, isFinishedCI } from "./types";

/**
 * What the Actions page shows of the runs it already has (the redesign's Actions board): the segments and their
 * counts, the list's search and order, this branch's recent runs, a run's jobs by result and the part of a log to
 * open on. Nothing here asks the server. (macOS: Core/ActionsPage.swift)
 */

/** The list's filter; all but `all` are states that need attention or are live, so only they carry a count */
export type RunSegment = "all" | "failed" | "running" | "waiting";
export const runSegments: RunSegment[] = ["all", "failed", "running", "waiting"];

export function runSegment(status: CIStatus): RunSegment | null {
  switch (status) {
    case "failed": return "failed";
    case "running": case "pending": case "created": return "running";
    case "waiting": case "manual": case "scheduled": return "waiting";
    default: return null;
  }
}

export function runCount(runs: CIPipeline[], segment: RunSegment): number {
  return segment === "all" ? runs.length : runs.filter((run) => runSegment(run.status) === segment).length;
}

/** The rows to show: the segment's runs that match the search (title, number, branch or workflow), in the chosen order */
export function visibleRuns(runs: CIPipeline[], segment: RunSegment, search: string, oldestFirst: boolean, title: (run: CIPipeline) => string): CIPipeline[] {
  const words = search.trim().toLowerCase();
  const shown = runs.filter((run) => {
    if (segment !== "all" && runSegment(run.status) !== segment) return false;
    return !words || [title(run), `#${run.number}`, run.ref, run.name].some((text) => text.toLowerCase().includes(words));
  });
  return oldestFirst ? shown.reverse() : shown;
}

/** The workflow most runs belong to; rows name only the other ones */
export function commonWorkflow(runs: CIPipeline[]): string | null {
  const counts = new Map<string, number>();
  for (const run of runs) if (run.name) counts.set(run.name, (counts.get(run.name) ?? 0) + 1);
  let best: string | null = null;
  for (const [name, count] of counts) if (best === null || count > counts.get(best)!) best = name;
  return best;
}

/** This branch's latest runs, oldest first, as the summary draws them */
export function runHistory(runs: CIPipeline[], ref: string | null, limit = 3): CIPipeline[] {
  if (ref === null) return [];
  const branch = runs.filter((run) => run.ref === ref);
  return branch.filter((run) => run.name === branch[0]?.name).slice(0, limit).reverse();
}

export type RunStreak =
  | { kind: "none" }
  /** The latest runs all passed */
  | { kind: "passing"; count: number }
  | { kind: "failed" | "running" | "waiting"; run: CIPipeline };

/** What the newest run of a history says: still going, waiting for someone, failed, or how many passed in a row */
export function runStreak(history: CIPipeline[]): RunStreak {
  const latest = history[history.length - 1];
  if (!latest) return { kind: "none" };
  const segment = runSegment(latest.status);
  if (segment === "running" || segment === "waiting" || segment === "failed") return { kind: segment, run: latest };
  let passed = 0;
  for (let i = history.length - 1; i >= 0 && history[i].status === "success"; i--) passed++;
  return passed > 0 ? { kind: "passing", count: passed } : { kind: "none" };
}

/** How long a finished run took in seconds, when the server said when it started and ended */
export function runTook(run: CIPipeline): number | null {
  const start = run.started ?? run.created, end = run.updated ?? null;
  return isFinishedCI(run.status) && start != null && end != null && end > start ? end - start : null;
}

/** The branch runs are compared with: main, or master where there is no main */
export function runBaseRef(branches: string[]): string | null {
  return ["main", "master"].find((name) => branches.includes(name)) ?? null;
}

export type JobGroup = "failed" | "running" | "waiting" | "passed" | "other";
const jobGroupOrder: JobGroup[] = ["failed", "running", "waiting", "passed", "other"];

export function jobGroup(status: CIStatus): JobGroup {
  const segment = runSegment(status);
  return segment === "failed" || segment === "running" || segment === "waiting" ? segment : status === "success" ? "passed" : "other";
}

/** A run's jobs by result, what failed first; groups without jobs are left out */
export function jobGroups(jobs: CIJob[]): { group: JobGroup; jobs: CIJob[] }[] {
  return jobGroupOrder.map((group) => ({ group, jobs: jobs.filter((job) => jobGroup(job.status) === group) })).filter((entry) => entry.jobs.length > 0);
}

const errorWord = /(^|[^A-Za-z_-])(error|fatal)([^A-Za-z_-]|$)/i;
const failWord = /(^|[^A-Za-z_-])FAIL(ED|URE)?([^A-Za-z_-]|$)/;
const stamp = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z /;
// eslint-disable-next-line no-control-regex
const colour = /\u001b\[[0-9;]*[A-Za-z]/g;

/** A log as a person reads it: without the runner's time stamps, colour codes and bookkeeping lines (macOS: ActionsPage.lines) */
export function logLines(log: string): string[] {
  return log.split("\n").flatMap((raw) => {
    const line = raw.replace(/\r$/, "").replace(stamp, "").replace(colour, "");
    const marker = /^##\[([^\]]+)\](.*)$/.exec(line);
    if (!marker) return [line];
    const [, kind, rest] = marker;
    return kind === "group" ? [rest] : kind === "error" ? [`Error: ${rest}`] : kind === "warning" ? [`Warning: ${rest}`] : kind === "notice" ? [`Notice: ${rest}`] : [];
  });
}

/** A line the log marks: it names an error, or FAIL in capitals as test runners print it */
export const isLogError = (line: string) => errorWord.test(line) || failWord.test(line);

/** The first line a log opens on: a few lines before its first error, or its last two hundred lines */
export function firstLogLine(lines: string[]): number {
  const error = lines.findIndex(isLogError);
  return error >= 0 ? Math.max(0, error - 3) : Math.max(0, lines.length - 200);
}
