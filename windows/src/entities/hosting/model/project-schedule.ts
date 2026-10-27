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
