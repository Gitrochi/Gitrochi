import { afterEach, describe, expect, it, vi } from "vitest";
import {
  accounts,
  HostingHubStore,
  HubUncertainWriteError,
  type HubDetail,
} from "@/entities/hosting";
import { ipc } from "@/shared/api";
const account = {
  id: "fixture",
  provider: "github" as const,
  server: "https://github.com",
  username: "reviewer",
  name: null,
  avatarURL: null,
};
const detail = (id = "PROJECT"): HubDetail => ({
  item: {
    id,
    title: "Roadmap",
    subtitle: "#1",
    body: "",
    url: "https://github.com/orgs/team/projects/1",
    data: {},
  },
  rows: [],
  fields: [],
  assets: [],

  members: [],
  repositories: [],
  more: false,
});
const storedAccounts = accounts.accounts;
afterEach(() => {
  accounts.accounts = storedAccounts;
  vi.restoreAllMocks();
});
function fixture() {
  accounts.accounts = [account];
  vi.spyOn(accounts, "token").mockResolvedValue("fixture-only");
  vi.spyOn(ipc, "http").mockResolvedValue({
    status: 200,
    body: JSON.stringify({
      data: {
        node: {
          id: "PROJECT",
          title: "Roadmap",
          fields: { nodes: [], pageInfo: {} },
          items: { nodes: [], pageInfo: {} },
        },
      },
    }),
  });
  const store = new HostingHubStore({
    path: "fixture/client",
    target: {
      provider: "github",
      host: "github.com",
      path: "team/client",
      remote: "origin",
    },
    hostingAccount: account,
  });
  store.section = "projects";
  store.detail = detail();
  return store;
}
describe("project action context", () => {
  it("includes the selected project in the confirmation identity", () => {
    const store = fixture(),
      stamp = store.actionStamp;
    store.detail = detail("OTHER");
    expect(store.actionStamp).not.toBe(stamp);
  });
  it("rejects a delayed write after the selected project changes", async () => {
    const store = fixture();
    let resolve!: (token: string) => void;
    vi.mocked(accounts.token).mockImplementation(
      () =>
        new Promise((done) => {
          resolve = done;
        }),
    );
    const write = vi.fn(async () => {}),
      pending = store.action(write);
    store.detail = detail("OTHER");
    resolve("fixture-only");
    expect(await pending).toBe(false);
    expect(write).not.toHaveBeenCalled();
    expect(store.busy).toBe(false);
  });
  it("keeps the current project mounted during a same-project refresh", async () => {
    const store = fixture(),
      snapshot = store.detail;
    const pending = store.select(snapshot!.item);
    expect(store.detail).toBe(snapshot);
    await pending;
    expect(store.detail?.item.id).toBe("PROJECT");
  });
  it("blocks writes after an uncertain response until a successful refresh", async () => {
    const store = fixture();
    await store.action(async () => {
      throw new HubUncertainWriteError("Refresh before retrying.");
    });
    expect(store.uncertainWrite).toBe(true);
    const write = vi.fn(async () => {});
    expect(await store.action(write)).toBe(false);
    expect(write).not.toHaveBeenCalled();
    await store.select(store.detail!.item);
    expect(store.uncertainWrite).toBe(false);
    expect(await store.action(write)).toBe(true);
    expect(write).toHaveBeenCalledTimes(1);
  });
});
