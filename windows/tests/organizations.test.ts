import { afterEach, describe, expect, it, vi } from "vitest";
import { accounts, HostingHubStore, hubPage, hubOrganizationDetail, hubOrganizationInviteError, inviteHubOrganizationMember, cancelHubOrganizationInvitation, hubOrganizationLinks, HubUncertainWriteError, type HubAccess, type HubItem, type HubOrganizationInviteInput } from "@/entities/hosting";
import { ipc } from "@/shared/api";
const access = (provider: "github" | "gitlab" = "github"): HubAccess => ({ target: { provider, host: provider === "github" ? "github.com" : "gitlab.example.com", remote: "origin", path: "team/repo" }, apiBase: provider === "github" ? "https://api.github.com" : "https://gitlab.example.com/api/v4", token: "fixture-token", me: "demo" });
const item = (provider: "github" | "gitlab" = "github"): HubItem => ({ id: provider === "github" ? "team" : "5", title: "Demo team", subtitle: "team", url: provider === "github" ? "https://github.com/team" : "https://gitlab.example.com/team", body: "", data: {} });
const input = (values: Partial<HubOrganizationInviteInput> = {}): HubOrganizationInviteInput => ({ email: "member@example.com", role: "direct_member", expiresAt: "", ...values });
const response = (value: unknown, status = 200) => ({ status, body: status === 204 ? "" : JSON.stringify(value) });
function fixture(role = "admin", provider: "github" | "gitlab" = "github") {
  return vi.spyOn(ipc, "http").mockImplementation(async (method, url) => {
    if (method !== "GET") return response(provider === "github" ? { id: 10 } : { status: "success" }, method === "DELETE" ? 204 : 201);
    if (url.includes("/user/memberships/")) return response({ role, state: "active" });
    if (url.endsWith("/user")) return response({ id: 9, username: "demo" });
    if (url.endsWith("/members/all/9")) return response({ id: 9, username: "demo", access_level: Number(role) });
    if (url.includes("/invitations?")) return response([{ id: 10, ...(provider === "github" ? { email: "member@example.com" } : { invite_email: "member@example.com" }), role: "direct_member", access_level: 30 }]);
    if (url.includes("/teams?") || url.includes("/subgroups?")) return response(Array.from({ length: 30 }, (_, id) => ({ id, name: `Team ${id}`, html_url: "https://github.com/orgs/team/teams/demo", web_url: "https://gitlab.example.com/team/subgroup" })));
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

  it("loads overview counts and confirms active GitHub ownership", async () => {
    const http = fixture(); const detail = await hubOrganizationDetail(access(), item(), 1, "overview");
    expect(detail.organization?.info).toMatchObject({ role: "Owner", canInvite: true, publicRepositories: 12, privateRepositories: 3 }); expect(http).toHaveBeenCalledTimes(2);
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
    expect(detail.more).toBe(true); expect(detail.organization?.teams).toHaveLength(30); expect(http.mock.calls.at(-1)?.[1]).toContain("/subgroups?per_page=30&page=2&all_available=true");
  });
  it("preserves profile on a forbidden team section", async () => {
    const http = fixture(); http.mockImplementation(async (_method, url) => url.includes("/teams?") ? response({ message: "Forbidden" }, 403) : response(url.includes("/user/memberships/") ? { role: "member", state: "active" } : { name: "Demo team" }));
    const detail = await hubOrganizationDetail(access(), item(), 1, "teams"); expect(detail.item.title).toBe("Demo team"); expect(detail.notice).toContain("cannot access"); expect(detail.organization?.teams).toEqual([]);
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
  it("builds administration links on the connected host and rejects spoofed addresses", () => {
    expect(hubOrganizationLinks(access(), item()).map(link => link.title)).toContain("Audit log"); expect(hubOrganizationLinks(access("gitlab"), item("gitlab")).every(link => link.url.startsWith("https://gitlab.example.com/groups/team/"))).toBe(true); expect(hubOrganizationLinks(access(), { ...item(), url: "https://evil.example.com/team" })).toEqual([]);
  });
});
