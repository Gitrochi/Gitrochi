import { afterEach, describe, expect, it, vi } from "vitest";
import { createHubProjectTask, hubDetail, HubUncertainWriteError, localHubAccess, localProjects, type HubAccess, type HubDetail, type HubProjectField } from "@/entities/hosting";
import { ipc } from "@/shared/api";

const access = (): HubAccess => ({ target: { provider: "github", host: "github.com", path: "team/client", remote: "origin" }, token: "fixture-token", apiBase: "https://api.github.com", me: "reader" });
const field: HubProjectField = { id: "STATUS", name: "Status", kind: "singleSelect", options: [{ id: "ACTIVE", name: "In progress" }] };
const detail = (): HubDetail => ({ item: { id: "PROJECT", title: "Delivery", subtitle: "", body: "", url: "", data: {} }, fields: [field], rows: [{ id: "OLDER", title: "Same title", body: "", url: "", contentID: "DRAFT", statuses: {}, kind: "draft" }], members: [], repositories: [], assets: [], more: false });
const response = (value: unknown) => ({ status: 200, body: JSON.stringify({ data: value }) });
const created = () => response({ addProjectV2DraftIssue: { projectItem: { id: "NEW-EXACT" } } });
const request = (body: string | undefined) => JSON.parse(body ?? "{}") as { query: string; variables: { input: Record<string, unknown> } };
afterEach(() => vi.restoreAllMocks());

describe("task creation in a project column", () => {
  it("reads factual issue authors and draft creators without inventing missing metadata", async () => {
    const http = vi.spyOn(ipc, "http").mockImplementation(async (_method, _url, _headers, body) => {
      const query = request(body).query;
      expect(query).toContain("createdAt author{login}"); expect(query).toContain("createdAt creator{login}");
      return response({ node: { id: "PROJECT", title: "Delivery", fields: { nodes: [] }, items: { nodes: [
        { id: "ISSUE", content: { __typename: "Issue", id: "I", title: "Issue", author: { login: "issue-writer" }, createdAt: "2026-10-01T12:00:00Z" } },
        { id: "DRAFT", content: { __typename: "DraftIssue", id: "D", title: "Draft", creator: { login: "draft-writer" }, createdAt: "2026-10-02T13:00:00Z" } },
        { id: "HIDDEN", content: null },
      ], pageInfo: { hasNextPage: false } } } });
    });
    const loaded = await hubDetail(access(), "projects", detail().item);
    expect(loaded.rows.map(row => [row.author, row.createdAt])).toEqual([["issue-writer", "2026-10-01T12:00:00Z"], ["draft-writer", "2026-10-02T13:00:00Z"], [undefined, undefined]]);
    expect(http).toHaveBeenCalledTimes(1);
  });
  it("persists local status and priority in one write each, without HTTP or credentials", async () => {
    let raw: string | null = null;
    const read = vi.spyOn(ipc, "localProjectsRead").mockImplementation(async () => raw);
    const write = vi.spyOn(ipc, "localProjectsWrite").mockImplementation(async (expected, content) => { expect(expected).toBe(raw); raw = content; });
    const http = vi.spyOn(ipc, "http").mockRejectedValue(new Error("Unexpected HTTP"));
    const credentials = vi.spyOn(ipc, "secretGet").mockRejectedValue(new Error("Unexpected credential access"));
    const c = localHubAccess(), project = await localProjects.create("Plan");
    let loaded = await hubDetail(c, "projects", project);
    const stale = loaded;
    let count = write.mock.calls.length;
    await createHubProjectTask(c, loaded, "In progress task", "Notes", loaded.fields[0], "local-progress");
    expect(write).toHaveBeenCalledTimes(count + 1);
    loaded = await hubDetail(c, "projects", project);
    expect(loaded.rows[0]).toMatchObject({ body: "Notes", statuses: { "local-status": "local-progress", "local-priority": "local-normal" } });
    count = write.mock.calls.length;
    await createHubProjectTask(c, loaded, "Urgent task", "", loaded.fields.find(value => value.id === "local-priority"), "local-urgent");
    expect(write).toHaveBeenCalledTimes(count + 1);
    loaded = await hubDetail(c, "projects", project);
    expect(loaded.rows[1].values).toMatchObject({ "local-status": "local-todo", "local-priority": "local-urgent" });
    const before = raw, writes = write.mock.calls.length, reads = read.mock.calls.length;
    await expect(createHubProjectTask(c, loaded, "Invalid", "", loaded.fields[0], "forged-option")).rejects.toThrow();
    await expect(createHubProjectTask(c, loaded, "Unset", "", loaded.fields[0])).rejects.toThrow();
    await expect(createHubProjectTask(c, loaded, "Missing field", "", undefined, "local-progress")).rejects.toThrow();
    expect(read).toHaveBeenCalledTimes(reads);
    await expect(createHubProjectTask(c, stale, "Stale", "", stale.fields[0], "local-progress")).rejects.toThrow("changed");
    expect(raw).toBe(before); expect(write).toHaveBeenCalledTimes(writes);
    expect(http).not.toHaveBeenCalled(); expect(credentials).not.toHaveBeenCalled();
  });
  it("assigns the exact mutation result despite an existing task with the same title", async () => {
    const captured = { ...detail(), item: { ...detail().item }, fields: [{ ...field }] };
    const http = vi.spyOn(ipc, "http").mockImplementation(async (_method, url, _headers, body) => {
      expect(url).toBe("https://api.github.com/graphql");
      if (request(body).query.includes("addProjectV2DraftIssue")) { captured.item.id = "OTHER-PROJECT"; captured.fields[0].id = "OTHER-FIELD"; return created(); }
      return response({ updateProjectV2ItemFieldValue: { projectV2Item: { id: "NEW-EXACT" } } });
    });
    await createHubProjectTask(access(), captured, "  Same title  ", "Body", captured.fields[0], "ACTIVE");
    expect(http).toHaveBeenCalledTimes(2);
    expect(request(http.mock.calls[0][3]).variables.input).toEqual({ projectId: "PROJECT", title: "Same title", body: "Body" });
    expect(request(http.mock.calls[1][3]).variables.input).toEqual({ projectId: "PROJECT", itemId: "NEW-EXACT", fieldId: "STATUS", value: { singleSelectOptionId: "ACTIVE" } });
  });
  it("supports remote unset columns and keeps default creation to one mutation", async () => {
    const http = vi.spyOn(ipc, "http").mockImplementation(async (_method, _url, _headers, body) => request(body).query.includes("addProjectV2DraftIssue") ? created() : response({ clearProjectV2ItemFieldValue: { projectV2Item: { id: "NEW-EXACT" } } }));
    await createHubProjectTask(access(), detail(), "Unset", "", field);
    expect(request(http.mock.calls[1][3])).toMatchObject({ query: expect.stringContaining("ClearProjectV2ItemFieldValueInput"), variables: { input: { itemId: "NEW-EXACT", fieldId: "STATUS" } } });
    http.mockClear(); await createHubProjectTask(access(), detail(), "Default"); expect(http).toHaveBeenCalledTimes(1);
  });
  it("rejects stale, crossed and invalid column contexts before creating anything", async () => {
    const http = vi.spyOn(ipc, "http").mockRejectedValue(new Error("Unexpected HTTP"));
    await expect(createHubProjectTask({ ...access(), stillCurrent: () => false }, detail(), "Stale", "", field, "ACTIVE")).rejects.toThrow("account changed");
    await expect(createHubProjectTask(localHubAccess(), detail(), "Crossed", "", field, "ACTIVE")).rejects.toThrow("matching project workspace");
    await expect(createHubProjectTask(access(), detail(), "Unknown", "", { ...field, id: "FOREIGN" }, "ACTIVE")).rejects.toThrow("loaded project field");
    await expect(createHubProjectTask(access(), detail(), "Invalid", "", field, "MISSING")).rejects.toThrow("loaded project field");
    await expect(createHubProjectTask(access(), { ...detail(), fields: [{ ...field, kind: "iteration" }] }, "Wrong kind", "", field, "ACTIVE")).rejects.toThrow("loaded project field");
    await expect(createHubProjectTask(access(), detail(), "Missing field", "", undefined, "ACTIVE")).rejects.toThrow("loaded project field");
    await expect(createHubProjectTask(access(), detail(), " ", "", field, "ACTIVE")).rejects.toThrow("title");
    expect(http).not.toHaveBeenCalled();
  });
  it.each(["network", "permission", "wrong-item"])("marks a post-create %s failure uncertain without retrying or deleting", async failure => {
    const http = vi.spyOn(ipc, "http").mockImplementation(async (_method, _url, _headers, body) => {
      if (request(body).query.includes("addProjectV2DraftIssue")) return created();
      if (failure === "network") throw new Error("Assignment disconnected");
      if (failure === "permission") return { status: 200, body: JSON.stringify({ errors: [{ type: "FORBIDDEN", message: "Denied" }] }) };
      return response({ updateProjectV2ItemFieldValue: { projectV2Item: { id: "OTHER" } } });
    });
    const outcome = createHubProjectTask(access(), detail(), "Same title", "", field, "ACTIVE");
    await expect(outcome).rejects.toBeInstanceOf(HubUncertainWriteError); await expect(outcome).rejects.toThrow("Refresh the project before trying again");
    expect(http).toHaveBeenCalledTimes(2); expect(http.mock.calls.every(call => !request(call[3]).query.includes("delete"))).toBe(true);
  });
  it("keeps an explicit creation denial distinct from an uncertain partial write", async () => {
    const http = vi.spyOn(ipc, "http").mockResolvedValue({ status: 200, body: JSON.stringify({ errors: [{ type: "FORBIDDEN", message: "Denied" }] }) });
    const outcome = createHubProjectTask(access(), detail(), "Denied", "", field, "ACTIVE");
    await expect(outcome).rejects.not.toBeInstanceOf(HubUncertainWriteError);
    expect(http).toHaveBeenCalledTimes(1);
  });
  it("treats a missing creation ID and context change after creation as uncertain, without assignment or retry", async () => {
    const http = vi.spyOn(ipc, "http").mockResolvedValue(response({ addProjectV2DraftIssue: { projectItem: {} } }));
    await expect(createHubProjectTask(access(), detail(), "Missing ID", "", field, "ACTIVE")).rejects.toBeInstanceOf(HubUncertainWriteError); expect(http).toHaveBeenCalledTimes(1);
    http.mockClear(); let current = true; http.mockImplementation(async () => { current = false; return created(); });
    await expect(createHubProjectTask({ ...access(), stillCurrent: () => current }, detail(), "Context changed", "", field, "ACTIVE")).rejects.toBeInstanceOf(HubUncertainWriteError); expect(http).toHaveBeenCalledTimes(1);
  });
});
