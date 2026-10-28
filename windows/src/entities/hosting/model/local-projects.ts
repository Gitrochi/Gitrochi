import { ipc } from "@/shared/api";
import { t } from "@/shared/i18n";
import { Observable } from "@/shared/lib";
import type { HubDetail, HubItem, HubProjectField, HubProjectRow } from "../api/hub";
import { decodeLocalProjects, localPriorityIDs, localStatusIDs, localProjectLimits, type LocalPlannerDocument, type LocalPlannerProject, type LocalPlannerTask } from "./local-project-document";
import { parseScheduleDay, scheduleReschedule, type ProjectScheduleSettings } from "./project-schedule";
import { validateProjectDependencies } from "./project-dependencies";

export interface LocalProjectPersistence { read(): Promise<string | null>; write(expected: string | null, content: string): Promise<void> }
const nativePersistence: LocalProjectPersistence = { read: () => ipc.localProjectsRead(), write: (expected, content) => ipc.localProjectsWrite(expected, content) };
function fail(message: string): never { throw new Error(t(message)); }
export const isLocalProject = (item: HubItem): boolean => item.id.startsWith("local:") && item.data.localProject === true;
export const localProjectFields = (): HubProjectField[] => [
  { id: "local-status", name: t("Status"), kind: "singleSelect", options: [{ id: "local-todo", name: t("Todo") }, { id: "local-progress", name: t("In progress") }, { id: "local-done", name: t("Done") }] },
  { id: "local-start", name: t("Start date"), kind: "date", options: [] },
  { id: "local-due", name: t("Due date"), kind: "date", options: [] },
  { id: "local-priority", name: t("Priority"), kind: "singleSelect", options: [{ id: "local-low", name: t("Low") }, { id: "local-normal", name: t("Normal") }, { id: "local-high", name: t("High") }, { id: "local-urgent", name: t("Urgent") }] },
  { id: "local-assignees", name: t("Assignees"), kind: "text", options: [] },
];
const projectItem = (project: LocalPlannerProject): HubItem => ({ id: project.id, title: project.title, subtitle: t("Local project"), body: project.description, url: "", editable: true, data: { localProject: true, localRevision: project.revision, createdAt: project.createdAt, updatedAt: project.updatedAt } });
const projectDetail = (project: LocalPlannerProject): HubDetail => ({ item: projectItem(project), fields: localProjectFields(), rows: project.tasks.map(task => ({ id: task.id, title: task.title, body: task.body, contentID: task.id, url: "", kind: "draft", archived: task.archived, state: task.status === "local-done" ? "CLOSED" : "OPEN", updatedAt: task.updatedAt, assignees: [...task.assignees], predecessorIDs: task.predecessorIDs ? [...task.predecessorIDs] : undefined, durationDays: task.durationDays, labels: [], statuses: { "local-status": task.status, "local-priority": task.priority }, values: { "local-status": task.status, "local-start": task.start, "local-due": task.due, "local-priority": task.priority, "local-assignees": task.assignees.join(", ") } })), members: [], repositories: [], assets: [], more: false });

/** Local planner data is account-independent and never passes through a hosting API. */
export class LocalProjectStore extends Observable {
  projects: HubItem[] = [];
  loading = false;
  loaded = false;
  error: string | null = null;
  revision = 0;
  private writing = false;
  private operation = 0;
  private writeGeneration = 0;
  constructor(private readonly storage: LocalProjectPersistence = nativePersistence) { super(); }
  async load(): Promise<void> {
    if (this.writing) return;
    const operation = ++this.operation; this.loading = true; this.error = null; this.emit();
    try { const document = decodeLocalProjects(await this.storage.read()); if (this.operation === operation) this.publish(document); }
    catch (error) { if (this.operation === operation) this.error = this.message(error); }
    finally { if (this.operation === operation) { this.loading = false; this.emit(); } }
  }
  async detail(projectID: string): Promise<HubDetail> {
    if (this.writing) fail("Local projects are still saving. Try again in a moment.");
    if (!projectID.startsWith("local:")) fail("This local project is unavailable.");
    const generation = this.writeGeneration;
    const document = decodeLocalProjects(await this.storage.read()), project = document.projects.find(project => project.id === projectID);
    if (generation !== this.writeGeneration || this.writing) fail("This local project changed. Refresh before saving.");
    if (!project) fail("This local project is unavailable.");
    this.publish(document); return projectDetail(project);
  }
  async create(title: string, description = ""): Promise<HubItem> {
    const name = this.title(title, 200), summary = this.body(description, 20_000), now = new Date().toISOString();
    const project: LocalPlannerProject = { id: `local:${crypto.randomUUID()}`, title: name, description: summary, revision: 1, createdAt: now, updatedAt: now, tasks: [] };
    await this.transaction(document => { if (document.projects.length >= localProjectLimits.maxProjects) fail("Local project data is invalid. Your saved data has not been changed."); document.projects.push(project); });
    return projectItem(project);
  }
  async saveDraft(detail: HubDetail, title: string, body: string, row?: HubProjectRow, initialField?: HubProjectField, option?: string): Promise<HubDetail> {
    const name = this.title(title, 500), description = this.body(body, 200_000);
    if (initialField) {
      const canonical = localProjectFields().find(field => field.id === initialField.id && field.kind === "singleSelect");
      const loaded = detail.fields.find(field => field.id === initialField.id && (field.kind ?? (field.options.length ? "singleSelect" : "unsupported")) === "singleSelect");
      if (row || !canonical || !loaded || option == null || !canonical.options.some(value => value.id === option) || !loaded.options.some(value => value.id === option)) fail("Choose a supported local project field.");
    } else if (option != null) fail("Choose a supported local project field.");
    return this.change(detail, project => {
      if (row) { const task = this.task(project, row); if (task.archived) fail("Restore this task before editing it."); task.title = name; task.body = description; task.updatedAt = new Date().toISOString(); }
      else {
        if (project.tasks.length >= localProjectLimits.maxTasksPerProject) fail("Local project data is invalid. Your saved data has not been changed.");
        const task: LocalPlannerTask = { id: `local-task:${crypto.randomUUID()}`, title: name, body: description, status: "local-todo", start: "", due: "", priority: "local-normal", assignees: [], archived: false, updatedAt: new Date().toISOString() };
        if (initialField) this.setField(task, initialField.id, option!);
        project.tasks.push(task);
      }
    });
  }
  async updateField(detail: HubDetail, row: HubProjectRow, field: HubProjectField, value?: string | null): Promise<HubDetail> {
    if (!detail.fields.some(candidate => candidate.id === field.id) || !localProjectFields().some(candidate => candidate.id === field.id)) fail("Choose a supported local project field.");
    return this.change(detail, project => this.setField(this.task(project, row), field.id, value ?? ""));
  }
  async archive(detail: HubDetail, row: HubProjectRow, archived: boolean): Promise<HubDetail> { return this.change(detail, project => { const task = this.task(project, row); task.archived = archived; task.updatedAt = new Date().toISOString(); }); }
  async updateFields(detail: HubDetail, rows: HubProjectRow[], field: HubProjectField, value?: string | null): Promise<HubDetail> {
    if (!detail.fields.some(candidate => candidate.id === field.id) || !localProjectFields().some(candidate => candidate.id === field.id)) fail("Choose a supported local project field.");
    return this.change(detail, project => { for (const row of rows.filter((row, index) => rows.findIndex(other => other.id === row.id) === index)) this.setField(this.task(project, row), field.id, value ?? ""); });
  }
  async archiveMany(detail: HubDetail, rows: HubProjectRow[], archived: boolean): Promise<HubDetail> {
    return this.change(detail, project => { for (const row of rows) { const task = this.task(project, row); task.archived = archived; task.updatedAt = new Date().toISOString(); } });
  }
  async removeItem(detail: HubDetail, row: HubProjectRow): Promise<HubDetail> { return this.removeMany(detail, [row]); }
  async removeMany(detail: HubDetail, rows: HubProjectRow[]): Promise<HubDetail> { return this.change(detail, project => {
    for (const row of rows) this.task(project, row);
    const ids = new Set(rows.map(row => row.id));
    if (project.tasks.some(task => !ids.has(task.id) && task.predecessorIDs?.some(id => ids.has(id)))) fail("Remove predecessor links from dependent tasks before deleting this task.");
    project.tasks = project.tasks.filter(task => !ids.has(task.id));
  }); }
  async setDependencies(detail: HubDetail, row: HubProjectRow, predecessorIDs: string[], durationDays?: number): Promise<HubDetail> {
    return this.change(detail, project => {
      const task = this.task(project, row);
      if (task.archived) fail("Restore this task before editing it.");
      task.predecessorIDs = [...predecessorIDs];
      if (durationDays === undefined) delete task.durationDays; else task.durationDays = durationDays;
      const error = validateProjectDependencies(project.tasks);
      if (error === "duration") fail("Enter a duration from 1 to 3650 whole days, or leave it empty.");
      if (error === "predecessors") fail("Choose up to 100 different predecessor tasks from this project, excluding this task.");
      if (error === "cycle") fail("These predecessor links would create a cycle.");
      task.updatedAt = new Date().toISOString();
    });
  }
  async reorder(detail: HubDetail, row: HubProjectRow, afterRow: HubProjectRow | null): Promise<HubDetail> {
    return this.change(detail, project => { const task = this.task(project, row); if (afterRow) this.task(project, afterRow); if (afterRow?.id === row.id) fail("Select a local project item."); project.tasks = project.tasks.filter(value => value.id !== row.id); project.tasks.splice(afterRow ? project.tasks.findIndex(value => value.id === afterRow.id) + 1 : 0, 0, task); });
  }
  async saveProject(detail: HubDetail, title: string, description: string): Promise<HubDetail> { const name = this.title(title, 200), body = this.body(description, 20_000); return this.change(detail, project => { project.title = name; project.description = body; }); }
  async deleteProject(detail: HubDetail): Promise<void> { await this.transaction(document => { this.current(document, detail); document.projects = document.projects.filter(project => project.id !== detail.item.id); }); }
  async setAssignees(detail: HubDetail, row: HubProjectRow, assignees: string[]): Promise<HubDetail> { return this.change(detail, project => { const task = this.task(project, row); if (task.archived) fail("Restore this task before editing it."); task.assignees = this.assignees(assignees); task.updatedAt = new Date().toISOString(); }); }
  async reschedule(detail: HubDetail, row: HubProjectRow, settings: ProjectScheduleSettings, targetDay: string): Promise<HubDetail> {
    return this.change(detail, project => {
      const task = this.task(project, row), actual = projectDetail(project).rows.find(value => value.id === task.id)!;
      const changes = scheduleReschedule(actual, localProjectFields(), settings, targetDay);
      for (const change of changes) this.setField(task, change.fieldID, change.value, false);
      this.validRange(task);
    });
  }
  private async change(detail: HubDetail, work: (project: LocalPlannerProject) => void): Promise<HubDetail> {
    let changed!: LocalPlannerProject;
    await this.transaction(document => { changed = this.current(document, detail); work(changed); changed.revision++; changed.updatedAt = new Date().toISOString(); });
    return projectDetail(changed);
  }
  private async transaction(work: (document: LocalPlannerDocument) => void): Promise<void> {
    if (this.writing) fail("Local projects are still saving. Try again in a moment.");
    this.writing = true; this.writeGeneration++; const operation = ++this.operation; this.loading = true; this.error = null; this.emit();
    try {
      const expected = await this.storage.read(), document = decodeLocalProjects(expected);
      work(document); document.revision++;
      const content = JSON.stringify(document); decodeLocalProjects(content);
      await this.storage.write(expected, content);
      if (this.operation === operation) this.publish(document);
    } catch (error) { this.error = this.message(error); throw new Error(this.error); }
    finally { this.writing = false; this.loading = false; this.emit(); }
  }
  private current(document: LocalPlannerDocument, detail: HubDetail): LocalPlannerProject {
    if (!isLocalProject(detail.item)) fail("This local project is unavailable.");
    const project = document.projects.find(project => project.id === detail.item.id);
    if (!project) fail("This local project is unavailable.");
    if (project.revision !== detail.item.data.localRevision) fail("This local project changed. Refresh before saving.");
    return project;
  }
  private task(project: LocalPlannerProject, row: HubProjectRow): LocalPlannerTask { const task = project.tasks.find(task => task.id === row.id); if (!task || !row.id.startsWith("local-task:")) fail("Select a local project item."); return task; }
  private setField(task: LocalPlannerTask, id: string, value: string, validateRange = true): void {
    if (task.archived) fail("Restore this task before editing it.");
    if (id === "local-status") { if (!localStatusIDs.includes(value)) fail("Choose a supported local project field."); task.status = value; }
    else if (id === "local-priority") { if (!localPriorityIDs.includes(value)) fail("Choose a supported local project field."); task.priority = value; }
    else if (id === "local-start" || id === "local-due") { if (value && !parseScheduleDay(value)) fail("Enter a date as YYYY-MM-DD."); if (id === "local-start") task.start = value; else task.due = value; }
    else if (id === "local-assignees") task.assignees = this.assignees(value.split(","));
    else fail("Choose a supported local project field.");
    if (validateRange) this.validRange(task);
    task.updatedAt = new Date().toISOString();
  }
  private validRange(task: LocalPlannerTask): void { if (task.start && task.due && task.start > task.due) fail("The start date must be on or before the due date."); }
  private assignees(values: string[]): string[] { const result = [...new Map(values.map(value => value.trim()).filter(Boolean).map(value => [value.toLowerCase(), value])).values()]; if (result.length > 20 || result.some(value => value.length > 100)) fail("Enter valid assignee names separated by commas."); return result; }
  private title(value: string, maximum: number): string { const title = value.trim(); if (!title || title.length > maximum) fail("A local project or task title is required."); return title; }
  private body(value: string, maximum: number): string { if (value.length > maximum) fail("Local project text is too long."); return value; }
  private publish(document: LocalPlannerDocument): void { this.projects = [...document.projects].sort((a, b) => b.updatedAt.localeCompare(a.updatedAt) || a.id.localeCompare(b.id)).map(projectItem); this.revision = document.revision; this.loaded = true; this.error = null; this.emit(); }
  private message(error: unknown): string { return t(error instanceof Error ? error.message : "Local project storage could not be read."); }
}
export const localProjects = new LocalProjectStore();
