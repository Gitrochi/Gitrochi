import { afterEach, describe, expect, it, vi } from "vitest";
import type { HostAccount } from "@/entities/git";
import { accounts, AccountStore, HostingHubStore } from "@/entities/hosting";
import { ipc } from "@/shared/api";
import { settings } from "@/shared/config";

const fixture: HostAccount = { id: "saved-account", provider: "github", server: "https://github.com", username: "octocat", name: null, avatarURL: null };
const privateOutput = "fixture-private-credential-output";
const store = () => {
  const account = new AccountStore();
  account.accounts = [fixture];
  return account;
};

afterEach(() => vi.restoreAllMocks());

describe("saved account credentials", () => {
  it("reports read failures without exposing private details and reads again on retry", async () => {
    const read = vi.spyOn(ipc, "secretGet").mockRejectedValueOnce(new Error(privateOutput)).mockResolvedValue("renewed-token");
    const account = store();
    try { await account.token(fixture, { reportReadFailure: true }); throw new Error("Expected credential read failure"); }
    catch (error) {
      expect(String(error)).toContain("Couldn't read the saved account credentials");
      expect(String(error)).not.toContain(privateOutput);
    }
    expect(await account.token(fixture)).toBe("renewed-token");
    expect(await account.token(fixture)).toBe("renewed-token");
    expect(read).toHaveBeenCalledTimes(2);
  });

  it("lets best-effort callers continue when credentials cannot be read", async () => {
    const read = vi.spyOn(ipc, "secretGet").mockRejectedValueOnce(new Error(privateOutput)).mockResolvedValue("available-token");
    const account = store();
    expect(await account.token(fixture)).toBeNull();
    expect(await account.token(fixture)).toBe("available-token");
    expect(read).toHaveBeenCalledTimes(2);
  });

  it("does not retain a missing credential when the next read can find it", async () => {
    const read = vi.spyOn(ipc, "secretGet").mockResolvedValueOnce(null).mockResolvedValue("available-token");
    const account = store();
    expect(await account.token(fixture)).toBeNull();
    expect(await account.token(fixture)).toBe("available-token");
    expect(read).toHaveBeenCalledTimes(2);
  });

  it("keeps Projects loading until credentials resolve and recovers from a failed read with Retry", async () => {
    let fail!: (reason: Error) => void;
    const read = vi.spyOn(ipc, "secretGet").mockImplementationOnce(() => new Promise((_resolve, reject) => { fail = reject; })).mockResolvedValue("available-token");
    const account = store();
    vi.spyOn(accounts, "token").mockImplementation((...args) => account.token(...args));
    const http = vi.spyOn(ipc, "http").mockResolvedValue({ status: 200, body: JSON.stringify({ data: { user: { projectsV2: { nodes: [{ id: "project", title: "Roadmap" }], pageInfo: {} } } } }) });
    const hub = new HostingHubStore({ path: null, target: null, hostingAccount: fixture });
    const loading = hub.activate("projects");
    expect(hub.loading).toBe(true);
    expect(hub.error).toBeNull();
    expect(http).not.toHaveBeenCalled();
    fail(new Error(privateOutput));
    await loading;
    expect(hub.loading).toBe(false);
    expect(hub.error).toContain("Couldn't read the saved account credentials");
    expect(hub.error).not.toContain(privateOutput);
    expect(hub.error).not.toContain("no token");
    expect(hub.projectPermissionRequired).toBe(false);
    await hub.load();
    expect(hub.error).toBeNull();
    expect(hub.items.map((item) => item.title)).toEqual(["Roadmap"]);
    expect(read).toHaveBeenCalledTimes(2);
    expect(http).toHaveBeenCalledTimes(1);
  });

  it("shares pending reads and discards their result after the account disconnects", async () => {
    let finish!: (value: string) => void;
    const read = vi.spyOn(ipc, "secretGet").mockImplementation(() => new Promise((resolve) => { finish = resolve; }));
    vi.spyOn(ipc, "secretSet").mockResolvedValue(undefined);
    vi.spyOn(settings, "set").mockImplementation(() => {});
    const account = store();
    const first = account.token(fixture), second = account.token(fixture);
    expect(read).toHaveBeenCalledTimes(1);
    await account.disconnect(fixture);
    finish("retired-token");
    expect(await first).toBeNull();
    expect(await second).toBeNull();
    expect(await account.token(fixture)).toBeNull();
    expect(read).toHaveBeenCalledTimes(1);
  });

  it("does not let a late read replace credentials saved by reconnecting", async () => {
    let finish!: (value: string) => void;
    const read = vi.spyOn(ipc, "secretGet").mockImplementation(() => new Promise((resolve) => { finish = resolve; }));
    vi.spyOn(ipc, "secretSet").mockResolvedValue(undefined);
    vi.spyOn(ipc, "http").mockResolvedValue({ status: 200, body: '{"login":"octocat","name":null,"avatar_url":null}' });
    vi.spyOn(settings, "set").mockImplementation(() => {});
    const account = store();
    const pending = account.token(fixture);
    const connected = await account.connectGitHub("renewed-token");
    finish("retired-token");
    expect(await pending).toBe("renewed-token");
    expect(await account.token(connected)).toBe("renewed-token");
    expect(read).toHaveBeenCalledTimes(1);
  });
});
