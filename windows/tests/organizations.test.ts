import { afterEach, describe, expect, it, vi } from "vitest";
import { accounts, HostingHubStore, hubPage, hubDetail, loadHubOrganizationSection, loadHubOrganizationTeamMembers, applyHubOrganizationSection, hubOrganizationDetail, hubOrganizationInviteError, inviteHubOrganizationMember, cancelHubOrganizationInvitation, hubOrganizationLinks, HubUncertainWriteError, type HubAccess, type HubItem, type HubOrganizationInviteInput } from "@/entities/hosting";
import { ipc } from "@/shared/api";
const access = (provider: "github" | "gitlab" = "github"): HubAccess => ({ target: { provider, host: provider === "github" ? "github.com" : "gitlab.example.com", remote: "origin", path: "team/repo" }, apiBase: provider === "github" ? "https://api.github.com" : "https://gitlab.example.com/api/v4", token: "fixture-token", me: "demo" });
const item = (provider: "github" | "gitlab" = "github"): HubItem => ({ id: provider === "github" ? "team" : "5", title: "Demo team", subtitle: "team", url: provider === "github" ? "https://github.com/team" : "https://gitlab.example.com/team", body: "", data: {} });
const input = (values: Partial<HubOrganizationInviteInput> = {}): HubOrganizationInviteInput => ({ email: "member@example.com", role: "direct_member", expiresAt: "", ...values });
const response = (value: unknown, status = 200) => ({ status, body: status === 204 ? "" : JSON.stringify(value) });
function fixture(role = "admin", provider: "github" | "gitlab" = "github") {
  return vi.spyOn(ipc, "http").mockImplementation(async (method, url, _headers, body) => {
    if (url.endsWith("/graphql")) { const variables = JSON.parse(body!).variables as Record<string, string>; return response({ data: Object.fromEntries(Object.entries(variables).map(([key, login]) => [key.replace("login", "member"), { name: `Display ${login}` }])) }); }
    if (method !== "GET") return response(provider === "github" ? { id: 10 } : { status: "success" }, method === "DELETE" ? 204 : 201);
    const request = new URL(url), limit = Number(request.searchParams.get("per_page") ?? 6), page = Number(request.searchParams.get("page") ?? 1);
    if (url.includes("/user/memberships/")) return response({ role, state: "active", user: { login: "demo" } });
    if (url.endsWith("/user")) return response({ id: 9, username: "demo" });
    if (url.endsWith("/members/all/9")) return response({ id: 9, username: "demo", access_level: Number(role) });
    if (url.includes("/invitations?")) return response([{ id: 10, ...(provider === "github" ? { email: "member@example.com" } : { invite_email: "member@example.com" }), role: "direct_member", access_level: 30 }]);
    if (url.includes("/teams?") || url.includes("/subgroups?")) return response(Array.from({ length: limit }, (_, offset) => { const id = 100 + (page - 1) * limit + offset; return { id, slug: `server-team-${id}`, name: `Team ${id}`, html_url: "https://github.com/orgs/team/teams/demo", web_url: "https://gitlab.example.com/team/subgroup" }; }));
    if (url.includes("/members?" ) || url.includes("/members/all?")) return response(Array.from({ length: limit }, (_, offset) => { const id = (page - 1) * limit + offset; return { id, login: `person-${id}`, username: `person-${id}`, name: `Display person-${id}`, access_level: 30, avatar_url: "https://avatars.githubusercontent.com/u/1", html_url: `https://github.com/person-${id}` }; }));
    if (url.includes("/repos?") || url.includes("/projects?")) return response(Array.from({ length: limit }, (_, offset) => ({ id: (page - 1) * limit + offset, full_name: `team/repo-${offset}`, path_with_namespace: `team/repo-${offset}`, html_url: "https://github.com/team/repo" })));
    return response({ name: "Demo team", html_url: "https://github.com/team", web_url: "https://gitlab.example.com/team", public_repos: 12, total_private_repos: 3 });
  });
}
afterEach(() => vi.restoreAllMocks());
describe("organization management", () => {
  it("uses membership pagination when fine-grained tokens return no organizations", async () => {
    const http = vi.spyOn(ipc, "http").mockImplementation(async (_method, url) => response(url.includes("/user/orgs?") ? [] : Array.from({ length: 30 }, (_, id) => ({ state: "active", organization: { login: `team-${id}` } }))));
    const first = await hubPage(access(), "organizations"); expect(first.cursor).toBe("organizationMemberships"); expect(first.more).toBe(true);
    await hubPage(access(), "organizations", 2, first.cursor); expect(http.mock.calls.at(-1)?.[1]).toContain("/user/memberships/orgs?state=active&per_page=30&page=2"); expect(http.mock.calls.filter(call => call[1].includes("/user/orgs?"))).toHaveLength(1);
  });

  it("loads fresh owner capabilities when entering focused Members or Repositories directly", async () => {
    fixture();
    for (const tab of ["members", "repositories"] as const) {
      const detail = await hubDetail(access(), "organizations", item(), 1, undefined, tab);
      expect(detail.organization?.info).toMatchObject({ role: "Owner", canInvite: true }); expect(detail.organization?.sections[tab].loaded).toBe(true); expect(detail.organization?.sections.invitations.loaded).toBe(false); expect(detail.organization?.invitations).toEqual([]);
    }
  });
  it("loads overview counts and confirms active GitHub ownership", async () => {
    const http = fixture(); const detail = await hubOrganizationDetail(access(), item(), 1, "overview");
    expect(detail.organization?.info).toMatchObject({ role: "Owner", canInvite: true, publicRepositories: 12, privateRepositories: 3 }); expect(detail.members).toHaveLength(12); expect(detail.repositories).toHaveLength(6); expect(detail.organization?.teams).toHaveLength(6); expect(detail.organization?.teams.every(team => team.members.length === 6)).toBe(true); expect(detail.members[0].name).toBe("Display person-0"); expect(http.mock.calls.filter(call => /\/teams\/[^/]+\/members\?/.test(call[1]))).toHaveLength(6);
  });
  it("does not infer GitLab ownership from undocumented group permissions", async () => {
    const http = fixture("50", "gitlab"); const detail = await hubOrganizationDetail(access("gitlab"), item("gitlab"), 1, "overview");
    expect(detail.organization?.info.canInvite).toBe(true); expect(http.mock.calls.map(call => call[1])).toContain("https://gitlab.example.com/api/v4/groups/5/members/all/9");
  });
  it("keeps overview readable and denies writes when membership permission is absent", async () => {
    const http = fixture(); http.mockImplementation(async (_method, url) => url.includes("/user/memberships/") ? response({ message: "Forbidden" }, 403) : response({ name: "Demo team", public_repos: 12 }));
    const detail = await hubOrganizationDetail(access(), item(), 1, "invitations"); expect(detail.organization?.info.canInvite).toBe(false); expect(detail.item.title).toBe("Demo team"); expect(detail.notice).toContain("ownership"); expect(detail.more).toBe(false);
    await expect(inviteHubOrganizationMember(access(), item(), input())).rejects.toThrow("ownership"); expect(http.mock.calls.every(call => call[0] === "GET")).toBe(true);
  });
  it("does not grant invitations to pending owners or GitLab maintainers", async () => {
    const http = fixture(); http.mockImplementation(async (_method, url) => response(url.includes("/user/memberships/") ? { role: "admin", state: "pending" } : { name: "Demo team" }));
    expect((await hubOrganizationDetail(access(), item(), 1, "overview")).organization?.info.canInvite).toBe(false);
    http.mockRestore(); fixture("40", "gitlab"); expect((await hubOrganizationDetail(access("gitlab"), item("gitlab"), 1, "overview")).organization?.info.canInvite).toBe(false);
  });
  it("paginates teams and requests all visible direct GitLab subgroups", async () => {
    const http = fixture("50", "gitlab"); const detail = await hubOrganizationDetail(access("gitlab"), item("gitlab"), 2, "teams");
    expect(detail.more).toBe(true); expect(detail.organization?.teams).toHaveLength(6); expect(http.mock.calls.some(call => call[1].includes("/subgroups?per_page=6&page=2&all_available=true"))).toBe(true); expect(detail.organization?.teams[0].members).toHaveLength(6);
  });
  it("preserves profile on a forbidden team section", async () => {
    const http = fixture(); http.mockImplementation(async (_method, url) => url.includes("/teams?") ? response({ message: "Forbidden" }, 403) : response(url.includes("/user/memberships/") ? { role: "member", state: "active" } : { name: "Demo team" }));
    const detail = await hubOrganizationDetail(access(), item(), 1, "teams"); expect(detail.item.title).toBe("Demo team"); expect(detail.notice).toContain("403"); expect(detail.organization?.teams).toEqual([]);
  });
  it("rejects batch recipients, invalid roles and malformed expiration dates before requests", async () => {
    const http = vi.spyOn(ipc, "http");
    for (const value of [input({ email: "one,two@example.com" }), input({ email: "one;two@example.com" }), input({ email: "bad" }), input({ role: "administrator" }), input({ expiresAt: "2099-02-30" })]) await expect(inviteHubOrganizationMember(access(), item(), value)).rejects.toThrow();
    expect(hubOrganizationInviteError("gitlab", input({ role: "30", expiresAt: "2099-02-30" }))).toContain("expiration"); expect(http).not.toHaveBeenCalled();
  });
  it("sends the reviewed GitHub email and role after a fresh owner check", async () => {
    const http = fixture(); await inviteHubOrganizationMember(access(), item(), input({ email: " member@example.com ", role: "admin" }));
    expect(http.mock.calls.at(-1)?.slice(0, 2)).toEqual(["POST", "https://api.github.com/orgs/team/invitations"]); expect(JSON.parse(http.mock.calls.at(-1)![3]!)).toEqual({ email: "member@example.com", role: "admin" });
  });
  it("sends GitLab role and expiration, and exposes queued approval", async () => {
    const http = fixture("50", "gitlab"); const original = http.getMockImplementation()!;
    http.mockImplementation(async (...args) => args[0] === "POST" ? response({ status: "success", queued_users: { "member@example.com": "Awaiting approval" } }) : original(...args));
    const result = await inviteHubOrganizationMember(access("gitlab"), item("gitlab"), input({ role: "30", expiresAt: "2099-01-01" }));
    expect(result).toContain("approval"); expect(JSON.parse(http.mock.calls.at(-1)![3]!)).toEqual({ email: "member@example.com", access_level: 30, expires_at: "2099-01-01" });
  });
  it("treats GitLab HTTP success with status error as rejected", async () => {
    const http = fixture("50", "gitlab"); const original = http.getMockImplementation()!; http.mockImplementation(async (...args) => args[0] === "POST" ? response({ status: "error", message: { "member@example.com": "Already invited" } }) : original(...args));
    await expect(inviteHubOrganizationMember(access("gitlab"), item("gitlab"), input({ role: "30" }))).rejects.toThrow("Already invited");
  });
  it("never retries an invitation with an unknown transport outcome", async () => {
    const http = fixture(); const original = http.getMockImplementation()!; http.mockImplementation(async (...args) => { if (args[0] === "POST") throw new Error("Connection lost"); return original(...args); });
    await expect(inviteHubOrganizationMember(access(), item(), input())).rejects.toBeInstanceOf(HubUncertainWriteError); expect(http.mock.calls.filter(call => call[0] === "POST")).toHaveLength(1);
  });
  it("accepts an empty successful cancellation and encodes GitLab email identifiers", async () => {
    const http = fixture("50", "gitlab"); const detail = await hubOrganizationDetail(access("gitlab"), item("gitlab"), 1, "invitations");
    await cancelHubOrganizationInvitation(access("gitlab"), detail, detail.organization!.invitations[0]); expect(http.mock.calls.at(-1)?.slice(0, 2)).toEqual(["DELETE", "https://gitlab.example.com/api/v4/groups/5/invitations/member%40example.com"]);
  });
  it("requires loaded invitations and current context for cancellation", async () => {
    const http = fixture(); const detail = await hubOrganizationDetail(access(), item(), 1, "invitations"); const before = http.mock.calls.length;
    await expect(cancelHubOrganizationInvitation(access(), detail, { ...detail.organization!.invitations[0], id: "forged" })).rejects.toThrow("loaded"); await expect(cancelHubOrganizationInvitation({ ...access(), stillCurrent: () => false }, detail, detail.organization!.invitations[0])).rejects.toThrow("changed"); expect(http).toHaveBeenCalledTimes(before);
  });
  it("rechecks account context between the owner read and write", async () => {
    const http = fixture(); const original = http.getMockImplementation()!; let current = true;
    http.mockImplementation(async (...args) => { const value = await original(...args); if (args[1].includes("/user/memberships/")) current = false; return value; });
    await expect(inviteHubOrganizationMember({ ...access(), stillCurrent: () => current }, item(), input())).rejects.toThrow("changed"); expect(http.mock.calls.every(call => call[0] === "GET")).toBe(true);
  });
  it("invalidates review stamps when a detail reload changes the selection version", async () => {
    const saved = accounts.accounts, account = { id: "demo", provider: "github" as const, server: "https://github.com", username: "demo", name: null, avatarURL: null };
    accounts.accounts = [account]; vi.spyOn(accounts, "token").mockResolvedValue("fixture-token"); fixture();
    try { const hub = new HostingHubStore({ path: null, target: null, hostingAccount: account }); hub.section = "organizations"; await hub.select(item(), false, "overview"); const stamp = hub.actionStamp; await hub.select(item(), false, "teams"); expect(hub.actionStamp).not.toBe(stamp); const write = vi.fn(); expect(await hub.action(write, "detail", stamp)).toBe(false); expect(write).not.toHaveBeenCalled(); } finally { accounts.accounts = saved; }
  });

  it("isolates inaccessible dashboard sections and per-team people while keeping successful lists", async () => {
    const http = fixture(); const original = http.getMockImplementation()!;
    http.mockImplementation(async (...args) => args[1].includes("/repos?") || args[1].includes("/teams/server-team-100/members?") ? response({ message: "Denied" }, 403) : original(...args));
    const detail = await hubOrganizationDetail(access(), item(), 1, "overview");
    expect(detail.members).toHaveLength(12); expect(detail.organization!.sections.repositories.error).toContain("403"); expect(detail.organization!.sections.members.error).toBeUndefined(); expect(detail.organization!.teams[0].memberState.error).toContain("403"); expect(detail.organization!.teams[1].members).toHaveLength(6); expect(detail.organization!.invitations).toHaveLength(1);
  });
  it("promotes preview pages without skipping people and appends new team pages with their own people", async () => {
    fixture(); let detail = await hubOrganizationDetail(access(), item(), 1, "overview");
    const page = await loadHubOrganizationSection(access(), detail.item, "members", 1, true); detail = applyHubOrganizationSection(detail, page, true);
    expect(detail.members).toHaveLength(30); expect(detail.members.map(member => member.id)).toEqual(Array.from({ length: 30 }, (_, id) => String(id))); expect(detail.organization!.sections.members.page).toBe(1);
    const teams = await loadHubOrganizationSection(access(), detail.item, "teams", 2, true); detail = applyHubOrganizationSection(detail, teams, true);
    expect(detail.organization!.teams).toHaveLength(12); expect(detail.organization!.teams.every(team => team.members.length === 6)).toBe(true);
    const team = detail.organization!.teams[0]; const people = await loadHubOrganizationTeamMembers(access(), detail.item, team, 1); expect(people.members).toHaveLength(30); expect(people.state.page).toBe(1);
  });
  it("uses server team slugs and subgroup IDs for native people requests", async () => {
    const http = fixture(); const detail = await hubOrganizationDetail(access(), item(), 1, "overview");
    expect(http.mock.calls.some(call => call[1].includes("/orgs/team/teams/server-team-100/members?role=all&per_page=6&page=1"))).toBe(true);
    const team = { ...detail.organization!.teams[0], slug: "" }; const before = http.mock.calls.length; await expect(loadHubOrganizationTeamMembers(access(), item(), team, 0)).rejects.toThrow("identifier"); expect(http).toHaveBeenCalledTimes(before);
  });
  it("appends one dashboard card in place and rejects late reads after switching the organization", async () => {
    const saved = accounts.accounts, account = { id: "demo", provider: "github" as const, server: "https://github.com", username: "demo", name: null, avatarURL: null }; accounts.accounts = [account]; vi.spyOn(accounts, "token").mockResolvedValue("fixture-token"); const http = fixture();
    try {
      const hub = new HostingHubStore({ path: null, target: null, hostingAccount: account }); hub.section = "organizations"; await hub.select(item(), false, "overview");
      await hub.loadOrganizationSection("members"); expect(hub.tab).toBe("overview"); expect(hub.detail!.members).toHaveLength(30); expect(hub.detail!.organization!.teams).toHaveLength(6);
      await hub.loadOrganizationSection("teams", "100"); expect(hub.detail!.organization!.teams[0].members).toHaveLength(30); expect(hub.detail!.organization!.teams[1].members).toHaveLength(6);
      const original = http.getMockImplementation()!; let resolve!: (value: ReturnType<typeof response>) => void;
      http.mockImplementation((...args) => args[1].includes("/members?per_page=30&page=2") ? new Promise(done => { resolve = done; }) : original(...args));
      const pending = hub.loadOrganizationSection("members"); await vi.waitFor(() => expect(resolve).toBeDefined()); await hub.select({ ...item(), id: "other" }, false, "overview"); resolve(response([{ id: 999, login: "late-person" }])); await pending;
      expect(hub.detail!.item.id).toBe("other"); expect(hub.detail!.members.some(member => member.id === "999")).toBe(false);
    } finally { accounts.accounts = saved; }
  });
  it("retries the failed inline page instead of restarting the dashboard preview", async () => {
    const saved = accounts.accounts, account = { id: "demo", provider: "github" as const, server: "https://github.com", username: "demo", name: null, avatarURL: null }; accounts.accounts = [account]; vi.spyOn(accounts, "token").mockResolvedValue("fixture-token"); const http = fixture();
    try {
      const hub = new HostingHubStore({ path: null, target: null, hostingAccount: account }); hub.section = "organizations"; await hub.select(item(), false, "overview"); await hub.loadOrganizationSection("members");
      const original = http.getMockImplementation()!; let failed = false;
      http.mockImplementation(async (...args) => { if (args[1].includes("/members?per_page=30&page=2") && !failed) { failed = true; return response({ message: "Temporary failure" }, 503); } return original(...args); });
      await hub.loadOrganizationSection("members"); expect(hub.detail!.organization!.sections.members.error).toContain("503"); expect(hub.detail!.members).toHaveLength(30);
      await hub.loadOrganizationSection("members"); expect(hub.detail!.members).toHaveLength(60); expect(hub.detail!.organization!.sections.members.page).toBe(2); expect(http.mock.calls.filter(call => call[1].includes("/members?per_page=30&page=2"))).toHaveLength(2);
    } finally { accounts.accounts = saved; }
  });
  it("builds administration links on the connected host and rejects spoofed addresses", () => {
    expect(hubOrganizationLinks(access(), item()).map(link => link.title)).toContain("Audit log"); expect(hubOrganizationLinks(access("gitlab"), item("gitlab")).every(link => link.url.startsWith("https://gitlab.example.com/groups/team/"))).toBe(true); expect(hubOrganizationLinks(access(), { ...item(), url: "https://evil.example.com/team" })).toEqual([]);
  });
});
