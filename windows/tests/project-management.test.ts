import { afterEach, describe, expect, it, vi } from "vitest";
import { inspectHubProjectCreationCapabilities, hubProjectPlanTier, HubProjectActionDeniedError, createHubProject, deleteHubProjectCustomField, deleteHubProjectView, hubProjectViews, HubUncertainWriteError, saveHubProjectCustomField, saveHubProjectSettings, saveHubProjectView, type HubAccess, type HubDetail, type HubProjectView } from "@/entities/hosting";
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

  it("maps only known billing names for the actual account kind", () => {
    expect(hubProjectPlanTier("free", "user")).toBe("free"); expect(hubProjectPlanTier("GitHub Pro", "user")).toBe("pro");
    expect(hubProjectPlanTier("team", "organization")).toBe("team"); expect(hubProjectPlanTier("enterprise_cloud", "organization")).toBe("enterprise");
    for (const value of [null, "", "Medium", "business", "enterprise"]) expect(hubProjectPlanTier(value, "user")).toBe("unknown");
    expect(hubProjectPlanTier("pro", "organization")).toBe("unknown"); expect(hubProjectPlanTier("team", "user")).toBe("unknown");
  });
  it("reports own Free and Pro plans without claiming token or owner-policy permission", async () => {
    const c = access(); c.target.path = "reader/workspace"; const http = vi.spyOn(ipc, "http");
    for (const [tier, max] of [["free", 1], ["pro", 5]] as const) {
      http.mockImplementation(async (_method, url) => response(url.endsWith("/user") ? { login: "reader", plan: { name: tier } } : { data: { repositoryOwner: { __typename: "User", id: "USER", login: "reader" } } }));
      expect(await inspectHubProjectCreationCapabilities(c)).toMatchObject({ viewerLogin: "reader", viewerVerified: true, ownerID: "USER", ownerKind: "user", accountPlan: { tier, source: "authenticatedUser" }, ownerPlan: { tier }, canCreate: null, canPublish: null, limits: { fields: 50, autoAddWorkflows: max } });
    }
    expect(http.mock.calls.some(call => call[1].includes("/users/"))).toBe(false);
    expect(http.mock.calls.filter(call => call[3]).every(call => !requestBody(call[3]).query.includes("viewerCanCreateProjects"))).toBe(true);
  });
  it("uses owner organization plan limits rather than the viewer's personal Pro plan", async () => {
    const http = vi.spyOn(ipc, "http");
    for (const [tier, max] of [["free", 1], ["team", 5], ["enterprise_cloud", 20], [null, null]] as const) {
      http.mockImplementation(async (_method, url) => response(url.endsWith("/user") ? { login: "reader", plan: { name: "pro" } } : url.endsWith("/orgs/team") ? { login: "team", ...(tier ? { plan: { name: tier } } : {}) } : { data: { repositoryOwner: { __typename: "Organization", id: "ORG", login: "team" } } }));
      const capabilities = await inspectHubProjectCreationCapabilities(access());
      expect(capabilities.accountPlan.tier).toBe("pro"); expect(capabilities.ownerPlan.tier).toBe(tier === "enterprise_cloud" ? "enterprise" : tier ?? "unknown"); expect(capabilities.limits.autoAddWorkflows).toBe(max);
    }
  });
  it("does not infer plan data missing from the API, legacy billing names, other users or enterprise hosts", async () => {
    const c = access(); c.target.path = "reader/workspace"; const http = vi.spyOn(ipc, "http");
    for (const [name, expected] of [[null, null], ["Medium", "Medium"]] as const) {
      http.mockImplementation(async (_method, url) => response(url.endsWith("/user") ? { login: "reader", ...(name ? { plan: { name } } : {}) } : { data: { repositoryOwner: { __typename: "User", id: "USER", login: "reader" } } }));
      const capabilities = await inspectHubProjectCreationCapabilities(c); expect(capabilities.viewerVerified).toBe(true); expect(capabilities.ownerPlan).toMatchObject({ tier: "unknown", rawName: expected }); expect(capabilities.limits.autoAddWorkflows).toBeNull();
    }
    c.target.path = "maintainer/repository"; http.mockClear().mockImplementation(async (_method, url) => response(url.endsWith("/user") ? { login: "reader", plan: { name: "pro" } } : { data: { repositoryOwner: { __typename: "User", id: "OTHER", login: "maintainer" } } }));
    const other = await inspectHubProjectCreationCapabilities(c); expect(other.accountPlan.tier).toBe("pro"); expect(other.ownerPlan.tier).toBe("unknown"); expect(http).toHaveBeenCalledTimes(2);
    c.target.host = "enterprise.test"; c.apiBase = "https://enterprise.test/api/v3"; http.mockClear().mockImplementation(async (_method, url) => url.endsWith("/orgs/maintainer") ? response({ message: "plan hidden" }, 403) : response(url.endsWith("/user") ? { login: "reader" } : { data: { repositoryOwner: { __typename: "Organization", id: "ORG", login: "maintainer" } } }));
    const enterprise = await inspectHubProjectCreationCapabilities(c); expect(enterprise.ownerPlan.tier).toBe("unknown"); expect(enterprise.accountPlan.tier).toBe("unknown"); expect(enterprise.ownerID).toBe("ORG"); expect(enterprise.limits.autoAddWorkflows).toBeNull(); expect(http).toHaveBeenCalledTimes(3);
  });
  it("rejects local or stale access and does not verify credentials for another username", async () => {
    const http = vi.spyOn(ipc, "http"), local = { ...access(), local: true };
    await expect(inspectHubProjectCreationCapabilities(local)).rejects.toThrow("GitHub project"); await expect(createHubProject(local, "Plan")).rejects.toThrow("GitHub project"); expect(http).not.toHaveBeenCalled();
    http.mockImplementation(async (_method, url) => response(url.endsWith("/user") ? { login: "another-user", plan: { name: "pro" } } : { data: { repositoryOwner: { __typename: "User", id: "USER", login: "reader" } } }));
    const mismatched = await inspectHubProjectCreationCapabilities(access()); expect(mismatched.viewerVerified).toBe(false); expect(mismatched.accountPlan.tier).toBe("unknown");
    let current = true; http.mockClear().mockImplementation(async () => { current = false; return response({ login: "reader", plan: { name: "pro" } }); });
    await expect(inspectHubProjectCreationCapabilities({ ...access(), stillCurrent: () => current })).rejects.toThrow("account changed"); expect(http).toHaveBeenCalledTimes(1);
  });
  it("defaults to private and publishes only through an explicit second mutation", async () => {
    const http = vi.spyOn(ipc, "http").mockImplementation(async (_method, _url, _headers, body) => {
      const query = requestBody(body).query;
      return response({ data: query.startsWith("query") ? { repository: { id: "REPO", owner: { id: "OWNER" } } } : query.includes("createProjectV2") ? { createProjectV2: { projectV2: metadata } } : { updateProjectV2: { projectV2: { ...metadata, public: true, updatedAt: "published" } } } });
    });
    expect((await createHubProject(access(), "Private")).data.public).toBe(false); expect(http).toHaveBeenCalledTimes(2); http.mockClear();
    expect((await createHubProject(access(), "Public", true)).data.public).toBe(true); expect(http).toHaveBeenCalledTimes(3); expect(requestBody(http.mock.calls[1][3]).variables.input).not.toHaveProperty("public"); expect(requestBody(http.mock.calls[2][3]).variables.input).toEqual({ projectId: "P", public: true });
  });
  it("carries the created private project through a denied publication without retrying creation", async () => {
    const http = vi.spyOn(ipc, "http").mockImplementation(async (_method, _url, _headers, body) => {
      const query = requestBody(body).query;
      return query.includes("updateProjectV2") ? response({ message: "Organization policy" }, 403) : response({ data: query.startsWith("query") ? { repository: { id: "REPO", owner: { id: "OWNER" } } } : { createProjectV2: { projectV2: metadata } } });
    });
    try { await createHubProject(access(), "Public", true); throw new Error("accepted"); } catch (error) { expect(error).toBeInstanceOf(HubUncertainWriteError); expect((error as HubUncertainWriteError).createdProject).toMatchObject({ id: "P", url: metadata.url, data: { public: false } }); expect(String(error)).toContain("private project was created"); }
    expect(http).toHaveBeenCalledTimes(3); expect(http.mock.calls.filter(call => requestBody(call[3]).query.includes("mutation($input:CreateProjectV2Input"))).toHaveLength(1);
  });
  it("distinguishes actual HTTP or GraphQL policy denial from billing and uncertain writes", async () => {
    const http = vi.spyOn(ipc, "http");
    for (const denied of [response({ message: "Organization policy" }, 403), response({ errors: [{ type: "FORBIDDEN", message: "restricted raw field" }] })]) {
      http.mockClear().mockResolvedValueOnce(response({ data: { repository: { id: "REPO", owner: { id: "OWNER" } } } })).mockResolvedValueOnce(denied);
      try { await createHubProject(access(), "Plan"); throw new Error("accepted"); } catch (error) { expect(error).toBeInstanceOf(HubProjectActionDeniedError); expect(error).not.toBeInstanceOf(HubUncertainWriteError); expect(String(error)).toContain("paid plan does not grant"); expect(String(error)).not.toContain("restricted raw field"); }
      expect(http).toHaveBeenCalledTimes(2);
    }
  });

});
