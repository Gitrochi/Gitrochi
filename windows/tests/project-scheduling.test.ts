import { afterEach, describe, expect, it, vi } from "vitest";
import { HostingError, HubUncertainWriteError, type HubAccess, type HubDetail, type HubProjectRow } from "@/entities/hosting";
import { rescheduleHubProjectItem } from "../src/entities/hosting/api/project-scheduling";
import { ipc } from "@/shared/api";

const access: HubAccess = { target: { provider: "github", host: "github.com", path: "team/client", remote: "origin" }, token: "fixture-credential", apiBase: "https://api.github.com", me: "reviewer" };
const settings = { completedOptionIDs: [] };
const row = (values: Record<string, string> = { start: "2026-10-27", due: "2026-10-29" }, extra: Partial<HubProjectRow> = {}): HubProjectRow => ({ id: "ROW", title: "Task", body: "", url: "https://github.com/team/client/issues/1", contentID: "ISSUE", kind: "issue", statuses: {}, values, ...extra });
const detail = (task = row()): HubDetail => ({ item: { id: "PROJECT", title: "Delivery", subtitle: "", body: "", url: "", data: {} }, fields: [{ id: "start", name: "Start date", kind: "date", options: [] }, { id: "due", name: "Due date", kind: "date", options: [] }], rows: [task], more: false, files: [], members: [], repositories: [], assets: [] });
const response = (data: unknown, status = 200) => ({ status, body: JSON.stringify(status === 200 ? { data } : { message: data }) });
const fresh = (values: Record<string, string> = { start: "2026-10-27", due: "2026-10-29" }) => ({ id: "ROW", isArchived: false, project: { id: "PROJECT" }, fieldValues: { nodes: Object.entries(values).map(([id, date]) => ({ date, field: { id } })), pageInfo: { hasNextPage: false } } });
const body = (value?: string) => JSON.parse(value ?? "{}") as { query: string; variables: { input?: { projectId: string; itemId: string; fieldId: string; value: { date: string } }; id?: string } };
afterEach(() => vi.restoreAllMocks());

describe("project schedule writes", () => {
  it("compares fresh dates before shifting both ends of a range with the official field mutation", async () => {
    const http = vi.spyOn(ipc, "http").mockImplementation(async (_method, url, _headers, value) => {
      expect(url).toBe("https://api.github.com/graphql");
      return response(body(value).query.startsWith("query") ? { node: fresh() } : { updateProjectV2ItemFieldValue: { projectV2Item: { id: "ROW" } } });
    });
    await rescheduleHubProjectItem(access, detail(), row(), settings, "2026-11-02");
    expect(http).toHaveBeenCalledTimes(3);
    expect(body(http.mock.calls[0][3]).variables).toEqual({ id: "ROW" });
    expect(http.mock.calls.slice(1).map(call => body(call[3]).variables.input)).toEqual([
      { projectId: "PROJECT", itemId: "ROW", fieldId: "start", value: { date: "2026-10-31" } },
      { projectId: "PROJECT", itemId: "ROW", fieldId: "due", value: { date: "2026-11-02" } },
    ]);
  });
  it("does no work for unchanged dates and ignores caller-forged dates in favor of loaded records", async () => {
    const http = vi.spyOn(ipc, "http").mockResolvedValue(response({ node: fresh() }));
    await rescheduleHubProjectItem(access, detail(), row({ due: "2030-01-01" }), settings, "2026-10-29");
    expect(http).not.toHaveBeenCalled();
  });
  it("refuses invalid, unavailable, foreign or stale inputs before any request", async () => {
    const http = vi.spyOn(ipc, "http").mockResolvedValue(response({}));
    for (const task of [row({ due: "2026-02-30" }), row({ start: "2026-10-30", due: "2026-10-27" }), row({}, { archived: true }), row({}, { kind: "redacted" })]) await expect(rescheduleHubProjectItem(access, detail(task), task, settings, "2026-11-02")).rejects.toThrow();
    await expect(rescheduleHubProjectItem(access, detail(), { ...row(), id: "FOREIGN" }, settings, "2026-11-02")).rejects.toThrow();
    await expect(rescheduleHubProjectItem({ ...access, target: { ...access.target, provider: "gitlab" } }, detail(), row(), settings, "2026-11-02")).rejects.toThrow();
    await expect(rescheduleHubProjectItem({ ...access, stillCurrent: () => false }, detail(), row(), settings, "2026-11-02")).rejects.toThrow();
    await expect(rescheduleHubProjectItem(access, detail(), row(), settings, "2026-02-30")).rejects.toThrow();
    expect(http).not.toHaveBeenCalled();
  });
  it("rejects collaborator changes to unchanged start fields before adding a due date", async () => {
    const task = row({ start: "2026-10-27" });
    const http = vi.spyOn(ipc, "http").mockResolvedValue(response({ node: fresh({ start: "2026-11-10" }) }));
    await expect(rescheduleHubProjectItem(access, detail(task), task, settings, "2026-11-02")).rejects.toThrow("changed on the server");
    expect(http).toHaveBeenCalledTimes(1);
  });
  it("requires complete project membership, archive and date metadata before any mutation", async () => {
    const http = vi.spyOn(ipc, "http");
    const original = fresh();
    for (const node of [{ ...original, project: { id: "OTHER" } }, { ...original, isArchived: true }, { ...original, fieldValues: { ...original.fieldValues, pageInfo: { hasNextPage: true } } }, { ...original, isArchived: undefined }, { ...original, fieldValues: { nodes: original.fieldValues.nodes } }]) {
      http.mockClear().mockResolvedValue(response({ node }));
      await expect(rescheduleHubProjectItem(access, detail(), row(), settings, "2026-11-02")).rejects.toThrow("changed on the server");
      expect(http).toHaveBeenCalledTimes(1);
    }
  });
  it("locks uncertain range results after a partial failure while preserving definite first-write rejection", async () => {
    let writes = 0;
    const http = vi.spyOn(ipc, "http").mockImplementation(async (_m, _u, _h, value) => body(value).query.startsWith("query") ? response({ node: fresh() }) : ++writes === 1 ? response({}) : response("Forbidden", 403));
    await expect(rescheduleHubProjectItem(access, detail(), row(), settings, "2026-11-02")).rejects.toBeInstanceOf(HubUncertainWriteError);
    expect(http).toHaveBeenCalledTimes(3);
    http.mockClear().mockImplementation(async (_m, _u, _h, value) => body(value).query.startsWith("query") ? response({ node: fresh() }) : response("Forbidden", 403));
    await expect(rescheduleHubProjectItem(access, detail(), row(), settings, "2026-11-02")).rejects.toBeInstanceOf(HostingError);
    expect(http).toHaveBeenCalledTimes(2);
  });
  it("rechecks context after the fresh read and never sends a mutation to an expired account", async () => {
    let current = true;
    const http = vi.spyOn(ipc, "http").mockImplementation(async () => { current = false; return response({ node: fresh() }); });
    await expect(rescheduleHubProjectItem({ ...access, stillCurrent: () => current }, detail(), row(), settings, "2026-11-02")).rejects.toThrow();
    expect(http).toHaveBeenCalledTimes(1);
  });
});
