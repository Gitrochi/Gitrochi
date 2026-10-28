import { afterEach, describe, expect, it, vi } from "vitest";
import { ipc } from "@/shared/api";
import { resolveHubOrganizationMember, readHubOrganizationMemberAccess, readHubOrganizationTeamAccess, setHubOrganizationMemberRole, setHubOrganizationTeamRole, HubUncertainWriteError, type HubAccess, type HubItem, type HubMember, type HubOrganizationTeam } from "@/entities/hosting";
const context = (provider: "github" | "gitlab" = "github"): HubAccess => ({ target: { provider, host: provider === "github" ? "github.com" : "gitlab.example.com", remote: "origin", path: "team/repo" }, apiBase: provider === "github" ? "https://api.github.com" : "https://gitlab.example.com/api/v4", token: "fixture-token", me: "demo" });
const organization = (provider: "github" | "gitlab" = "github"): HubItem => ({ id: provider === "github" ? "team" : "5", title: "Demo team", subtitle: "", body: "", url: "https://github.com/team", data: {} });
const person: HubMember = { id: "7", username: "contributor", name: "Demo contributor", role: "Member", avatarURL: null, url: "" };
const team: HubOrganizationTeam = { id: "20", slug: "server-team", name: "Desktop team", url: "", privacy: "closed", description: "", members: [], memberState: { loaded: false, loading: false, page: 0, more: false } };
const response = (value: unknown, status = 200) => ({ status, body: JSON.stringify(value) });
function fixture(provider: "github" | "gitlab" = "github") {
  const state = { actor: "demo", owner: true, pending: false, missing: false, orgRole: provider === "github" ? "member" : "30", directOrg: true, directTeam: false, teamRole: "30", custom: false, moved: false, teamInherited: false, teamChanged: false, result: null as unknown, awaiting: false };
  const http = vi.spyOn(ipc, "http").mockImplementation(async (method, url, _headers, body) => {
    const path = new URL(url).pathname;
    if (method !== "GET") {
      if (state.result !== null) return response(state.result);
      const input = JSON.parse(body!);
      return response(provider === "github" ? { state: "active", role: input.role, user: { id: 7, login: "contributor" } } : { id: 7, username: "contributor", access_level: input.access_level });
    }
    if (path.includes("/user/memberships/orgs/")) return response({ role: state.owner ? "admin" : "member", state: "active", user: { id: 1, login: state.actor } });
    if (path.endsWith("/users")) return response([{ id: 7, username: "contributor", name: "Demo contributor" }]);
    if (path.endsWith("/user")) return response({ id: 1, username: state.actor });
    if (path.endsWith("/members/all/1")) return response({ id: 1, username: "demo", access_level: state.owner ? 50 : 30 });
    if (path.endsWith("/groups/20")) return response({ id: 20, parent_id: state.moved ? 99 : 5 });
    if (path.endsWith("/teams/server-team")) return response({ id: state.teamChanged ? 99 : 20, slug: "server-team" });
    if (path.includes("/teams/") && path.endsWith("/memberships/contributor")) return state.directTeam ? response({ state: "active", role: state.teamRole === "30" ? "member" : state.teamRole, inherited: state.teamInherited }) : response({ message: "Missing" }, 404);
    if (path.endsWith("/memberships/contributor")) return state.missing ? response({ message: "Missing" }, 404) : response({ state: state.pending ? "pending" : "active", role: state.orgRole, user: { id: 7, login: "contributor" } });
    if (path.endsWith("/members/all/7")) return state.missing ? response({ message: "Missing" }, 404) : response({ id: 7, username: "contributor", state: "active", membership_state: state.awaiting ? "awaiting" : "active", access_level: path.includes("/groups/20/") ? state.teamRole : state.orgRole });
    if (path.endsWith("/members/7")) {
      const direct = path.includes("/groups/20/") ? state.directTeam : state.directOrg;
      return direct ? response({ id: 7, username: "contributor", access_level: path.includes("/groups/20/") ? state.teamRole : state.orgRole, ...(state.custom ? { member_role_id: 4 } : {}) }) : response({ message: "Missing" }, 404);
    }
    throw new Error(`Unexpected fixture request ${method} ${path}`);
  });
  return { state, http, writes: () => http.mock.calls.filter(call => call[0] !== "GET") };
}
afterEach(() => vi.restoreAllMocks());
describe("organization permission grants", () => {
  it("resolves an exact existing username without sending invitations", async () => {
    const f = fixture(); const member = await resolveHubOrganizationMember(context(), organization(), "@contributor"); expect(member.id).toBe("7"); expect(member.username).toBe("contributor"); f.state.pending = true; await expect(resolveHubOrganizationMember(context(), organization(), "contributor")).rejects.toThrow("active organization member"); expect(f.writes()).toHaveLength(0);
  });
  it("requires an exact GitLab username and active parent membership", async () => {
    const f = fixture("gitlab"); const member = await resolveHubOrganizationMember(context("gitlab"), organization("gitlab"), "contributor"); expect(member.id).toBe("7"); await expect(resolveHubOrganizationMember(context("gitlab"), organization("gitlab"), "other")).rejects.toThrow("active organization member"); expect(f.writes()).toHaveLength(0);
  });
  it("updates an existing active GitHub member after fresh owner and target reads", async () => {
    const f = fixture(); const snapshot = await readHubOrganizationMemberAccess(context(), organization(), person);
    await setHubOrganizationMemberRole(context(), organization(), snapshot, "admin"); expect(f.writes()).toHaveLength(1); expect(f.writes()[0].slice(0, 2)).toEqual(["PUT", "https://api.github.com/orgs/team/memberships/contributor"]); expect(JSON.parse(f.writes()[0][3]!)).toEqual({ role: "admin" });
  });
  it("does not let role upsert invite missing or pending people", async () => {
    const f = fixture(); const snapshot = await readHubOrganizationMemberAccess(context(), organization(), person);
    f.state.pending = true; await expect(setHubOrganizationMemberRole(context(), organization(), snapshot, "admin")).rejects.toThrow("active organization member"); f.state.pending = false; f.state.missing = true; await expect(setHubOrganizationMemberRole(context(), organization(), snapshot, "admin")).rejects.toThrow("active organization member"); expect(f.writes()).toHaveLength(0);
  });
  it("blocks wrong actors, unsupported roles and self changes without a write", async () => {
    const f = fixture(); const snapshot = await readHubOrganizationMemberAccess(context(), organization(), person);
    await expect(setHubOrganizationMemberRole(context(), organization(), snapshot, "superuser")).rejects.toThrow("supported"); f.state.actor = "other"; await expect(setHubOrganizationMemberRole(context(), organization(), snapshot, "admin")).rejects.toThrow("owner"); await expect(readHubOrganizationMemberAccess(context(), organization(), { ...person, username: "DEMO" })).rejects.toThrow("own access"); expect(f.writes()).toHaveLength(0);
  });
  it("binds snapshots to the organization and team scope", async () => {
    const f = fixture(); const snapshot = await readHubOrganizationMemberAccess(context(), organization(), person); const before = f.http.mock.calls.length;
    await expect(setHubOrganizationMemberRole(context(), { ...organization(), id: "other" }, snapshot, "admin")).rejects.toThrow("changed"); await expect(setHubOrganizationTeamRole(context(), organization(), team, snapshot, "member")).rejects.toThrow("changed"); expect(f.http).toHaveBeenCalledTimes(before); expect(f.writes()).toHaveLength(0);
  });
  it("rejects a changed role or stale account before mutation", async () => {
    const f = fixture(); const snapshot = await readHubOrganizationMemberAccess(context(), organization(), person); f.state.orgRole = "admin";
    await expect(setHubOrganizationMemberRole(context(), organization(), snapshot, "admin")).rejects.toThrow("changed on the server"); await expect(setHubOrganizationMemberRole({ ...context(), stillCurrent: () => false }, organization(), snapshot, "admin")).rejects.toThrow("account changed"); expect(f.writes()).toHaveLength(0);
  });
  it("assigns a GitHub team member only after confirming organization membership", async () => {
    const f = fixture(); const snapshot = await readHubOrganizationTeamAccess(context(), organization(), team, person);
    await setHubOrganizationTeamRole(context(), organization(), team, snapshot, "maintainer"); expect(f.writes()[0][1]).toContain("/teams/server-team/memberships/contributor"); expect(JSON.parse(f.writes()[0][3]!)).toEqual({ role: "maintainer" });
  });
  it("rejects a reused GitHub team slug before granting to a different team", async () => {
    const f = fixture(); const snapshot = await readHubOrganizationTeamAccess(context(), organization(), team, person); f.state.teamChanged = true;
    await expect(setHubOrganizationTeamRole(context(), organization(), team, snapshot, "maintainer")).rejects.toThrow("team changed on the server"); expect(f.writes()).toHaveLength(0);
  });
  it("never claims a pending GitHub upsert response granted access", async () => {
    const f = fixture(); const snapshot = await readHubOrganizationMemberAccess(context(), organization(), person); f.state.result = { state: "pending", role: "admin", user: { id: 7, login: "contributor" } };
    await expect(setHubOrganizationMemberRole(context(), organization(), snapshot, "admin")).rejects.toBeInstanceOf(HubUncertainWriteError); expect(f.writes()).toHaveLength(1);
  });
  it("keeps inherited or custom GitLab organization roles read-only", async () => {
    const f = fixture("gitlab"); f.state.directOrg = false; let snapshot = await readHubOrganizationMemberAccess(context("gitlab"), organization("gitlab"), person); await expect(setHubOrganizationMemberRole(context("gitlab"), organization("gitlab"), snapshot, "40")).rejects.toThrow("inherited");
    f.state.directOrg = true; f.state.custom = true; snapshot = await readHubOrganizationMemberAccess(context("gitlab"), organization("gitlab"), person); await expect(setHubOrganizationMemberRole(context("gitlab"), organization("gitlab"), snapshot, "40")).rejects.toThrow("Custom roles"); expect(f.writes()).toHaveLength(0);
  });
  it("grants a higher direct subgroup role with POST while preserving inherited access", async () => {
    const f = fixture("gitlab"); const snapshot = await readHubOrganizationTeamAccess(context("gitlab"), organization("gitlab"), team, person);
    await expect(setHubOrganizationTeamRole(context("gitlab"), organization("gitlab"), team, snapshot, "20")).rejects.toThrow("inherited"); await setHubOrganizationTeamRole(context("gitlab"), organization("gitlab"), team, snapshot, "40"); expect(f.writes()[0].slice(0, 2)).toEqual(["POST", "https://gitlab.example.com/api/v4/groups/20/members"]); expect(JSON.parse(f.writes()[0][3]!)).toEqual({ user_id: 7, access_level: 40 });
  });
  it("requires a fresh subgroup parent and owner before granting direct access", async () => {
    const f = fixture("gitlab"); const snapshot = await readHubOrganizationTeamAccess(context("gitlab"), organization("gitlab"), team, person); f.state.moved = true;
    await expect(setHubOrganizationTeamRole(context("gitlab"), organization("gitlab"), team, snapshot, "40")).rejects.toThrow("no longer belongs"); f.state.moved = false; f.state.owner = false; await expect(setHubOrganizationTeamRole(context("gitlab"), organization("gitlab"), team, snapshot, "40")).rejects.toThrow("owner"); expect(f.writes()).toHaveLength(0);
  });
  it("edits a direct GitLab subgroup role with PUT and rejects awaiting parent membership", async () => {
    const f = fixture("gitlab"); f.state.directTeam = true; f.state.teamRole = "40"; const snapshot = await readHubOrganizationTeamAccess(context("gitlab"), organization("gitlab"), team, person);
    await setHubOrganizationTeamRole(context("gitlab"), organization("gitlab"), team, snapshot, "50"); expect(f.writes()[0][0]).toBe("PUT"); expect(f.writes()[0][1]).toContain("/groups/20/members/7"); f.state.awaiting = true; await expect(setHubOrganizationTeamRole(context("gitlab"), organization("gitlab"), team, snapshot, "50")).rejects.toThrow("active organization member"); expect(f.writes()).toHaveLength(1);
  });
  it("distinguishes queued approvals from validation rejection and malformed responses", async () => {
    const f = fixture("gitlab"); const snapshot = await readHubOrganizationMemberAccess(context("gitlab"), organization("gitlab"), person);
    for (const result of [{ message: { contributor: "Request queued for administrator approval" } }, { status: "success", queued_users: { contributor: "queued" } }]) { f.state.result = result; await expect(setHubOrganizationMemberRole(context("gitlab"), organization("gitlab"), snapshot, "40")).resolves.toContain("approval"); }
    f.state.result = { message: { access_level: "is invalid" } }; await expect(setHubOrganizationMemberRole(context("gitlab"), organization("gitlab"), snapshot, "40")).rejects.toThrow("rejected"); f.state.result = {}; await expect(setHubOrganizationMemberRole(context("gitlab"), organization("gitlab"), snapshot, "40")).rejects.toBeInstanceOf(HubUncertainWriteError);
  });
});
