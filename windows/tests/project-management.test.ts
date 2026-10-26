import { afterEach, describe, expect, it, vi } from "vitest";
import { createHubProject, deleteHubProjectCustomField, deleteHubProjectView, hubProjectViews, HubUncertainWriteError, saveHubProjectCustomField, saveHubProjectSettings, saveHubProjectView, type HubAccess, type HubDetail, type HubProjectView } from "@/entities/hosting";
import { ipc } from "@/shared/api";

const access = (): HubAccess => ({ target: { provider: "github", host: "github.com", path: "team/client", remote: "origin" }, token: "fixture-token", apiBase: "https://api.github.com", me: "reader" });
const metadata = { id: "P", number: 1, title: "Delivery", shortDescription: "Team plan", readme: "Handbook", public: false, closed: false, updatedAt: "2026-01-01", url: "https://github.com/orgs/team/projects/1" };
const field = { id: "F", name: "Priority", kind: "singleSelect" as const, options: [{ id: "A", name: "High" }, { id: "B", name: "Low" }] };
const fieldNode = { ...field, options: [{ id: "A", name: "High", color: "RED", description: "Urgent" }, { id: "B", name: "Low", color: "GRAY", description: "Later" }] };
const detail = (): HubDetail => ({ item: { id: "P", title: "Delivery", subtitle: "#1", body: "Team plan", url: metadata.url, data: metadata }, fields: [field, { id: "N", name: "Points", kind: "number", options: [] }, { id: "TITLE", name: "Title", kind: "unsupported", options: [] }], rows: [], files: [], members: [], repositories: [], assets: [], more: false });
const connection = (values: unknown[], more = false) => ({ nodes: values, pageInfo: { hasNextPage: more } });
const viewNode = { id: "V", name: "Ready", number: 2, updatedAt: "2026-01-01", layout: "BOARD_LAYOUT", filter: "status:Todo", project: { id: "P" }, configuration: { visibleFields: connection([{ id: "F" }, { id: "TITLE" }]) }, groupByFields: connection([{ id: "F" }]), sortByFields: connection([{ direction: "DESC", field: { id: "N" } }]) };
const view = (): HubProjectView => ({ id: "V", name: "Ready", number: 2, updatedAt: "2026-01-01", layout: "BOARD_LAYOUT", filter: "status:Todo", visibleFieldIDs: ["F", "TITLE"], groupFieldIDs: ["F"], sortFields: [{ fieldID: "N", direction: "DESC" }] });
const response = (value: unknown, status = 200) => ({ status, body: JSON.stringify(value) });
const requestBody = (body: string | undefined) => JSON.parse(body ?? "{}") as { query: string; variables: { input?: Record<string, unknown>; [key: string]: unknown } };
afterEach(() => vi.restoreAllMocks());

describe("ProjectV2 native management contract", () => {
  it("resolves the captured owner and links a newly created repository project", async () => {
    const http = vi.spyOn(ipc, "http").mockImplementation(async (_method, url, _headers, body) => {
      expect(url).toBe("https://api.github.com/graphql");
      const { query } = requestBody(body);
      return response({ data: query.startsWith("query") ? { repository: { id: "REPO", owner: { id: "OWNER" } } } : { createProjectV2: { projectV2: metadata } } });
    });
    expect((await createHubProject(access(), "  Delivery  ")).id).toBe("P");
    expect(requestBody(http.mock.calls[1][3]).variables.input).toEqual({ ownerId: "OWNER", repositoryId: "REPO", title: "Delivery" });
  });
  it("resolves a personal owner without inventing repository IDs", async () => {
    const c = access(); c.target.path = "reader/workspace";
    const http = vi.spyOn(ipc, "http").mockImplementation(async (_m, _u, _h, body) => response({ data: requestBody(body).query.startsWith("query") ? { repositoryOwner: { id: "USER" } } : { createProjectV2: { projectV2: metadata } } }));
    await createHubProject(c, "Plan");
    expect(requestBody(http.mock.calls[0][3]).query).toContain("repositoryOwner(login:$owner)");
    expect(requestBody(http.mock.calls[1][3]).variables.input).toEqual({ ownerId: "USER", title: "Plan" });
  });
  it("sends exactly the documented project settings and rejects collaborator changes", async () => {
    const http = vi.spyOn(ipc, "http").mockResolvedValue(response({ data: { node: metadata } }));
    const input = { title: "  Release  ", shortDescription: "Summary", readme: "Guide", public: true, closed: true };
    await saveHubProjectSettings(access(), detail(), input);
    expect(requestBody(http.mock.calls[1][3]).variables.input).toEqual({ projectId: "P", ...input, title: "Release" });
    http.mockClear().mockResolvedValue(response({ data: { node: { ...metadata, readme: "Collaborator" } } }));
    await expect(saveHubProjectSettings(access(), detail(), input)).rejects.toThrow("changed on the server");
    expect(http).toHaveBeenCalledTimes(1);
  });
  it("creates each supported custom field with the official custom data type", async () => {
    const http = vi.spyOn(ipc, "http").mockResolvedValue(response({ data: {} }));
    for (const kind of ["text", "number", "date", "singleSelect"] as const) await saveHubProjectCustomField(access(), detail(), { name: "Custom", kind, ...(kind === "singleSelect" ? { options: [{ name: "Ready", color: "GREEN" }] } : {}) });
    expect(http.mock.calls.map(call => requestBody(call[3]).variables.input?.dataType)).toEqual(["TEXT", "NUMBER", "DATE", "SINGLE_SELECT"]);
    expect(requestBody(http.mock.calls[3][3]).variables.input?.singleSelectOptions).toEqual([{ name: "Ready", color: "GREEN", description: "" }]);
    expect(requestBody(http.mock.calls[0][3]).query).toContain("CreateProjectV2FieldInput!");
  });
  it("retains option IDs, descriptions and colors during a rename", async () => {
    const http = vi.spyOn(ipc, "http").mockResolvedValue(response({ data: { node: { id: "P", fields: connection([fieldNode]) } } }));
    await saveHubProjectCustomField(access(), detail(), { name: "Urgency", kind: "singleSelect", options: [{ id: "A", name: "Critical" }, { id: "B", name: "Low" }] }, field);
    expect(requestBody(http.mock.calls[1][3]).variables.input).toEqual({ fieldId: "F", name: "Urgency", singleSelectOptions: [{ id: "A", name: "Critical", color: "RED", description: "Urgent" }, { id: "B", name: "Low", color: "GRAY", description: "Later" }] });
  });
  it("checks current custom fields before deleting and rejects built-ins or forged fields", async () => {
    const http = vi.spyOn(ipc, "http").mockResolvedValue(response({ data: { node: { id: "P", fields: connection([fieldNode]) } } }));
    await deleteHubProjectCustomField(access(), detail(), field);
    expect(requestBody(http.mock.calls[1][3]).variables.input).toEqual({ fieldId: "F" });
    expect(requestBody(http.mock.calls[1][3]).query).toContain("DeleteProjectV2FieldInput!");
    http.mockClear();
    await expect(deleteHubProjectCustomField(access(), detail(), { ...field, id: "TITLE" })).rejects.toThrow("loaded custom");
    await expect(deleteHubProjectCustomField(access(), detail(), { ...field, id: "forged" })).rejects.toThrow("loaded custom");
    await expect(saveHubProjectCustomField(access(), detail(), { name: "X", kind: "number" }, field)).rejects.toThrow("valid project");
    expect(http).not.toHaveBeenCalled();
  });
  it("rejects empty or duplicate options and unknown option IDs", async () => {
    const http = vi.spyOn(ipc, "http").mockResolvedValue(response({ data: { node: { id: "P", fields: connection([fieldNode]) } } }));
    await expect(saveHubProjectCustomField(access(), detail(), { name: "", kind: "text" })).rejects.toThrow("valid project");
    await expect(saveHubProjectCustomField(access(), detail(), { name: "X", kind: "singleSelect", options: [] })).rejects.toThrow("valid project");
    await expect(saveHubProjectCustomField(access(), detail(), { name: "X", kind: "singleSelect", options: [{ name: "One" }, { name: " One " }] })).rejects.toThrow("valid project");
    expect(http).not.toHaveBeenCalled();
    await expect(saveHubProjectCustomField(access(), detail(), { name: "X", kind: "singleSelect", options: [{ id: "forged", name: "Other" }] }, field)).rejects.toThrow("valid project");
    expect(http).toHaveBeenCalledTimes(1);
  });
  it("pages shared views and reads ordered fields plus real grouping and sorting", async () => {
    const http = vi.spyOn(ipc, "http").mockResolvedValue(response({ data: { node: { id: "P", views: { ...connection([viewNode], true), pageInfo: { hasNextPage: true, endCursor: "next" } } } } }));
    expect(await hubProjectViews(access(), detail(), "before")).toEqual({ views: [view()], more: true, cursor: "next" });
    const request = requestBody(http.mock.calls[0][3]);
    expect(request.variables).toEqual({ id: "P", cursor: "before" });
    expect(request.query).toContain("configuration{visibleFields(first:100)");
    expect(request.query).toContain("groupByFields");
    expect(request.query).toContain("sortByFields");
    expect(request.query).not.toContain("items(");
  });
  it("updates only the schema's writable view properties after checking project membership", async () => {
    const http = vi.spyOn(ipc, "http").mockResolvedValue(response({ data: { node: viewNode } }));
    await saveHubProjectView(access(), detail(), { name: "Review", layout: "TABLE_LAYOUT", filter: "assignee:@me", visibleFieldIDs: ["TITLE", "F"] }, view());
    expect(requestBody(http.mock.calls[1][3]).variables.input).toEqual({ viewId: "V", name: "Review", layout: "TABLE_LAYOUT", filter: "assignee:@me", configuration: { visibleFieldIds: ["TITLE", "F"] } });
    http.mockClear().mockResolvedValue(response({ data: { node: { ...viewNode, project: { id: "OTHER" } } } }));
    await expect(deleteHubProjectView(access(), detail(), view())).rejects.toThrow("changed on the server");
    expect(http).toHaveBeenCalledTimes(1);
  });
  it("creates a shared view then applies a filter using the separate documented input", async () => {
    const http = vi.spyOn(ipc, "http").mockResolvedValue(response({ data: { createProjectV2View: { projectV2View: { id: "NEW" } } } }));
    await saveHubProjectView(access(), detail(), { name: "Mine", layout: "BOARD_LAYOUT", filter: "assignee:@me", visibleFieldIDs: ["TITLE"] });
    expect(requestBody(http.mock.calls[0][3]).variables.input).toEqual({ projectId: "P", name: "Mine", layout: "BOARD_LAYOUT", configuration: { visibleFieldIds: ["TITLE"] } });
    expect(requestBody(http.mock.calls[1][3]).variables.input).toEqual({ viewId: "NEW", filter: "assignee:@me" });
    http.mockClear().mockResolvedValueOnce(response({ data: { createProjectV2View: { projectV2View: { id: "NEW" } } } })).mockResolvedValue(response({ message: "forbidden" }, 403));
    await expect(saveHubProjectView(access(), detail(), { name: "Mine", layout: "BOARD_LAYOUT", filter: "assignee:@me", visibleFieldIDs: [] })).rejects.toBeInstanceOf(HubUncertainWriteError);
    expect(http).toHaveBeenCalledTimes(2);
  });
  it("deletes only a current shared view and refuses incomplete or malformed configurations", async () => {
    const http = vi.spyOn(ipc, "http").mockResolvedValue(response({ data: { node: viewNode } }));
    await deleteHubProjectView(access(), detail(), view());
    expect(requestBody(http.mock.calls[1][3]).query).toContain("DeleteProjectV2ViewInput!");
    expect(requestBody(http.mock.calls[1][3]).variables.input).toEqual({ viewId: "V" });
    http.mockClear();
    await expect(saveHubProjectView(access(), detail(), { name: "X", layout: "BOARD_LAYOUT", filter: "", visibleFieldIDs: ["forged"] })).rejects.toThrow("valid project");
    expect(http).not.toHaveBeenCalled();
    http.mockResolvedValue(response({ data: { node: { id: "P", views: connection([{ ...viewNode, groupByFields: connection([], true) }]) } } }));
    await expect(hubProjectViews(access(), detail())).rejects.toThrow("unexpected response");
  });
  it("stops mutations when the captured account changes during prerequisite reads", async () => {
    let current = true;
    const c = { ...access(), stillCurrent: () => current };
    const http = vi.spyOn(ipc, "http").mockImplementation(async () => { current = false; return response({ data: { repository: { id: "R", owner: { id: "O" } } } }); });
    await expect(createHubProject(c, "Plan")).rejects.toThrow("account changed");
    expect(http).toHaveBeenCalledTimes(1);
    http.mockClear();
    await expect(hubProjectViews(c, detail())).rejects.toThrow("account changed");
    expect(http).not.toHaveBeenCalled();
  });
  it("preserves unsupported field identities and their visible order when renaming a shared view", async () => {
    const project = detail(); project.fields.push({ id: "M", name: "Teams", kind: "unsupported", options: [] });
    const remote = { ...viewNode, configuration: { visibleFields: connection([{ __typename: "ProjectV2MultiSelectField", id: "M" }, { id: "TITLE" }, { id: "F" }]) } };
    const http = vi.spyOn(ipc, "http").mockImplementation(async (_method, _url, _headers, body) => response({ data: requestBody(body).query.includes("views(first:") ? { node: { id: "P", views: connection([remote]) } } : { node: remote } }));
    const page = await hubProjectViews(access(), project);
    expect(page.views[0].visibleFieldIDs).toEqual(["M", "TITLE", "F"]);
    expect(requestBody(http.mock.calls[0][3]).query).toContain("... on ProjectV2FieldCommon{id}");
    await saveHubProjectView(access(), project, { name: "Renamed", layout: page.views[0].layout, filter: page.views[0].filter, visibleFieldIDs: page.views[0].visibleFieldIDs }, page.views[0]);
    expect(requestBody(http.mock.calls.at(-1)![3]).variables.input?.configuration).toEqual({ visibleFieldIds: ["M", "TITLE", "F"] });
  });
  it("rejects incomplete visible, grouping or sort field identities instead of losing them on save", async () => {
    const http = vi.spyOn(ipc, "http");
    for (const malformed of [{ ...viewNode, configuration: { visibleFields: connection([{}]) } }, { ...viewNode, groupByFields: connection([{}]) }, { ...viewNode, sortByFields: connection([{ direction: "ASC", field: {} }]) }]) {
      http.mockResolvedValue(response({ data: { node: { id: "P", views: connection([malformed]) } } }));
      await expect(hubProjectViews(access(), detail())).rejects.toThrow("unexpected response");
    }
    expect(http).toHaveBeenCalledTimes(3);
  });

});
