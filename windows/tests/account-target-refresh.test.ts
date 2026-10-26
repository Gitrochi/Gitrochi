import { afterEach, describe, expect, it, vi } from "vitest";
vi.hoisted(() => vi.stubGlobal("matchMedia", () => ({ matches: false, addEventListener() {}, removeEventListener() {} })));
vi.mock("@/entities/terminal", () => ({ TerminalSession: class {} }));
import { RepoStore } from "@/entities/repo";
import { accounts } from "@/entities/hosting";

const originalAccounts = accounts.accounts;
const originalRevision = accounts.revision;
afterEach(() => { accounts.accounts = originalAccounts; accounts.revision = originalRevision; vi.restoreAllMocks(); });

describe("계정 변경 뒤 저장소 서비스 갱신", () => {
  it("기존에 못 찾던 SSH 별칭을 계정 연결 뒤 다시 해석하고 중복 요청을 막는다", async () => {
    const store = new RepoStore();
    store.path = "/fixture/account-refresh"; store.remotes = ["origin"]; store.remoteURLs = { origin: "git@github-alice:owner/repository.git" };
    accounts.accounts = [];
    const requests = vi.spyOn(store, "loadPullRequests").mockResolvedValue(undefined);
    const reset = vi.spyOn(store.ci, "reset").mockImplementation(() => {});
    const badges = vi.spyOn(store.ci, "refreshBadges").mockResolvedValue(undefined);
    await store.refreshHostingAccount();
    expect(store.target).toBeNull();
    accounts.accounts = [{ id: "fixture-alice", provider: "github", server: "https://github.com", username: "alice", name: null, avatarURL: null }]; accounts.revision++;
    await store.refreshHostingAccount();
    expect(store.target).toMatchObject({ host: "github.com", path: "owner/repository" });
    expect(store.hostingAccount?.username).toBe("alice");
    expect(requests).toHaveBeenCalledTimes(2); expect(reset).toHaveBeenCalledTimes(2); expect(badges).toHaveBeenCalledTimes(2);
    await store.refreshHostingAccount();
    expect(requests).toHaveBeenCalledTimes(2);
    accounts.accounts = []; accounts.revision++;
    await store.refreshHostingAccount();
    expect(store.target).toBeNull(); expect(store.hostingAccount).toBeNull();
    expect(requests).toHaveBeenCalledTimes(3);
  });
});
