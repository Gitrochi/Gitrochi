import { describe, expect, it } from "vitest";
import type { HubAccess, HubDetail, HubItem, HubPage, HubProjectRow } from "@/entities/hosting";
import { ProjectPortfolioState, portfolioTasks, type ProjectPortfolioReader } from "../src/entities/hosting/model/project-portfolio";

const item = (id: string): HubItem => ({ id, title: `Project ${id}`, body: "", subtitle: "", url: "", data: {} });
const row = (id: string, due = "", extra: Partial<HubProjectRow> = {}): HubProjectRow => ({ id, title: id, body: "", url: "", contentID: id, kind: "issue", statuses: {}, values: due ? { due } : {}, ...extra });
const detail = (id: string, rows: HubProjectRow[] = [], more = false, cursor?: string): HubDetail => ({ item: item(id), fields: [{ id: "due", name: "Due date", kind: "date", options: [] }], rows, more, cursor, files: [], members: [], repositories: [], assets: [] });
const access: HubAccess = { target: { provider: "github", host: "github.com", path: "team/client", remote: "origin" }, token: "fixture-credential", apiBase: "https://api.github.com", me: "reviewer" };
function deferred<T>() { let resolve!: (value: T) => void; const promise = new Promise<T>((done) => { resolve = done; }); return { promise, resolve }; }

describe("project portfolio reads", () => {
  it("preserves the account-free local backend and its stale-context guard", async () => {
    let current = true;
    const delayed = deferred<HubPage>();
    const local: HubAccess = { target: { provider: "github", host: "local", path: "local/workspace", remote: "origin" }, token: "", apiBase: "", me: "", local: true, stillCurrent: () => current };
    const captured: HubAccess[] = [];
    const model = new ProjectPortfolioState({ page: async c => { captured.push(c); return delayed.promise; }, detail: async (c, selected) => { captured.push(c); return detail(selected.id, [row("local-task")]); } });
    const pending = model.load(local, "local");
    expect(captured[0]).toMatchObject({ local: true, token: "", apiBase: "", me: "" });
    current = false;
    delayed.resolve({ items: [item("local:project")], more: false });
    await pending;
    expect(model.projects).toEqual([]);
    expect(captured).toHaveLength(1);
    current = true;
    await model.load(local, "local");
    await model.refresh(local, "local");
    expect(model.details[0].rows[0].id).toBe("local-task");
    expect(captured.every(c => c.local && !c.token && !c.apiBase)).toBe(true);
  });
  it("restores selected IDs beyond the catalog page using authoritative detail metadata", async () => {
    const calls: string[] = [];
    const model = new ProjectPortfolioState({
      page: async () => ({ items: [item("first-page")], more: true, cursor: "next-catalog-page" }),
      detail: async (_c, selected) => { calls.push(selected.id); if (selected.id === "removed") throw new Error("Not found"); return { ...detail(selected.id, [row("task", "2026-10-28")]), item: { ...item(selected.id), title: "Actual project title" } }; },
    });
    model.reset("account");
    model.setSelected(["later-page", "removed"]);
    await model.load(access, "account");
    expect(calls).toEqual(["later-page", "removed"]);
    expect(model.projects.map(value => value.title)).toEqual(["Project first-page", "Actual project title"]);
    expect(model.details[0].item.id).toBe("later-page");
    expect(model.projectErrors.removed).toBe("Not found");
    expect(model.projects.some(value => value.id === "removed")).toBe(false);
    expect(model.more).toBe(true);
  });
  it("loads the first three selected projects without limiting later explicit selections", async () => {
    const calls: string[] = [];
    const reader: ProjectPortfolioReader = { page: async () => ({ items: ["a", "b", "c", "d"].map(item), more: false }), detail: async (_c, selected) => { calls.push(selected.id); return detail(selected.id, [row(selected.id)]); } };
    const model = new ProjectPortfolioState(reader);
    await model.load(access, "account-a");
    expect(model.selectedIDs).toEqual(["a", "b", "c"]);
    expect(calls).toEqual(["a", "b", "c"]);
    model.setSelected(["a", "b", "c", "d", "d"]);
    await model.refresh(access, "account-a");
    expect(model.details).toHaveLength(4);
    model.setSelected([]);
    await model.load(access, "account-a");
    expect(model.selectedIDs).toEqual([]);
    expect(model.details).toEqual([]);
  });
  it("clears old account data immediately and rejects late reads and late errors", async () => {
    const oldPage = deferred<HubPage>();
    const reader: ProjectPortfolioReader = { page: async (c) => c.me === "old" ? oldPage.promise : { items: [item("new")], more: false }, detail: async (_c, selected) => detail(selected.id, [row(selected.id)]) };
    const model = new ProjectPortfolioState(reader);
    model.projects = [item("private-old")]; model.details = [detail("private-old")];
    const old = model.load({ ...access, me: "old" }, "old-account");
    const current = model.load({ ...access, me: "new" }, "new-account");
    expect(model.projects).toEqual([]);
    expect(model.details).toEqual([]);
    await current;
    oldPage.resolve({ items: [item("old")], more: true });
    await old;
    expect(model.projects.map(value => value.id)).toEqual(["new"]);
    expect(model.details.map(value => value.item.id)).toEqual(["new"]);
    expect(model.loading).toBe(false);
  });
  it("uses the latest refresh and keeps partial failures until that project actually succeeds", async () => {
    let failB = true, calls = 0;
    const delayed = deferred<HubDetail>();
    const reader: ProjectPortfolioReader = { page: async () => ({ items: [item("a"), item("b")], more: false }), detail: async (_c, selected) => {
      if (selected.id === "b" && failB) throw new Error(`Unavailable ${access.token}`);
      if (selected.id === "a" && ++calls === 2) return delayed.promise;
      return detail(selected.id, [row(`${selected.id}-${calls}`)]);
    } };
    const model = new ProjectPortfolioState(reader);
    await model.load(access, "account");
    expect(model.details.map(value => value.item.id)).toEqual(["a"]);
    expect(model.projectErrors.b).toBe("Unavailable [redacted]");
    const old = model.refresh(access, "account");
    failB = false;
    await model.refresh(access, "account");
    delayed.resolve(detail("a", [row("stale")]));
    await old;
    expect(model.details.flatMap(value => value.rows).some(value => value.id === "stale")).toBe(false);
    expect(model.projectErrors).toEqual({});
    expect(model.details.map(value => value.item.id)).toEqual(["a", "b"]);
    expect(model.loading).toBe(false);
  });
  it("paginates catalog and selected items with truthful cursors and row deduplication", async () => {
    const pages: (string | number | undefined)[][] = [];
    const reader: ProjectPortfolioReader = { page: async (_c, page, cursor) => { pages.push(["catalog", page, cursor]); return page === 1 ? { items: [item("a")], more: true, cursor: "catalog-next" } : { items: [item("a"), item("b")], more: false }; }, detail: async (_c, selected, page, cursor) => { pages.push([selected.id, page, cursor]); return page === 1 ? detail(selected.id, [row("one", "2026-10-27")], true, "items-next") : detail(selected.id, [row("one"), row("two", "2026-10-28")], false); } };
    const model = new ProjectPortfolioState(reader);
    await model.load(access, "account");
    await model.loadMoreItems(access, "account", "a");
    expect(model.details[0].rows.map(value => value.id)).toEqual(["one", "two"]);
    expect(model.details[0].more).toBe(false);
    expect(model.details[0].rows[0].values?.due).toBe("2026-10-27");
    await model.load(access, "account", true);
    expect(model.projects.map(value => value.id)).toEqual(["a", "b"]);
    expect(model.more).toBe(false);
    expect(pages).toContainEqual(["a", 2, "items-next"]);
    expect(pages).toContainEqual(["catalog", 2, "catalog-next"]);
  });
  it("does not start or publish reads after an access context has expired", async () => {
    let calls = 0, current = true;
    const delayed = deferred<HubPage>();
    const model = new ProjectPortfolioState({ page: async () => { calls++; return delayed.promise; }, detail: async (_c, selected) => { calls++; return detail(selected.id); } });
    const pending = model.load({ ...access, stillCurrent: () => current }, "account");
    current = false;
    delayed.resolve({ items: [item("a")], more: false });
    await pending;
    expect(model.projects).toEqual([]);
    expect(model.loading).toBe(false);
    expect(calls).toBe(1);
  });
});

describe("portfolio task identity and actual dates", () => {
  it("keeps active membership dates when another project's completed membership has an earlier deadline", () => {
    const shared = { contentID: "content", url: "https://github.com/team/client/issues/1" };
    const records = [detail("done", [row("closed", "2026-10-01", { ...shared, state: "CLOSED" })]), detail("active", [row("open", "2026-11-01", { ...shared, state: "OPEN" })])];
    const task = portfolioTasks(records)[0];
    expect(task.entry.completed).toBe(false);
    expect(task.detail.item.id).toBe("active");
    expect(task.entry.due).toBe("2026-11-01");
    expect(task.projectNames).toEqual(["Project active", "Project done"]);
    records[1].rows[0].state = "CLOSED";
    expect(portfolioTasks(records)[0]).toMatchObject({ detail: { item: { id: "done" } }, entry: { completed: true, due: "2026-10-01" } });
  });
  it("deduplicates issues across projects, retains earliest actual dates and keeps drafts separate", () => {
    const shared = { contentID: "content", url: "https://github.com/team/client/issues/1" };
    const records = [detail("a", [row("a-one", "2026-10-29", shared), row("draft", "", { kind: "draft", contentID: "same-draft" })]), detail("b", [row("b-one", "2026-10-27", shared), row("draft", "", { kind: "draft", contentID: "same-draft" }), row("archived", "", { archived: true }), row("private", "", { kind: "redacted" })])];
    const tasks = portfolioTasks(records);
    expect(tasks).toHaveLength(3);
    expect(tasks[0].detail.item.id).toBe("b");
    expect(tasks[0].entry.due).toBe("2026-10-27");
    expect(tasks[0].projectNames).toEqual(["Project a", "Project b"]);
    expect(portfolioTasks([...records].reverse()).map(task => task.id)).toEqual(tasks.map(task => task.id));
    expect(tasks.filter(task => task.entry.row.kind === "draft")).toHaveLength(2);
  });
  it("joins URL-only records without using invalid dates or mixing hosts", () => {
    const url = "https://github.com/team/client/issues/1";
    const tasks = portfolioTasks([detail("a", [row("a", "2026-02-30", { url, contentID: "one" })]), detail("b", [row("b", "2026-10-30", { url: `${url}/?tracking=1#body`, contentID: "" })]), detail("c", [row("c", "2026-10-28", { url: "https://code.example.com/team/client/issues/1", contentID: "one" })])]);
    expect(tasks).toHaveLength(2);
    expect(tasks[0].detail.item.id).toBe("c");
    expect(tasks[1].detail.item.id).toBe("b");
    expect(tasks[1].projectNames).toEqual(["Project a", "Project b"]);
    expect(tasks[1].entry.due).toBe("2026-10-30");
  });
});
