import type { HubProjectField, HubProjectRow } from "../api/hub";

/** macOS: Core/ProjectSchedule.swift. Dates are calendar days, never instants. */
export interface ProjectScheduleSettings {
  startFieldID?: string;
  dueFieldID?: string;
  statusFieldID?: string;
  completedOptionIDs: string[];
}
export interface ProjectScheduleFields {
  start?: HubProjectField;
  due?: HubProjectField;
  status?: HubProjectField;
}
export interface ProjectScheduleEntry {
  row: HubProjectRow;
  start?: string;
  due?: string;
  date?: string;
  completed: boolean;
  invalidDate: boolean;
  invalidRange: boolean;
}
export interface ProjectScheduleSummary {
  active: number;
  overdue: number;
  today: number;
  upcoming: number;
  unscheduled: number;
  completed: number;
  invalid: number;
}
export interface ProjectScheduleWorkload extends ProjectScheduleSummary {
  assignee: string;
}
export interface ProjectScheduleChange { fieldID: string; value: string }
/** One chip of the overview. A chip counts open tasks only, and its count is the rows the Schedule list shows for it. */
export type ProjectScheduleGroup = "overdue" | "today" | "upcoming" | "unscheduled";
/** Where a task stands, for its status pill and the progress bar. */
export type ProjectScheduleStage = "todo" | "inProgress" | "done";
/** The overview's Schedule list and what it leaves to the cards beside it. */
export interface ProjectScheduleOverview {
  /** Open tasks a chip counts, by date, with the done tasks of the same days between them */
  rows: ProjectScheduleEntry[];
  /** Done tasks the list leaves out until they are asked for */
  done: ProjectScheduleEntry[];
  /** Open tasks due after the week the list covers, soonest first */
  later: ProjectScheduleEntry[];
  counts: Record<ProjectScheduleGroup, number>;
}
export interface ProjectScheduleProgress { done: number; inProgress: number; todo: number; percent: number }

const dayMilliseconds = 86_400_000;
const defaults: ProjectScheduleSettings = { completedOptionIDs: [] };

/** Parse only real Gregorian YYYY-MM-DD values, including years below 100. */
export function parseScheduleDay(value: string | undefined): Date | undefined {
  if (!value || !/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(value)) return undefined;
  const [year, month, day] = value.split("-").map(Number);
  if (year < 1) return undefined;
  const date = new Date(0);
  date.setUTCHours(0, 0, 0, 0);
  date.setUTCFullYear(year, month - 1, day);
  return date.getUTCFullYear() === year && date.getUTCMonth() === month - 1 && date.getUTCDate() === day ? date : undefined;
}
const dayString = (date: Date) => `${String(date.getUTCFullYear()).padStart(4, "0")}-${String(date.getUTCMonth() + 1).padStart(2, "0")}-${String(date.getUTCDate()).padStart(2, "0")}`;

export function localScheduleToday(date = new Date()): string {
  return `${String(date.getFullYear()).padStart(4, "0")}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
}
export function scheduleAddDays(day: string, count: number): string | undefined {
  const parsed = parseScheduleDay(day);
  if (!parsed || !Number.isInteger(count) || Math.abs(count) > 3_652_058) return undefined;
  const result = new Date(parsed.getTime() + count * dayMilliseconds);
  const text = dayString(result);
  return parseScheduleDay(text) ? text : undefined;
}
export function scheduleWeekDays(day: string, weekStartsOn = 1): string[] {
  const parsed = parseScheduleDay(day);
  if (!parsed || !Number.isInteger(weekStartsOn) || weekStartsOn < 0 || weekStartsOn > 6) return [];
  const first = scheduleAddDays(day, -((parsed.getUTCDay() - weekStartsOn + 7) % 7));
  return first ? Array.from({ length: 7 }, (_, index) => scheduleAddDays(first, index)).filter((value): value is string => !!value) : [];
}
export function scheduleMonthDays(day: string, weekStartsOn = 1): string[] {
  if (!parseScheduleDay(day)) return [];
  const first = scheduleWeekDays(`${day.slice(0, 7)}-01`, weekStartsOn)[0];
  return first ? Array.from({ length: 42 }, (_, index) => scheduleAddDays(first, index)).filter((value): value is string => !!value) : [];
}

export function resolveScheduleFields(fields: HubProjectField[], settings: ProjectScheduleSettings = defaults): ProjectScheduleFields {
  const dates = fields.filter((field) => field.kind === "date");
  const named = (candidates: HubProjectField[], names: string[]) => candidates.find((field) => names.includes(field.name.toLowerCase().trim().replace(/[_-]/g, " ")));
  const start = settings.startFieldID === undefined ? dates.find((field) => field.id === "local-start") ?? named(dates, ["start", "start date", "begin", "begin date", "planned start"]) : dates.find((field) => field.id === settings.startFieldID);
  const remaining = dates.filter((field) => field.id !== start?.id);
  const due = settings.dueFieldID === undefined ? remaining.find((field) => field.id === "local-due") ?? named(remaining, ["due", "due date", "deadline", "end", "end date", "target", "target date"]) ?? (remaining.length === 1 ? remaining[0] : undefined) : dates.find((field) => field.id === settings.dueFieldID);
  const selects = fields.filter((field) => field.kind === "singleSelect" || (!field.kind && field.options.length > 0));
  const status = settings.statusFieldID === undefined ? selects.find((field) => field.id === "local-status") ?? named(selects, ["status", "state"]) : selects.find((field) => field.id === settings.statusFieldID);
  return { start, due, status };
}
const fieldValue = (row: HubProjectRow, field: HubProjectField | undefined) => field ? row.values?.[field.id] ?? row.statuses[field.id] ?? "" : "";

export function scheduleEntries(rows: HubProjectRow[], fields: HubProjectField[], settings: ProjectScheduleSettings = defaults): ProjectScheduleEntry[] {
  const selected = resolveScheduleFields(fields, settings);
  return rows.filter((row) => !row.archived && row.kind !== "redacted").map((row) => {
    const rawStart = fieldValue(row, selected.start), rawDue = fieldValue(row, selected.due);
    const start = parseScheduleDay(rawStart) ? rawStart : undefined, due = parseScheduleDay(rawDue) ? rawDue : undefined;
    const status = fieldValue(row, selected.status);
    const configuredComplete = !!selected.status?.options.some((option) => option.id === status && settings.completedOptionIDs.includes(option.id));
    return { row, start, due, date: due ?? start, completed: ["closed", "merged"].includes(row.state?.toLowerCase() ?? "") || configuredComplete,
      invalidDate: (!!rawStart && !start) || (!!rawDue && !due), invalidRange: !!start && !!due && start > due };
  });
}
export function scheduleSummary(entries: ProjectScheduleEntry[], today: string): ProjectScheduleSummary {
  const result: ProjectScheduleSummary = { active: 0, overdue: 0, today: 0, upcoming: 0, unscheduled: 0, completed: 0, invalid: 0 };
  const horizon = scheduleAddDays(today, 7);
  for (const entry of entries) {
    if (entry.invalidDate || entry.invalidRange) result.invalid++;
    if (entry.completed) { result.completed++; continue; }
    result.active++;
    if (!entry.date) result.unscheduled++;
    if (!parseScheduleDay(today) || entry.invalidRange) continue;
    if (entry.due && entry.due < today) result.overdue++;
    if (entry.date === today) result.today++;
    if (entry.date && horizon && entry.date > today && entry.date <= horizon) result.upcoming++;
  }
  return result;
}
/** The chip that counts a task, with the rules of `scheduleSummary`; undefined for a done task and for one no chip counts (due after the week, started without a due date, or with its dates reversed). */
export function scheduleGroup(entry: ProjectScheduleEntry, today: string): ProjectScheduleGroup | undefined {
  if (entry.completed) return undefined;
  if (!entry.date) return "unscheduled";
  if (!parseScheduleDay(today) || entry.invalidRange) return undefined;
  if (entry.due && entry.due < today) return "overdue";
  if (entry.date === today) return "today";
  const horizon = scheduleAddDays(today, 7);
  return horizon && entry.date > today && entry.date <= horizon ? "upcoming" : undefined;
}
/** The Schedule list keeps the project's order within a day, so the chips always add up to its open rows. */
export function scheduleOverview(entries: ProjectScheduleEntry[], today: string): ProjectScheduleOverview {
  const horizon = scheduleAddDays(today, 7);
  const counts: Record<ProjectScheduleGroup, number> = { overdue: 0, today: 0, upcoming: 0, unscheduled: 0 };
  const rows: [number, ProjectScheduleEntry][] = [], done: [number, ProjectScheduleEntry][] = [], later: [number, ProjectScheduleEntry][] = [];
  entries.forEach((entry, index) => {
    const group = scheduleGroup(entry, today);
    if (group) { counts[group]++; rows.push([index, entry]); }
    else if (entry.completed) (entry.date && horizon && entry.date >= today && entry.date <= horizon ? rows : done).push([index, entry]);
    else if (entry.due && horizon && entry.due > horizon && !entry.invalidRange) later.push([index, entry]);
  });
  const ordered = (values: [number, ProjectScheduleEntry][], day: (entry: ProjectScheduleEntry) => string | undefined) =>
    values.sort(([a, left], [b, right]) => { const x = day(left) ?? "9999-99-99", y = day(right) ?? "9999-99-99"; return x === y ? a - b : x < y ? -1 : 1; }).map(([, entry]) => entry);
  return { rows: ordered(rows, (entry) => entry.date), done: ordered(done, (entry) => entry.date), later: ordered(later, (entry) => entry.due), counts };
}
/** A task that left the first open status is in progress; one without a status field is still to do. */
export function scheduleStage(entry: ProjectScheduleEntry, status: HubProjectField | undefined, settings: ProjectScheduleSettings = defaults): ProjectScheduleStage {
  if (entry.completed) return "done";
  if (!status) return "todo";
  const current = fieldValue(entry.row, status), first = status.options.find((option) => !settings.completedOptionIDs.includes(option.id));
  return current === first?.id || !status.options.some((option) => option.id === current) ? "todo" : "inProgress";
}
export function scheduleProgress(entries: ProjectScheduleEntry[], status: HubProjectField | undefined, settings: ProjectScheduleSettings = defaults): ProjectScheduleProgress {
  const result = { done: 0, inProgress: 0, todo: 0, percent: 0 };
  for (const entry of entries) result[scheduleStage(entry, status, settings)]++;
  const total = result.done + result.inProgress + result.todo;
  result.percent = total ? Math.round((result.done / total) * 100) : 0;
  return result;
}
/** Shared tasks count once per assignee, so workload totals may exceed the project total. */
export function scheduleWorkload(entries: ProjectScheduleEntry[], today: string): ProjectScheduleWorkload[] {
  const grouped = new Map<string, { assignee: string; entries: ProjectScheduleEntry[] }>();
  for (const entry of entries) {
    const assignees = entry.row.assignees?.filter((assignee) => !!assignee.trim()) ?? [];
    const seen = new Set<string>();
    for (const assignee of assignees.length ? assignees : [""]) {
      const key = assignee.toLowerCase();
      if (seen.has(key)) continue;
      seen.add(key);
      const group = grouped.get(key) ?? { assignee, entries: [] };
      group.entries.push(entry);
      grouped.set(key, group);
    }
  }
  return [...grouped.entries()].sort(([a], [b]) => !a ? 1 : !b ? -1 : a.localeCompare(b)).map(([, group]) => ({ assignee: group.assignee, ...scheduleSummary(group.entries, today) }));
}
export function scheduleReschedule(row: HubProjectRow, fields: HubProjectField[], settings: ProjectScheduleSettings = defaults, targetDay: string): ProjectScheduleChange[] {
  if (row.archived || row.kind === "redacted") throw new Error("The project item is unavailable.");
  const target = parseScheduleDay(targetDay);
  if (!target) throw new Error("Choose a valid calendar date.");
  const selected = resolveScheduleFields(fields, settings), anchor = selected.due ?? selected.start;
  if (!anchor) throw new Error("Choose a date field for scheduling.");
  const entry = scheduleEntries([row], fields, settings)[0];
  if (entry.invalidDate) throw new Error("Fix invalid task dates before rescheduling.");
  if (entry.invalidRange) throw new Error("The start date must be on or before the due date.");
  if (selected.start && selected.due && selected.start.id !== selected.due.id && entry.start && entry.due) {
    const duration = (parseScheduleDay(entry.due)!.getTime() - parseScheduleDay(entry.start)!.getTime()) / dayMilliseconds;
    const shifted = scheduleAddDays(targetDay, -duration);
    if (!shifted) throw new Error("Choose a valid calendar date.");
    return [{ fieldID: selected.start.id, value: shifted }, { fieldID: selected.due.id, value: targetDay }];
  }
  if (anchor.id === selected.due?.id && entry.start && entry.start > targetDay) throw new Error("The start date must be on or before the due date.");
  return [{ fieldID: anchor.id, value: targetDay }];
}
