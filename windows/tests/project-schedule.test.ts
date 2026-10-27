import { describe, expect, it } from "vitest";
import type { HubProjectField, HubProjectRow } from "@/entities/hosting";
import {
  localScheduleToday, parseScheduleDay, resolveScheduleFields, scheduleAddDays,
  scheduleEntries, scheduleMonthDays, scheduleReschedule, scheduleSummary,
  scheduleWeekDays, scheduleWorkload,
} from "../src/entities/hosting/model/project-schedule";

const fields: HubProjectField[] = [
  { id: "start", name: "Start date", kind: "date", options: [] },
  { id: "due", name: "Due date", kind: "date", options: [] },
  { id: "status", name: "Status", kind: "singleSelect", options: [{ id: "done", name: "Shipped" }, { id: "todo", name: "Todo" }] },
  { id: "priority", name: "Priority", kind: "singleSelect", options: [{ id: "high", name: "High" }] },
];
const settings = { completedOptionIDs: ["done"] };
const row = (id: string, values: Record<string, string> = {}, extra: Partial<HubProjectRow> = {}): HubProjectRow => ({
  id, title: id, body: "", url: "", contentID: id, statuses: {}, kind: "issue", values, ...extra,
});

describe("project scheduling calendar days", () => {
  it("accepts Gregorian calendar-only dates and rejects normalization and instants", () => {
    for (const value of ["2024-02-29", "2000-02-29", "1582-10-10", "0001-01-01", "0099-12-31", "9999-12-31"]) expect(parseScheduleDay(value)).toBeDefined();
    for (const value of [undefined, "", "2026-02-29", "1900-02-29", "2026-04-31", "2026-00-10", "2026-13-01", "2026-01-00", "0000-01-01", "2026-1-01", "2026-01-1", "2026-10-26T00:00:00Z", " 2026-10-26", "2026-10-26 ", "２０２６-１０-２６"]) expect(parseScheduleDay(value)).toBeUndefined();
  });
  it("keeps local today separate from UTC and uses calendar arithmetic across DST and year boundaries", () => {
    const local = new Date(2026, 9, 27, 0, 15);
    expect(localScheduleToday(local)).toBe("2026-10-27");
    expect(scheduleAddDays("2026-03-07", 2)).toBe("2026-03-09");
    expect(scheduleAddDays("2026-11-01", 1)).toBe("2026-11-02");
    expect(scheduleAddDays("2024-02-28", 1)).toBe("2024-02-29");
    expect(scheduleAddDays("2026-12-31", 1)).toBe("2027-01-01");
    expect(scheduleAddDays("1582-10-04", 1)).toBe("1582-10-05");
    expect(scheduleAddDays("0001-01-01", -1)).toBeUndefined();
    expect(scheduleAddDays("9999-12-31", 1)).toBeUndefined();
    expect(scheduleAddDays("2026-10-27", 0.5)).toBeUndefined();
  });
  it("creates stable Monday-first 42-day months and seven-day weeks", () => {
    const month = scheduleMonthDays("2026-10-27");
    expect(month).toHaveLength(42);
    expect(month[0]).toBe("2026-09-28");
    expect(month[41]).toBe("2026-11-08");
    expect(new Set(month).size).toBe(42);
    expect(scheduleWeekDays("2027-01-01")).toEqual(["2026-12-28", "2026-12-29", "2026-12-30", "2026-12-31", "2027-01-01", "2027-01-02", "2027-01-03"]);
    expect(scheduleMonthDays("2026-03-09", 0)[0]).toBe("2026-03-01");
    expect(scheduleWeekDays("invalid")).toEqual([]);
    expect(scheduleWeekDays("2026-10-27", 9)).toEqual([]);
  });
});

describe("project scheduling derived data", () => {
  it("resolves named date fields without guessing completion or overriding explicit selections", () => {
    expect(resolveScheduleFields(fields, settings)).toMatchObject({ start: { id: "start" }, due: { id: "due" }, status: { id: "status" } });
    expect(resolveScheduleFields(fields, { startFieldID: "", dueFieldID: "missing", statusFieldID: "priority", completedOptionIDs: [] })).toMatchObject({ start: undefined, due: undefined, status: { id: "priority" } });
    expect(resolveScheduleFields([{ id: "release", name: "Release", kind: "date", options: [] }], settings).due?.id).toBe("release");
    expect(resolveScheduleFields([{ id: "a", name: "Alpha", kind: "date", options: [] }, { id: "b", name: "Beta", kind: "date", options: [] }], settings).due).toBeUndefined();
    expect(resolveScheduleFields([fields[3]], settings).status).toBeUndefined();
  });
  it("derives honest loaded-item counts and keeps invalid ranges flagged", () => {
    const entries = scheduleEntries([
      row("late", { due: "2026-10-26" }, { assignees: ["alex", "sam", "ALEX"] }),
      row("today", { due: "2026-10-27" }, { assignees: ["alex"] }),
      row("week", { due: "2026-11-03" }), row("later", { due: "2026-11-04" }),
      row("unscheduled"), row("bad", { due: "2026-02-30" }),
      row("reversed", { start: "2026-10-29", due: "2026-10-26" }),
      row("configured", { due: "2026-10-26" }, { statuses: { status: "done" } }),
      row("closed", {}, { state: "CLOSED" }), row("merged", {}, { state: "MERGED", kind: "pullRequest" }),
      row("start-only", { start: "2026-10-26" }),
      row("archived", { due: "2026-10-26" }, { archived: true }), row("redacted", {}, { kind: "redacted" }),
    ], fields, settings);
    expect(entries).toHaveLength(11);
    expect(entries.find((entry) => entry.row.id === "reversed")).toMatchObject({ start: "2026-10-29", due: "2026-10-26", invalidRange: true });
    expect(scheduleSummary(entries, "2026-10-27")).toEqual({ active: 8, overdue: 1, today: 1, upcoming: 1, unscheduled: 2, completed: 3, invalid: 2 });
    expect(scheduleSummary(entries, "invalid").overdue).toBe(0);
    expect(scheduleSummary(scheduleEntries([row("last-option", {}, { statuses: { status: "todo" } })], fields), "2026-10-27").completed).toBe(0);
    expect(scheduleEntries([row("removed-option", {}, { statuses: { status: "removed" } })], fields, { completedOptionIDs: ["removed"] })[0].completed).toBe(false);
    const workloads = scheduleWorkload(entries, "2026-10-27");
    expect(workloads.find((value) => value.assignee === "alex")).toMatchObject({ active: 2, overdue: 1, today: 1 });
    expect(workloads.find((value) => value.assignee === "sam")).toMatchObject({ active: 1, overdue: 1 });
    expect(workloads.at(-1)?.assignee).toBe("");
    expect(workloads.reduce((count, value) => count + value.active, 0)).toBe(9);
  });
  it("moves both dates by calendar duration and refuses ambiguous or invalid edits", () => {
    expect(scheduleReschedule(row("range", { start: "2026-03-07", due: "2026-03-09" }), fields, settings, "2026-11-02")).toEqual([{ fieldID: "start", value: "2026-10-31" }, { fieldID: "due", value: "2026-11-02" }]);
    expect(scheduleReschedule(row("single", { due: "2026-10-27" }), fields, settings, "2026-10-30")).toEqual([{ fieldID: "due", value: "2026-10-30" }]);
    expect(scheduleReschedule(row("new"), fields, settings, "2026-10-30")).toEqual([{ fieldID: "due", value: "2026-10-30" }]);
    expect(scheduleReschedule(row("start", { start: "2026-10-27" }), [fields[0]], settings, "2026-10-30")).toEqual([{ fieldID: "start", value: "2026-10-30" }]);
    for (const item of [row("bad", { due: "2026-02-30" }), row("reversed", { start: "2026-10-30", due: "2026-10-27" }), row("early-due", { start: "2026-10-31" }), row("archived", {}, { archived: true }), row("private", {}, { kind: "redacted" })]) expect(() => scheduleReschedule(item, fields, settings, "2026-10-30")).toThrow();
    expect(() => scheduleReschedule(row("invalid"), fields, settings, "2026-02-30")).toThrow();
    expect(() => scheduleReschedule(row("missing"), [], settings, "2026-10-30")).toThrow();
  });
});
