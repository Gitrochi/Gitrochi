import { describe, expect, it, vi } from "vitest";
import { ipc } from "@/shared/api";
import { LocalProjectStore, isLocalProject, localProjectLimits, type LocalProjectPersistence } from "@/entities/hosting";
import { scheduleEntries, scheduleSummary } from "../src/entities/hosting/model/project-schedule";

class MemoryPersistence implements LocalProjectPersistence {
  raw: string | null = null;
  writes = 0;
  failWrite = false;
  async read() { return this.raw; }
  async write(expected: string | null, content: string) {
    if (this.failWrite) throw new Error("Disk unavailable");
    if (this.raw !== expected) throw new Error("Stale document");
    this.raw = content; this.writes++;
  }
}

describe("durable local planner projects", () => {
  it("creates and reloads projects and task details without an account or network", async () => {
    const http = vi.spyOn(ipc, "http").mockRejectedValue(new Error("Unexpected HTTP"));
    const credentials = vi.spyOn(ipc, "secretGet").mockRejectedValue(new Error("Unexpected credential access"));
    const storage = new MemoryPersistence(), model = new LocalProjectStore(storage);
    const project = await model.create("  Release plan  ", "Local team schedule");
    expect(isLocalProject(project)).toBe(true);
    let detail = await model.detail(project.id);
    detail = await model.saveDraft(detail, "Task one", "Implementation notes");
    detail = await model.saveDraft(detail, "Task two", "");
    const restarted = new LocalProjectStore(storage);
    await restarted.load();
    expect(restarted.projects.map(value => value.title)).toEqual(["Release plan"]);
    expect((await restarted.detail(project.id)).rows.map(row => [row.title, row.body])).toEqual([["Task one", "Implementation notes"], ["Task two", ""]]);
    expect(http).not.toHaveBeenCalled(); expect(credentials).not.toHaveBeenCalled();
    http.mockRestore(); credentials.mockRestore();
  });
  it("edits status, priority, assignees, dates and task contents with real scheduling semantics", async () => {
    const model = new LocalProjectStore(new MemoryPersistence()), project = await model.create("Plan");
    let detail = await model.saveDraft(await model.detail(project.id), "Task", "Before");
    const field = (id: string) => detail.fields.find(field => field.id === id)!;
    detail = await model.updateField(detail, detail.rows[0], field("local-start"), "2026-10-27");
    detail = await model.updateField(detail, detail.rows[0], field("local-due"), "2026-10-29");
    detail = await model.updateField(detail, detail.rows[0], field("local-priority"), "local-high");
    detail = await model.updateField(detail, detail.rows[0], field("local-assignees"), "alex, sam, ALEX");
    expect(detail.rows[0].assignees?.map(value => value.toLowerCase()).sort()).toEqual(["alex", "sam"]);
    detail = await model.saveDraft(detail, "Edited task", "After", detail.rows[0]);
    detail = await model.updateField(detail, detail.rows[0], field("local-status"), "local-done");
    expect(detail.rows[0]).toMatchObject({ title: "Edited task", body: "After", state: "CLOSED", values: { "local-priority": "local-high" } });
    expect(scheduleSummary(scheduleEntries(detail.rows, detail.fields), "2026-10-27")).toMatchObject({ completed: 1, active: 0 });
    const localized = detail.fields.map(value => ({ ...value, name: "Localized field" }));
    expect(scheduleEntries(detail.rows, localized)[0]).toMatchObject({ start: "2026-10-27", due: "2026-10-29", completed: true });
  });
  it("rejects stale, foreign and invalid updates without changing durable data", async () => {
    const storage = new MemoryPersistence(), model = new LocalProjectStore(storage), project = await model.create("Plan");
    const stale = await model.detail(project.id);
    let detail = await model.saveDraft(stale, "Task", "");
    const before = storage.raw, writes = storage.writes;
    await expect(model.saveProject(stale, "Overwrite", "")).rejects.toThrow("changed");
    await expect(model.updateField(detail, detail.rows[0], detail.fields.find(field => field.id === "local-due")!, "2026-02-30")).rejects.toThrow();
    await expect(model.updateField(detail, { ...detail.rows[0], id: "foreign" }, detail.fields[0], "local-done")).rejects.toThrow();
    await expect(model.saveProject({ ...detail, item: { ...detail.item, id: "REMOTE", data: {} } }, "Remote", "")).rejects.toThrow();
    expect(storage.raw).toBe(before); expect(storage.writes).toBe(writes);
    detail = await model.updateField(detail, detail.rows[0], detail.fields.find(field => field.id === "local-start")!, "2026-11-02");
    const rangeBefore = storage.raw;
    await expect(model.updateField(detail, detail.rows[0], detail.fields.find(field => field.id === "local-due")!, "2026-10-30")).rejects.toThrow("start date");
    expect(storage.raw).toBe(rangeBefore);
  });
  it("reschedules both ends atomically while preserving calendar duration", async () => {
    const storage = new MemoryPersistence(), model = new LocalProjectStore(storage), project = await model.create("Plan");
    let detail = await model.saveDraft(await model.detail(project.id), "Task", "");
    detail = await model.updateField(detail, detail.rows[0], detail.fields.find(field => field.id === "local-start")!, "2026-03-07");
    detail = await model.updateField(detail, detail.rows[0], detail.fields.find(field => field.id === "local-due")!, "2026-03-09");
    const writes = storage.writes;
    detail = await model.reschedule(detail, detail.rows[0], { completedOptionIDs: [] }, "2026-11-02");
    expect(storage.writes).toBe(writes + 1);
    expect(detail.rows[0].values).toMatchObject({ "local-start": "2026-10-31", "local-due": "2026-11-02" });
  });
  it("applies bulk status/archive/remove in one revision and reorders actual records", async () => {
    const storage = new MemoryPersistence(), model = new LocalProjectStore(storage), project = await model.create("Plan");
    let detail = await model.saveDraft(await model.detail(project.id), "First", "");
    detail = await model.saveDraft(detail, "Second", "");
    const first = detail.rows[0].id, second = detail.rows[1].id;
    detail = await model.reorder(detail, detail.rows[1], null);
    expect(detail.rows.map(row => row.id)).toEqual([second, first]);
    let writes = storage.writes;
    detail = await model.updateFields(detail, detail.rows, detail.fields[0], "local-done");
    expect(storage.writes).toBe(writes + 1); expect(detail.rows.every(row => row.state === "CLOSED")).toBe(true);
    writes = storage.writes;
    detail = await model.archiveMany(detail, detail.rows, true);
    expect(storage.writes).toBe(writes + 1); expect(detail.rows.every(row => row.archived)).toBe(true);
    await expect(model.saveDraft(detail, "Forbidden edit", "", detail.rows[0])).rejects.toThrow("Restore");
    detail = await model.archiveMany(detail, detail.rows, false);
    const before = storage.raw;
    await expect(model.updateFields(detail, [...detail.rows, { ...detail.rows[0], id: "foreign" }], detail.fields[0], "local-todo")).rejects.toThrow();
    expect(storage.raw).toBe(before);
    detail = await model.removeMany(detail, detail.rows);
    expect(detail.rows).toEqual([]);
    await model.deleteProject(detail);
    expect(model.projects).toEqual([]);
  });
  it("preserves saved data when decoding fails or the atomic storage write is rejected", async () => {
    const storage = new MemoryPersistence(), model = new LocalProjectStore(storage), project = await model.create("Plan");
    const detail = await model.detail(project.id), before = storage.raw;
    storage.failWrite = true;
    await expect(model.saveProject(detail, "Unsaved", "")).rejects.toThrow("Disk unavailable");
    expect(storage.raw).toBe(before); expect(model.projects[0].title).toBe("Plan");
    storage.failWrite = false;
    for (const invalid of ["invalid JSON", '{"version":2,"revision":0,"projects":[]}', '{"version":1,"revision":0,"projects":[{}]}']) {
      storage.raw = invalid; const writes = storage.writes;
      await expect(model.create("Do not overwrite")).rejects.toThrow("saved data has not been changed");
      expect(storage.raw).toBe(invalid); expect(storage.writes).toBe(writes);
    }
    expect(localProjectLimits).toEqual({ maxProjects: 1000, maxTasksPerProject: 10000, maxBytes: 50000000 });
  });
});
