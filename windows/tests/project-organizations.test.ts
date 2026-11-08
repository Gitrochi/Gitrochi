import { afterEach, describe, expect, it, vi } from "vitest";
import { accounts, HostingHubStore, hubPage, hubProjectOrganization, hubProjectTarget, ProjectOrganizationState, type HubAccess } from "@/entities/hosting";
import type { HostAccount } from "@/entities/git";
import { ipc } from "@/shared/api";

const account = (id = "first"): HostAccount => ({ id, provider: "github", server: "https://github.com", username: id, name: null, avatarURL: null });
const response = (value: unknown, status = 200) => ({ status, body: JSON.stringify(value) });
const access = (): HubAccess => ({ target: hubProjectTarget(null, "github", "github.com", "reader", false, "demo-team"), token: "fixture-token", me: "reader", apiBase: "https://api.github.com", projectOrganization: "demo-team" });
const savedAccounts = accounts.accounts;
afterEach(() => { vi.restoreAllMocks(); accounts.accounts = savedAccounts; });

describe("organization project discovery", () => {
  it("queries a selected organization directly without an open repository and paginates its projects", async () => {
    const http = vi.spyOn(ipc, "http").mockResolvedValue(response({ data: { organization: { projectsV2: { nodes: [{ id: "P", title: "Delivery", number: 1 }], pageInfo: { hasNextPage: true, endCursor: "next" } } } } }));
    const page = await hubPage(access(), "projects", 2, "before");
    const payload = JSON.parse(http.mock.calls[0][3]!);
    expect(payload.query).toContain("organization(login:$owner)");
    expect(payload.query).not.toContain("repository(");
    expect(payload.variables).toEqual({ owner: "demo-team", cursor: "before" });
    expect(page).toMatchObject({ items: [{ id: "P" }], more: true, cursor: "next" });
  });

  it("keeps manual organization logins valid and independent of membership discovery", () => {
    expect(hubProjectOrganization("organization:demo-team")).toBe("demo-team");
    for (const value of ["", "-team", "team-", "team/repo", "team.example", "a".repeat(40), "two--hyphens"]) expect(hubProjectOrganization(`organization:${value}`)).toBeUndefined();
    expect(hubProjectOrganization("personal")).toBeUndefined();
  });

  it("paginates organization memberships and preserves loaded choices after a retry", async () => {
    const a = account(); accounts.accounts = [a]; vi.spyOn(accounts, "token").mockResolvedValue("fixture-token");
    let fail = true;
    const http = vi.spyOn(ipc, "http").mockImplementation(async (_method, url) => {
      if (url.includes("page=2")) { if (fail) return response({}, 500); return response([{ login: "later-team" }]); }
      return response(Array.from({ length: 30 }, (_, i) => ({ login: `team-${i}` })));
    });
    const catalog = new ProjectOrganizationState(); await catalog.activate(a, 1);
    expect(catalog.items).toHaveLength(30); expect(catalog.more).toBe(true);
    await catalog.load(true); expect(catalog.error).toContain("Your personal projects are still available"); expect(catalog.items).toHaveLength(30);
    fail = false; await catalog.load(true);
    expect(catalog.items.at(-1)?.id).toBe("later-team"); expect(catalog.error).toBeNull(); expect(catalog.more).toBe(false);
    expect(http.mock.calls.at(-1)?.[1]).toContain("page=2");
  });

  it("ignores delayed organization catalogs and clears choices when the account changes", async () => {
    const old = account(), next = account("second"); accounts.accounts = [old, next]; vi.spyOn(accounts, "token").mockResolvedValue("fixture-token");
    let finish!: (value: ReturnType<typeof response>) => void;
    vi.spyOn(ipc, "http").mockImplementationOnce(() => new Promise(resolve => { finish = resolve; })).mockResolvedValue(response([{ login: "new-team" }]));
    const catalog = new ProjectOrganizationState(), pending = catalog.activate(old, 1);
    await vi.waitFor(() => expect(finish).toBeDefined());
    const current = catalog.activate(next, 1); expect(catalog.items).toEqual([]); await current;
    finish(response([{ login: "old-team" }])); await pending;
    expect(catalog.items.map(item => item.id)).toEqual(["new-team"]); expect(catalog.error).toBeNull(); expect(catalog.loading).toBe(false);
  });

  it("changes the account and the owner in one step, as the Projects scope menu chooses them", async () => {
    // macOS: the same case in macos/Tools/test-hosting-hub-credentials.sh
    const first = account(), second = account("second"); accounts.accounts = [first, second]; vi.spyOn(accounts, "token").mockResolvedValue("fixture-token");
    const http = vi.spyOn(ipc, "http").mockResolvedValue(response({ data: { organization: { projectsV2: { nodes: [{ id: "theirs", title: "Delivery", number: 1 }], pageInfo: {} } } } }));
    const hub = new HostingHubStore({ path: null, target: null, hostingAccount: first }); hub.section = "projects"; hub.projectScope = "personal";
    await hub.selectProjectScope("organization:second-team", second.id);
    expect(hub.account?.id).toBe("second"); expect(hub.projectOwner).toBe("second-team"); expect(hub.items.map(item => item.id)).toEqual(["theirs"]);
    expect(http).toHaveBeenCalledTimes(1); expect(JSON.parse(http.mock.calls[0][3]!).variables.owner).toBe("second-team");
    await hub.selectProjectScope("organization:second-team", "missing");
    expect(hub.account?.id).toBe("second"); expect(http).toHaveBeenCalledTimes(1);
  });

  it("preserves organization scope without a repository and rejects old project reads after switching accounts", async () => {
    const old = account(), next = account("second"); accounts.accounts = [old, next]; vi.spyOn(accounts, "token").mockResolvedValue("fixture-token");
    let finish!: (value: ReturnType<typeof response>) => void;
    const http = vi.spyOn(ipc, "http").mockImplementationOnce(() => new Promise(resolve => { finish = resolve; })).mockResolvedValue(response({ data: { user: { projectsV2: { nodes: [{ id: "new" }], pageInfo: {} } } } }));
    const hub = new HostingHubStore({ path: null, target: null, hostingAccount: old }); hub.projectScope = "organization:shared-team";
    const pending = hub.activate("projects"); await vi.waitFor(() => expect(finish).toBeDefined());
    expect(hub.projectEffectiveScope).toBe("organization:shared-team"); expect(hub.projectOwner).toBe("shared-team");
    expect(JSON.parse(http.mock.calls[0][3]!).variables.owner).toBe("shared-team");
    await hub.selectAccount(next.id); finish(response({ data: { organization: { projectsV2: { nodes: [{ id: "old" }], pageInfo: {} } } } })); await pending;
    expect(hub.projectScope).toBe("personal"); expect(hub.items.map(item => item.id)).toEqual(["new"]); expect(hub.error).toBeNull();
  });
});
