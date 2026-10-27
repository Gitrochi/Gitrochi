import { parseScheduleDay } from "./project-schedule";

export interface LocalPlannerTask {
  id: string; title: string; body: string; status: string; start: string; due: string;
  priority: string; assignees: string[]; archived: boolean; updatedAt: string;
}
export interface LocalPlannerProject {
  id: string; title: string; description: string; revision: number; createdAt: string; updatedAt: string; tasks: LocalPlannerTask[];
}
export interface LocalPlannerDocument { version: 1; revision: number; projects: LocalPlannerProject[] }
export const localProjectLimits = { maxProjects: 1000, maxTasksPerProject: 10_000, maxBytes: 50_000_000 } as const;
export const localStatusIDs = ["local-todo", "local-progress", "local-done"];
export const localPriorityIDs = ["local-low", "local-normal", "local-high", "local-urgent"];
const object = (value: unknown): value is Record<string, unknown> => !!value && typeof value === "object" && !Array.isArray(value);
const text = (value: unknown, maximum: number, required = false): value is string => typeof value === "string" && value.length <= maximum && (!required || !!value.trim());
const integer = (value: unknown): value is number => Number.isSafeInteger(value) && Number(value) >= 0;
const unique = (values: { id: string }[]) => new Set(values.map(value => value.id)).size === values.length;

/** A corrupt or newer document is never treated as empty and never overwritten. */
export function decodeLocalProjects(raw: string | null): LocalPlannerDocument {
  if (raw === null) return { version: 1, revision: 0, projects: [] };
  if (new TextEncoder().encode(raw).length > localProjectLimits.maxBytes) throw new Error("Local project data is invalid. Your saved data has not been changed.");
  let value: unknown;
  try { value = JSON.parse(raw); } catch { throw new Error("Local project data is invalid. Your saved data has not been changed."); }
  if (!object(value) || value.version !== 1 || !integer(value.revision) || !Array.isArray(value.projects) || value.projects.length > localProjectLimits.maxProjects) throw new Error("Local project data is invalid. Your saved data has not been changed.");
  for (const project of value.projects) {
    if (!object(project) || !text(project.id, 100, true) || !/^local:[a-zA-Z0-9-]+$/.test(project.id) || !text(project.title, 200, true) || !text(project.description, 20_000) || !integer(project.revision) || !text(project.createdAt, 50, true) || !text(project.updatedAt, 50, true) || !Array.isArray(project.tasks) || project.tasks.length > localProjectLimits.maxTasksPerProject) throw new Error("Local project data is invalid. Your saved data has not been changed.");
    for (const task of project.tasks) {
      if (!object(task) || !text(task.id, 100, true) || !/^local-task:[a-zA-Z0-9-]+$/.test(task.id) || !text(task.title, 500, true) || !text(task.body, 200_000) || !localStatusIDs.includes(String(task.status)) || !localPriorityIDs.includes(String(task.priority)) || typeof task.archived !== "boolean" || !text(task.updatedAt, 50, true) || !Array.isArray(task.assignees) || task.assignees.length > 20 || !task.assignees.every(value => text(value, 100, true)) || !text(task.start, 10) || !text(task.due, 10) || (task.start !== "" && !parseScheduleDay(task.start)) || (task.due !== "" && !parseScheduleDay(task.due)) || (!!task.start && !!task.due && task.start > task.due)) throw new Error("Local project data is invalid. Your saved data has not been changed.");
    }
    if (!unique(project.tasks as LocalPlannerTask[])) throw new Error("Local project data is invalid. Your saved data has not been changed.");
  }
  if (!unique(value.projects as LocalPlannerProject[])) throw new Error("Local project data is invalid. Your saved data has not been changed.");
  return value as unknown as LocalPlannerDocument;
}
