import type { WorkingStatus } from "@/entities/git";
import type { ProjectPortfolioTask } from "@/entities/hosting";
import { t } from "@/shared/i18n";

/** What Home says about the recent repositories and today's tasks (the redesign's Home board). macOS: HomeRepositories. */

/** "2 not pushed · 3 to pull", or "Up to date" */
export function homeSync(ahead: number, behind: number): string {
  const words: string[] = [];
  if (ahead > 0) words.push(t("{0} not pushed", ahead));
  if (behind > 0) words.push(t("{0} to pull", behind));
  return words.length ? words.join(" · ") : t("Up to date");
}

/** When a repository was opened: Today, Yesterday, then the day, with the year only for another year */
export function homeOpened(opened: number, now: number, language: string): string {
  const day = (ms: number) => { const d = new Date(ms); return Date.UTC(d.getFullYear(), d.getMonth(), d.getDate()); };
  const days = Math.round((day(now) - day(opened)) / 86_400_000);
  if (days === 0) return t("Today");
  if (days === 1) return t("Yesterday");
  const sameYear = new Date(opened).getFullYear() === new Date(now).getFullYear();
  return new Intl.DateTimeFormat(language, { month: "short", day: "numeric", ...(sameYear ? {} : { year: "numeric" }) }).format(new Date(opened));
}

/** The filter field matches the repository's name or any part of its path */
export function homeMatches(path: string, filter: string): boolean {
  const words = filter.trim().toLowerCase();
  return !words || path.toLowerCase().includes(words);
}

/** Files with a change, each once */
export function homeChanged(status: WorkingStatus): number {
  return new Set([...status.staged, ...status.unstaged, ...status.conflicted].map((file) => file.path)).size;
}

/** Today's tasks: what is overdue first, oldest first, then what is due today; at most five */
export function homeTodayTasks(tasks: ProjectPortfolioTask[], today: string): ProjectPortfolioTask[] {
  const open = tasks.filter(({ entry }) => !entry.completed && !entry.invalidRange && !entry.invalidDate);
  const overdue = open.filter(({ entry }) => !!entry.due && entry.due < today)
    .sort((a, b) => (a.entry.due ?? "").localeCompare(b.entry.due ?? "") || a.entry.row.title.localeCompare(b.entry.row.title));
  const due = open.filter((task) => !overdue.includes(task) && task.entry.date === today)
    .sort((a, b) => a.entry.row.title.localeCompare(b.entry.row.title));
  return [...overdue, ...due].slice(0, 5);
}
