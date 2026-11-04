import { afterEach, describe, expect, it, vi } from "vitest";
import { accounts, addHubProjectIssue, HostingHubStore, hubDetail, hubPage, hubProjectOrganization, hubProjectTarget, moveHubProjectItem, ProjectOrganizationState, type HubAccess, type HubDetail, type HubItem } from "@/entities/hosting";
import type { HostAccount } from "@/entities/git";
import { ipc } from "@/shared/api";

const response = (value: unknown, status = 200) => ({ status, body: JSON.stringify(value) });
const lab = (): HostAccount => ({ id: "lab", provider: "gitlab", server: "https://gitlab.test", username: "reader", name: null, avatarURL: null });
const group = (projectOrganization = "team/design"): HubAccess => ({ target: hubProjectTarget(null, "gitlab", "gitlab.test", "reader", false, projectOrganization), token: "fixture-token", apiBase: "https://gitlab.test/api/v4", me: "reader", projectOrganization });
const repository = (path = "team/repo"): HubAccess => ({ target: { provider: "gitlab", host: "gitlab.test", path, remote: "origin" }, token: "fixture-token", apiBase: "https://gitlab.test/api/v4", me: "reader" });
const board: HubItem = { id: "4", title: "Delivery", subtitle: "", body: "", url: "", data: {} };
const page = (url: string) => Number(new URL(url).searchParams.get("page"));
const savedAccounts = accounts.accounts;
afterEach(() => { vi.restoreAllMocks(); accounts.accounts = savedAccounts; });

describe("GitLab group boards", () => {
  it("accepts group paths only for GitLab and keeps GitHub logins strict", () => {
    expect(hubProjectOrganization("organization:team/design", "gitlab")).toBe("team/design");
    expect(hubProjectOrganization("organization:team_x/design.web", "gitlab")).toBe("team_x/design.web");
    expect(hubProjectOrganization("organization:team/design")).toBeUndefined();
    for (const value of ["", "../team", "team//design", "team/..", "-team", "team/design?x", "a".repeat(256)]) expect(hubProjectOrganization(`organization:${value}`, "gitlab")).toBeUndefined();
  });

  it("lists every board of a group without an open repository", async () => {
    const http = vi.spyOn(ipc, "http").mockImplementation(async (_method, url) => response(Array.from({ length: page(url) === 1 ? 100 : 5 }, (_, i) => ({ id: (page(url) - 1) * 100 + i, name: `Board ${i}` }))));
    const result = await hubPage(group(), "projects");
    expect(result.items).toHaveLength(105); expect(result.more).toBe(false);
    expect(http.mock.calls.map(call => call[1])).toEqual(["https://gitlab.test/api/v4/groups/team%2Fdesign/boards?per_page=100&page=1", "https://gitlab.test/api/v4/groups/team%2Fdesign/boards?per_page=100&page=2"]);
    expect(result.items[0].url).toBe("https://gitlab.test/groups/team/design/-/boards/0");
    await expect(hubPage(repository("reader/workspace"), "projects")).rejects.toThrow("Choose a group");
  });

  it("loads every issue of a group board once and moves each through its own project", async () => {
    const issue = (id: number, project: string, iid: number, labels: string[] = []) => ({ id, iid, title: `Task ${id}`, state: "opened", web_url: `https://gitlab.test/${project}/-/issues/${iid}`, references: { full: `${project}#${iid}` }, labels });
    const writes: { url: string; body: unknown }[] = [];
    const http = vi.spyOn(ipc, "http").mockImplementation(async (method, url, _headers, body) => {
      if (method === "PUT") { writes.push({ url, body: JSON.parse(body!) }); return response({}); }
      if (url.includes("/lists?")) return response([{ label: { id: 11, name: "Doing" } }]);
      if (url.includes("/issues?")) return response(page(url) === 1 ? Array.from({ length: 100 }, (_, i) => issue(i + 1, i % 2 ? "team/design/app" : "team/design/web", Math.floor(i / 2) + 1)) : [issue(100, "team/design/app", 50), issue(101, "team/design/app", 51, ["Doing"])]);
      if (url.includes("/issues/")) return response({ labels: [] });
      return response({ id: 4, name: "Delivery", labels: [] });
    });
    const d = await hubDetail(group(), "projects", board);
    expect(d.rows).toHaveLength(101); expect(d.more).toBe(false);
    expect(new Set(d.rows.map(row => row.id)).size).toBe(101);
    expect(d.rows[0]).toMatchObject({ id: "1", number: 1, repository: "team/design/web" });
    expect(d.rows.at(-1)).toMatchObject({ id: "101", repository: "team/design/app", statuses: { board: "11" } });
    expect(http.mock.calls.filter(call => call[1].includes("/issues?")).map(call => page(call[1]))).toEqual([1, 2]);
    expect(http.mock.calls.every(call => call[1].startsWith("https://gitlab.test/api/v4/groups/team%2Fdesign/"))).toBe(true);
    await moveHubProjectItem(group(), d, d.rows[1], d.fields[0], "11");
    expect(writes).toEqual([{ url: "https://gitlab.test/api/v4/projects/team%2Fdesign%2Fapp/issues/1", body: { remove_labels: "", add_labels: "Doing", state_event: "reopen" } }]);
  });

  it("adds only issues from projects inside the chosen group", async () => {
    const http = vi.spyOn(ipc, "http").mockImplementation(async method => response(method === "PUT" ? {} : { id: 70, iid: 7, title: "Task", labels: [] }));
    const d: HubDetail = { item: board, members: [], repositories: [], assets: [], fields: [{ id: "board", name: "Board column", options: [{ id: "__open", name: "Open" }, { id: "__closed", name: "Closed" }] }], rows: [], more: false };
    for (const url of ["https://gitlab.test/other/app/-/issues/7", "https://gitlab.test/team/designer/app/-/issues/7"]) await expect(addHubProjectIssue(group(), d, url)).rejects.toThrow("repository in this group");
    expect(http).not.toHaveBeenCalled();
    await addHubProjectIssue(group(), d, "https://gitlab.test/team/design/sub/app/-/issues/7");
    const issue = "https://gitlab.test/api/v4/projects/team%2Fdesign%2Fsub%2Fapp/issues/7";
    expect(http.mock.calls.map(call => call[1])).toEqual([issue, issue, issue]);
    expect(http.mock.calls.at(-1)?.[0]).toBe("PUT");
  });

  it("loads every page of an open repository's boards and issues", async () => {
    const http = vi.spyOn(ipc, "http").mockImplementation(async (_method, url) => {
      if (url.includes("/boards?")) return response(Array.from({ length: page(url) === 1 ? 100 : 1 }, (_, i) => ({ id: (page(url) - 1) * 100 + i, name: "Board" })));
      if (url.includes("/lists?")) return response([]);
      if (url.includes("/issues?")) return response(Array.from({ length: page(url) === 1 ? 100 : 3 }, (_, i) => ({ id: page(url) * 1000 + i, iid: (page(url) - 1) * 100 + i + 1, title: "Task", state: "opened" })));
      return response({ id: 4, name: "Board" });
    });
    expect((await hubPage(repository(), "projects")).items).toHaveLength(101);
    const d = await hubDetail(repository(), "projects", board);
    expect(d.rows).toHaveLength(103); expect(d.more).toBe(false); expect(d.rows.at(-1)).toMatchObject({ id: "103", repository: "team/repo" });
    expect(http.mock.calls.some(call => call[1].startsWith("https://gitlab.test/api/v4/projects/team%2Frepo/issues?") && call[1].includes("per_page=100"))).toBe(true);
  });

  it("offers groups by full path and scopes GitLab projects to the chosen group", async () => {
    const a = lab(); accounts.accounts = [a]; vi.spyOn(accounts, "token").mockResolvedValue("fixture-token");
    vi.spyOn(ipc, "http").mockImplementation(async (_method, url) => response(url.includes("/groups?") ? [{ id: 5, name: "Design", full_path: "team/design" }] : []));
    const catalog = new ProjectOrganizationState(); await catalog.activate(a, 1);
    expect(catalog.items.map(item => [item.id, item.title])).toEqual([["team/design", "team/design"]]);
    const hub = new HostingHubStore({ path: null, target: null, hostingAccount: a }); hub.section = "projects";
    expect(hub.projectEffectiveScope).toBe("personal");
    hub.projectScope = "organization:team/design";
    expect(hub.projectEffectiveScope).toBe("organization:team/design"); expect(hub.projectOwner).toBe("team/design");
    expect(await hub.access()).toMatchObject({ projectOrganization: "team/design", target: { provider: "gitlab", path: "team/design/workspace" } });
    const open = new HostingHubStore({ path: "/work/app", target: { provider: "gitlab", host: "gitlab.test", path: "team/design/app", remote: "origin" }, hostingAccount: a }); open.section = "projects"; open.projectScope = "personal";
    expect(open.projectEffectiveScope).toBe("repository"); expect(open.projectRepositoryLabel).toBe("team/design/app");
  });
});
