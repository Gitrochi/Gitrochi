import type { Provider } from "@/entities/git";
import { language, t } from "@/shared/i18n";
import { listWhen } from "@/shared/lib";

/**
 * A workflow (GitHub) or pipeline (GitLab) run the app starts once, later. It keeps enough to find the saved account
 * again and never a token: the token is read when the run starts. (macOS: Core/ScheduledRuns.swift › ScheduledRun)
 */
export interface ScheduledRun {
  id: string;
  /** The repository folder it was scheduled from; that repository's Actions page lists it */
  repoPath: string;
  provider: Provider;
  host: string;
  remote: string;
  /** owner/repo, group/sub/repo */
  path: string;
  /** The saved account whose token starts the run */
  accountID: string;
  /** GitHub: the workflow_dispatch workflow */
  workflowID: number | null;
  workflowName: string | null;
  ref: string;
  inputs: Record<string, string>;
  /** GitLab: the pipeline variables, in the order given */
  variables: [string, string][];
  /** When it starts, in milliseconds */
  runAt: number;
  createdAt: number;
  state: ScheduledRunState;
  /** Why the start failed */
  message: string | null;
}

export type ScheduledRunState = "scheduled" | "missed" | "failed";

// Pure, and the same as the macOS ScheduledRuns functions named beside each.

/** How late a check may find a run and still start it; any later and it waits for a click (macOS: ScheduledRuns.grace) */
export const scheduleGrace = 120_000;
/** How often the app looks for runs that are due (macOS: ScheduledRuns.interval) */
export const scheduleInterval = 30_000;

/** The sheet's first time: the next full hour (macOS: ScheduledRuns.nextFullHour) */
export function nextFullHour(now: number): number {
  const date = new Date(now);
  date.setMinutes(0, 0, 0);
  date.setHours(date.getHours() + 1);
  return date.getTime();
}

/** Only a time still ahead can be scheduled (macOS: ScheduledRuns.canSchedule) */
export const canSchedule = (at: number | null, now: number): at is number => at !== null && Number.isFinite(at) && at > now;

/**
 * What a check does with a run. One found more than `scheduleGrace` late (the app was closed or the computer slept) is
 * missed and never starts on its own. (macOS: ScheduledRuns.action)
 */
export function scheduledRunAction(run: Pick<ScheduledRun, "state" | "runAt">, now: number): "wait" | "start" | "miss" {
  if (run.state !== "scheduled" || now < run.runAt) return "wait";
  return now - run.runAt <= scheduleGrace ? "start" : "miss";
}

/** "in 5m", "in 2h", "in 3d"; a time gone by reads like a list date, "12m ago" (macOS: ScheduledRuns.relative) */
export function scheduledRunRelative(at: number, now: number): string {
  const left = at - now;
  if (left <= 0) return listWhen(at / 1000, now / 1000);
  const minutes = Math.ceil(left / 60_000);
  if (minutes < 60) return t("in {0}m", minutes);
  if (minutes < 1440) return t("in {0}h", Math.floor(minutes / 60));
  return t("in {0}d", Math.floor(minutes / 1440));
}

/** "Nov 12, 2:00 PM", with the year only for another year (macOS: ScheduledRuns.time) */
export function scheduledRunTime(at: number, now: number, lang: string = language): string {
  const sameYear = new Date(at).getFullYear() === new Date(now).getFullYear();
  return new Intl.DateTimeFormat(lang, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit", ...(sameYear ? {} : { year: "numeric" }) }).format(at);
}

/** The repository's runs, soonest first */
export function scheduledRunsFor(runs: ScheduledRun[], repoPath: string | null, same: (a: string, b: string) => boolean): ScheduledRun[] {
  return repoPath ? runs.filter((run) => same(run.repoPath, repoPath)).sort((a, b) => a.runAt - b.runAt) : [];
}

/** A datetime-local input's value for a time, in local time ("2026-11-10T15:00") */
export function dateTimeInputValue(at: number): string {
  const date = new Date(at), pad = (n: number) => String(n).padStart(2, "0");
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

/** A datetime-local input's value as a local time, or null while it is not a whole date and time */
export function parseDateTimeInput(value: string): number | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2}))?$/.exec(value);
  if (!m) return null;
  const [year, month, day, hour, minute, second] = m.slice(1).map((part) => Number(part ?? 0));
  const date = new Date(year, month - 1, day, hour, minute, second);
  // a day past the month's end would roll over into the next one
  return date.getMonth() === month - 1 && date.getDate() === day ? date.getTime() : null;
}

/** The saved list, without entries a damaged or older settings file may hold */
export function decodeScheduledRuns(value: unknown): ScheduledRun[] {
  if (!Array.isArray(value)) return [];
  return value.filter((run): run is ScheduledRun =>
    !!run && typeof run === "object"
    && typeof run.id === "string" && typeof run.repoPath === "string" && typeof run.accountID === "string" && typeof run.ref === "string"
    && (run.provider === "github" || run.provider === "gitlab")
    && typeof run.runAt === "number" && Number.isFinite(run.runAt)
    && (run.state === "scheduled" || run.state === "missed" || run.state === "failed"));
}
