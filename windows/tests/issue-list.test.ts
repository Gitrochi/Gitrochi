import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
vi.hoisted(() => vi.stubGlobal("matchMedia", () => ({ matches: false, addEventListener() {}, removeEventListener() {} })));
vi.mock("@/entities/terminal", () => ({ TerminalSession: class {} }));
import { RepoStore } from "@/entities/repo";
import type { ReviewAccess } from "@/entities/hosting";
import { settings } from "@/shared/config";
import { ipc } from "@/shared/api";

const issue = (number: number, state = "open") => ({ number, title: `Issue ${number}`, body: `Body ${number}`, state, html_url: `https://github.com/team/repo/issues/${number}`, user: { login: "author" } });
const response = (value: unknown) => ({ status: 200, body: JSON.stringify(value) });
let memory: Record<string, unknown>;
let urls: string[];
let list: (url: string) => unknown;
const internal = (store: RepoStore) => store as unknown as { reviewAccess(): Promise<ReviewAccess | null>; resetState(): void };
const fixture = (path = "C:/fixture/issues") => {
  const store = new RepoStore(); store.path = path;
  store.target = { provider: "github", host: "github.com", path: "team/repo", remote: "origin" };
  const access = (): ReviewAccess => ({ target: store.target!, token: "fixture-token", apiBase: "https://api.github.com", me: "me" });
  vi.spyOn(store, "workspaceAccess").mockImplementation(async () => access());
  vi.spyOn(internal(store), "reviewAccess").mockImplementation(async () => access());
  return store;
};
beforeEach(() => {
  memory = {}; urls = [];
  list = () => [issue(1), issue(2)];
  vi.spyOn(settings, "get").mockImplementation(<T>(key: string, fallback: T): T => (memory[key] ?? fallback) as T);
  vi.spyOn(settings, "set").mockImplementation((key, value) => { memory[key] = value; });
  vi.spyOn(ipc, "run").mockImplementation(async () => { throw new Error("Issue tests must not start processes"); });
  vi.spyOn(ipc, "http").mockImplementation(async (method, url) => {
    if (method !== "GET") throw new Error("Issue list tests only read");
    urls.push(url);
    // GitHub answers a text search through the search API
    if (url.includes("/search/issues?")) { const items = list(url) as unknown[]; return response({ items, total_count: items.length }); }
    if (/\/issues\?/.test(url)) return response(list(url));
    if (/\/comments\?/.test(url)) return response([{ id: 9, body: "A comment", user: { login: "reviewer" } }]);
    const number = Number(url.match(/\/issues\/(\d+)/)?.[1]);
    return response(issue(number));
  });
});
afterEach(() => { expect(ipc.run).not.toHaveBeenCalled(); vi.restoreAllMocks(); });

describe("shared issue list", () => {
  it("loads once per repository context, whichever view asks first", async () => {
    const store = fixture();
    await store.prepareIssues(); await store.prepareIssues();
    expect(store.issues.map((i) => i.number)).toEqual([1, 2]); expect(store.issueState.kind).toBe("loaded"); expect(store.issuePage).toBe(1);
    expect(urls.filter((url) => url.includes("/issues?"))).toHaveLength(1);
  });
  it("opens an issue from the sidebar on the Issues page and keeps it when the page prepares its list", async () => {
    const store = fixture(); await store.prepareIssues(); store.navigate("repository");
    store.openIssue(store.issues[1]);
    expect(store.destination).toBe("issues"); expect(store.inboxDetail?.item.number).toBe(2);
    await vi.waitFor(() => expect(store.inboxDetail?.comments).toHaveLength(1));
    await store.prepareIssues();
    expect(store.inboxDetail?.item.number).toBe(2); expect(urls.filter((url) => url.includes("/issues?"))).toHaveLength(1);
  });
  it("searches and filters from the first page without closing the open issue", async () => {
    const store = fixture(); await store.prepareIssues();
    await store.openInboxItem(store.issues[0]);
    list = () => [issue(5, "closed")];
    await store.filterIssues("closed", "crash");
    expect(store.issueScope).toBe("closed"); expect(store.issueSearch).toBe("crash"); expect(store.issues.map((i) => i.number)).toEqual([5]); expect(store.issuePage).toBe(1);
    const q = new URL(urls.filter((url) => url.includes("/search/issues?")).at(-1)!).searchParams.get("q") ?? "";
    expect(q).toContain("repo:team/repo"); expect(q).toContain("is:closed"); expect(q).toContain('"crash"');
    expect(store.inboxDetail?.item.number).toBe(1);
    await store.filterIssues("open", "");
    expect(new URL(urls.at(-1)!).searchParams.get("state")).toBe("open"); expect(store.inboxDetail?.item.number).toBe(1);
  });
  it("appends further pages without duplicates and reports more while a page is full", async () => {
    const store = fixture();
    list = (url) => new URL(url).searchParams.get("page") === "1" ? Array.from({ length: 30 }, (_, i) => issue(i + 1)) : [issue(30), issue(31)];
    await store.prepareIssues(); expect(store.issuesMore).toBe(true);
    await store.loadIssues(true);
    expect(store.issuePage).toBe(2); expect(store.issues).toHaveLength(31); expect(store.issuesMore).toBe(false);
  });
  it("drops the list and the open issue when the repository context changes, and ignores a late answer", async () => {
    const store = fixture(); await store.prepareIssues(); await store.openInboxItem(store.issues[0]);
    let finish!: () => void, started = false;
    const late = new Promise<void>((resolve) => { finish = resolve; });
    list = () => [issue(8)];
    vi.mocked(ipc.http).mockImplementationOnce(async () => { started = true; await late; return response([issue(99)]); });
    const pending = store.loadIssues();
    await vi.waitFor(() => expect(started).toBe(true));
    store.path = "C:/fixture/other";
    await store.prepareIssues();
    finish(); await pending;
    expect(store.inboxDetail).toBeNull(); expect(store.issues.map((i) => i.number)).toEqual([8]);
  });
  it("asks for an account instead of failing when there is no access, and resets the filter with the repository", async () => {
    const store = fixture(); vi.mocked(store.workspaceAccess).mockResolvedValue(null);
    await store.prepareIssues();
    expect(store.issueState.kind).toBe("needsAccount"); expect(store.issues).toEqual([]);
    store.issueScope = "all"; store.issueSearch = "x"; internal(store).resetState();
    expect(store.issueScope).toBe("open"); expect(store.issueSearch).toBe(""); expect(store.issueState.kind).toBe("idle");
  });
  it("asks once before closing an issue, without treating it as destructive", async () => {
    const store = fixture(); await store.prepareIssues();
    store.confirmIssueState(store.issues[0]);
    expect(store.confirm?.destructive).toBe(false); expect(store.confirm?.message).toBe("Issue 1");
  });
});
