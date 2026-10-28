import { describe, expect, it } from "vitest";
import { LocalProjectStore, projectDependencyGraph, validateProjectDependencies, type HubProjectRow, type LocalProjectPersistence } from "@/entities/hosting";
import { decodeLocalProjects } from "../src/entities/hosting/model/local-project-document";

class MemoryPersistence implements LocalProjectPersistence {
  raw: string | null = null;
  writes = 0;
  failed = false;
  async read() { return this.raw; }
  async write(expected: string | null, content: string) {
    if (this.failed) throw new Error("Synthetic storage failure");
    if (expected !== this.raw) throw new Error("Stale document");
    this.raw = content; this.writes++;
  }
}
const row = (id: string, predecessors: string[] = [], durationDays?: number): HubProjectRow => ({
  id, title: id, body: "", url: "", contentID: id, statuses: { "local-status": "local-todo" }, predecessorIDs: predecessors, durationDays,
});
async function fixture() {
  const storage = new MemoryPersistence(), model = new LocalProjectStore(storage), project = await model.create("Delivery plan");
  let detail = await model.detail(project.id);
  for (const title of ["Design", "Implement", "Review"]) detail = await model.saveDraft(detail, title, "");
  return { storage, model, detail };
}

describe("local task predecessor plans", () => {
  it("opens older documents with absent optional fields and preserves new fields through unrelated edits", async () => {
    const { storage, model, detail: original } = await fixture();
    expect(decodeLocalProjects(storage.raw).projects[0].tasks[0].predecessorIDs).toBeUndefined();
    let detail = await model.setDependencies(original, original.rows[1], [original.rows[0].id], 5);
    detail = await model.saveDraft(detail, "Implementation", "Keep predecessors", detail.rows[1]);
    detail = await model.reorder(detail, detail.rows[1], null);
    const reopened = await new LocalProjectStore(storage).detail(detail.item.id), task = reopened.rows.find((value) => value.title === "Implementation")!;
    expect(task.predecessorIDs).toEqual([original.rows[0].id]); expect(task.durationDays).toBe(5);
    expect(JSON.parse(storage.raw!).version).toBe(1);
  });
  it("saves the DAG atomically without changing dates and derives readiness from actual status", async () => {
    const { storage, model, detail: original } = await fixture();
    let detail = original;
    detail = await model.updateField(detail, detail.rows[1], detail.fields.find((field) => field.id === "local-due")!, "2026-11-12");
    const beforeDates = detail.rows.map((value) => value.values), writes = storage.writes;
    detail = await model.setDependencies(detail, detail.rows[1], [detail.rows[0].id], 3);
    expect(storage.writes).toBe(writes + 1); expect(detail.rows.map((value) => value.values)).toEqual(beforeDates);
    let graph = projectDependencyGraph(detail.rows);
    expect(graph.nodes.find((node) => node.row.id === detail.rows[1].id)?.blockedBy).toEqual([detail.rows[0].id]);
    expect(graph.durationDays).toBeUndefined();
    detail = await model.updateField(detail, detail.rows[0], detail.fields[0], "local-done");
    graph = projectDependencyGraph(detail.rows);
    expect(graph.nodes.find((node) => node.row.id === detail.rows[1].id)?.blockedBy).toEqual([]);
  });
  it("rejects self, duplicate, missing, foreign, cyclic, oversized, malformed and stale edits without a write", async () => {
    const { storage, model, detail: original } = await fixture();
    const detail = await model.setDependencies(original, original.rows[1], [original.rows[0].id], 2), before = storage.raw, writes = storage.writes;
    for (const predecessors of [[detail.rows[0].id], ["local-task:missing"], [detail.rows[2].id, detail.rows[2].id], Array.from({ length: 101 }, (_, index) => `missing-${index}`)]) {
      await expect(model.setDependencies(detail, detail.rows[0], predecessors)).rejects.toThrow();
    }
    await expect(model.setDependencies(detail, detail.rows[0], [detail.rows[1].id])).rejects.toThrow("cycle");
    for (const duration of [0, -1, 1.5, 3651, Infinity, NaN]) await expect(model.setDependencies(detail, detail.rows[2], [], duration)).rejects.toThrow("duration");
    await expect(model.setDependencies(original, original.rows[2], [], 2)).rejects.toThrow("changed");
    await expect(model.setDependencies(detail, { ...detail.rows[0], id: "local-task:foreign" }, [])).rejects.toThrow();
    expect(storage.raw).toBe(before); expect(storage.writes).toBe(writes);
  });
  it("preserves corrupt dependency documents instead of silently clearing links", async () => {
    const { storage, model, detail } = await fixture(), valid = JSON.parse(storage.raw!);
    for (const patch of [{ predecessorIDs: null }, { predecessorIDs: "text" }, { predecessorIDs: [detail.rows[0].id] }, { predecessorIDs: [42] }, { durationDays: null }, { durationDays: "5" }, { durationDays: 0 }]) {
      const document = structuredClone(valid);
      Object.assign(document.projects[0].tasks[0], patch);
      const invalid = JSON.stringify(document); storage.raw = invalid;
      expect(() => decodeLocalProjects(invalid)).toThrow("invalid");
      const writes = storage.writes;
      await expect(model.create("Do not overwrite")).rejects.toThrow("saved data has not been changed");
      expect(storage.raw).toBe(invalid); expect(storage.writes).toBe(writes);
    }
  });
  it("requires dependent links to be removed before deleting a predecessor and permits an atomic whole-subgraph removal", async () => {
    const { storage, model, detail: original } = await fixture();
    let detail = await model.setDependencies(original, original.rows[1], [original.rows[0].id]);
    const before = storage.raw;
    await expect(model.removeItem(detail, detail.rows[0])).rejects.toThrow("predecessor links");
    expect(storage.raw).toBe(before);
    detail = await model.removeMany(detail, detail.rows.slice(0, 2));
    expect(detail.rows.map((value) => value.title)).toEqual(["Review"]);
  });
  it("keeps unfinished archived predecessors as blockers and preserves failed edits", async () => {
    const { storage, model, detail: original } = await fixture();
    let detail = await model.setDependencies(original, original.rows[1], [original.rows[0].id], 2);
    detail = await model.archive(detail, detail.rows[0], true);
    expect(projectDependencyGraph(detail.rows).nodes.find((node) => node.row.id === detail.rows[1].id)?.blockedBy).toEqual([detail.rows[0].id]);
    expect(projectDependencyGraph(detail.rows).durationDays).toBeUndefined();
    await expect(model.setDependencies(detail, detail.rows[0], [])).rejects.toThrow("Restore");
    const before = storage.raw; storage.failed = true;
    await expect(model.setDependencies(detail, detail.rows[1], [], 3)).rejects.toThrow("Synthetic storage failure");
    expect(storage.raw).toBe(before);
  });
});

describe("predecessor graph analysis", () => {
  it("finds all critical branches from explicit durations and excludes shorter parallel work", () => {
    const graph = projectDependencyGraph([row("A", [], 2), row("B", ["A"], 4), row("C", ["A"], 4), row("D", ["B", "C"], 1), row("E", [], 1)]);
    expect(graph.durationDays).toBe(7);
    expect(graph.nodes.filter((node) => node.critical).map((node) => node.row.id)).toEqual(["A", "B", "C", "D"]);
    expect(graph.nodes.find((node) => node.row.id === "D")?.level).toBe(2);
  });
  it("does not invent missing durations, rejects invalid graphs, and removes completed work from remaining duration", () => {
    expect(projectDependencyGraph([row("A")]).durationDays).toBeUndefined();
    expect(projectDependencyGraph([row("A", ["B"]), row("B", ["A"])]).error).toBe("cycle");
    expect(projectDependencyGraph([row("A", ["missing"])]).error).toBe("predecessors");
    expect(projectDependencyGraph([row("A", [], 1.5)]).error).toBe("duration");
    const completed = row("A"); completed.statuses["local-status"] = "local-done";
    const graph = projectDependencyGraph([completed, row("B", ["A"], 4)]);
    expect(graph.durationDays).toBe(4); expect(graph.nodes[1].blockedBy).toEqual([]);
    expect(projectDependencyGraph([completed]).durationDays).toBeUndefined();
  });
  it("handles a 10,000-task chain without recursive stack limits", () => {
    const rows = Array.from({ length: 10_000 }, (_, index) => row(`task-${index}`, index ? [`task-${index - 1}`] : [], 1));
    expect(validateProjectDependencies(rows)).toBeUndefined();
    const graph = projectDependencyGraph(rows);
    expect(graph.nodes).toHaveLength(10_000); expect(graph.durationDays).toBe(10_000);
    expect(graph.nodes[9999].level).toBe(9999);
  });
});
