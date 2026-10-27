import { afterEach, describe, expect, it, vi } from "vitest";
import { archiveHubProjectItem, convertHubProjectDraftToIssue, createHubProject, deleteHubProjectItem, hubDetail, hubPage, hubProjectViews, inspectHubProjectCreationCapabilities, localProjects, moveHubProjectItemPosition, rescheduleHubProjectItem, saveHubProjectDraft, saveHubProjectSettings, updateHubProjectField, type HubAccess } from "@/entities/hosting";
import { ipc } from "@/shared/api";

const access = (): HubAccess => ({ target: { provider: "github", host: "github.com", path: "reader/workspace", remote: "origin" }, token: "", apiBase: "https://api.github.com", me: "", local: true });
function memoryStorage() {
  let raw: string | null = null;
  const read = vi.spyOn(ipc, "localProjectsRead").mockImplementation(async () => raw);
  const write = vi.spyOn(ipc, "localProjectsWrite").mockImplementation(async (expected, content) => { if (expected !== raw) throw new Error("stale fixture"); raw = content; });
  const http = vi.spyOn(ipc, "http").mockImplementation(async () => { throw new Error("Local project reached HTTP"); });
  return { read, write, http };
}
afterEach(() => vi.restoreAllMocks());

describe("project backend routing", () => {
  it("routes local planning operations and settings into memory persistence without credentials or HTTP", async () => {
    const storage = memoryStorage(), c = access(), created = await localProjects.create("Local plan", "Device notes");
    expect((await hubPage(c, "projects")).items.map(item => item.id)).toEqual([created.id]);
    let detail = await hubDetail(c, "projects", created);
    await saveHubProjectSettings(c, detail, { title: "Renamed local plan", shortDescription: "Local summary", readme: "Ignored cloud readme", public: true, closed: true });
    detail = await hubDetail(c, "projects", created);
    expect(detail.item).toMatchObject({ title: "Renamed local plan", body: "Local summary", url: "" }); expect(detail.item.data).not.toHaveProperty("public");
    await saveHubProjectDraft(c, detail, "First", "Body"); detail = await hubDetail(c, "projects", created); const first = detail.rows[0];
    await saveHubProjectDraft(c, detail, "Second", ""); detail = await hubDetail(c, "projects", created); const second = detail.rows[1];
    await moveHubProjectItemPosition(c, detail, second, null); detail = await hubDetail(c, "projects", created); expect(detail.rows.map(row => row.id)).toEqual([second.id, first.id]);
    await updateHubProjectField(c, detail, first, detail.fields.find(field => field.id === "local-priority")!, "local-high"); detail = await hubDetail(c, "projects", created); expect(detail.rows.find(row => row.id === first.id)?.values?.["local-priority"]).toBe("local-high");
    await updateHubProjectField(c, detail, first, detail.fields.find(field => field.id === "local-start")!, "2026-10-01"); detail = await hubDetail(c, "projects", created);
    await updateHubProjectField(c, detail, first, detail.fields.find(field => field.id === "local-due")!, "2026-10-04"); detail = await hubDetail(c, "projects", created);
    const beforeSchedule = storage.write.mock.calls.length;
    await rescheduleHubProjectItem(c, detail, first, { completedOptionIDs: [] }, "2026-10-10"); detail = await hubDetail(c, "projects", created);
    expect(detail.rows.find(row => row.id === first.id)?.values).toMatchObject({ "local-start": "2026-10-07", "local-due": "2026-10-10" }); expect(storage.write).toHaveBeenCalledTimes(beforeSchedule + 1);
    await archiveHubProjectItem(c, detail, second, true); detail = await hubDetail(c, "projects", created); expect(detail.rows.find(row => row.id === second.id)?.archived).toBe(true);
    await archiveHubProjectItem(c, detail, second, false); detail = await hubDetail(c, "projects", created);
    await deleteHubProjectItem(c, detail, second); detail = await hubDetail(c, "projects", created); expect(detail.rows.map(row => row.id)).toEqual([first.id]);
    expect(storage.write.mock.calls.length).toBeGreaterThan(0); expect(storage.http).not.toHaveBeenCalled();
  });
  it("rejects crossed workspace identities, remote-only actions and stale contexts before writing", async () => {
    const storage = memoryStorage(), c = access(), created = await localProjects.create("Local plan"); let detail = await hubDetail(c, "projects", created);
    await saveHubProjectDraft(c, detail, "Task", ""); detail = await hubDetail(c, "projects", created); const row = detail.rows[0], count = storage.write.mock.calls.length, remote = { ...c, local: false };
    await expect(saveHubProjectDraft(remote, detail, "Wrong", "")).rejects.toThrow("matching project workspace");
    await expect(saveHubProjectSettings(remote, detail, { title: "Wrong", shortDescription: "", readme: "", public: true, closed: false })).rejects.toThrow("matching project workspace");
    await expect(hubProjectViews(remote, detail)).rejects.toThrow("matching project workspace");
    await expect(convertHubProjectDraftToIssue(c, detail, row, "team/repo")).rejects.toThrow("GitHub project");
    await expect(inspectHubProjectCreationCapabilities(c)).rejects.toThrow("GitHub project");
    await expect(createHubProject(c, "Cloud")).rejects.toThrow("GitHub project");
    await expect(saveHubProjectDraft(c, { ...detail, item: { ...detail.item, id: "REMOTE" } }, "Wrong", "")).rejects.toThrow("matching project workspace");
    await expect(saveHubProjectDraft({ ...c, stillCurrent: () => false }, detail, "Stale", "")).rejects.toThrow("account changed");
    expect(storage.write).toHaveBeenCalledTimes(count); expect(storage.http).not.toHaveBeenCalled();
  });
});
