import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
vi.hoisted(() => vi.stubGlobal("matchMedia", () => ({ matches: false, addEventListener() {}, removeEventListener() {} })));
vi.mock("@/entities/terminal", () => ({ TerminalSession: class {} }));
import { RepoStore } from "@/entities/repo";
import { issueTaskReference, issueBranchName, issueRequestBody, quoteIssueComment, changeIssueComment, issueLinkedRequests, rememberProjectBranch, type ReviewAccess, type InboxItem } from "@/entities/hosting";
import { ipc } from "@/shared/api";
const target = { provider: "github" as const, host: "github.com", path: "team/repo", remote: "origin" };
const item: InboxItem = { id: "issue-7", number: 7, title: "Improve search", body: "Body", url: "https://github.com/team/repo/issues/7", kind: "issue", state: "open", author: "reader", updated: null, unread: false };
const comment = { id: "12", author: "reader", body: "Original", date: null, editable: true };
const access: ReviewAccess = { target, token: "fixture", apiBase: "https://api.github.com", me: "reader" };
const response = (data: unknown) => ({ status: 200, body: JSON.stringify(data) });
beforeEach(() => { const memory = new Map<string, string>(); vi.stubGlobal("localStorage", { getItem: (key: string) => memory.get(key) ?? null, setItem: (key: string, value: string) => memory.set(key, value) }); });
afterEach(() => vi.restoreAllMocks());
describe("issue development handoffs", () => {
  it("creates a readable branch and closing reference only for the current issue repository", () => {
    const task = issueTaskReference(target, item)!;
    expect(issueBranchName(task)).toBe("feature/7-improve-search"); expect(issueRequestBody(task)).toBe("Closes #7\n\nhttps://github.com/team/repo/issues/7");
    expect(issueTaskReference(target, { ...item, url: "https://github.com/other/repo/issues/7" })).toBeNull();
    expect(issueTaskReference(target, { ...item, url: "https://reader:secret@github.com/team/repo/issues/7" })).toBeNull();
    expect(issueTaskReference(target, { ...item, isRequest: true })).toBeNull();
    expect(issueTaskReference({ ...target, path: "Team/Repo" }, item)?.number).toBe(7);
    expect(quoteIssueComment("reader", "one\ntwo")).toContain("> one\n> two");
  });
  it("prefills branch/PR dialogs without mutations and recovers a branch's linked issue", () => {
    const store = new RepoStore(); store.path = "fixture/issues"; store.target = target; store.headHash = "head"; store.headBranch = "feature/search";
    const run = vi.spyOn(store, "run").mockResolvedValue(true);
    store.requestIssueBranch(item); expect(store.sheet).toMatchObject({ kind: "newBranch", suggestedName: "feature/7-improve-search", projectTask: { number: 7 } });
    const task = issueTaskReference(target, item)!; rememberProjectBranch(store.path, store.headBranch, task);
    expect(store.currentBranchIssue?.number).toBe(7);
    store.requestIssuePullRequest(item); expect(store.sheet?.kind).toBe("createPullRequest"); expect(store.newPullRequestDraft).toMatchObject({ title: item.title, body: issueRequestBody(task), draft: true, issue: { number: 7 } });
    expect(run).not.toHaveBeenCalled(); store.target = { ...target, host: "enterprise.test" }; expect(store.currentBranchIssue).toBeNull();
  });
});
describe("issue comment editing", () => {
  it("rechecks ownership, issue and body before updating or deleting a comment", async () => {
    const http = vi.spyOn(ipc, "http").mockResolvedValue(response({ body: "Original", user: { login: "reader" }, issue_url: "https://api.github.com/repos/team/repo/issues/7" }));
    await changeIssueComment(access, item, comment, "Edited"); expect(http.mock.calls[1][0]).toBe("PATCH"); expect(JSON.parse(http.mock.calls[1][3]!)).toEqual({ body: "Edited" });
    await changeIssueComment(access, item, comment, null); expect(http.mock.calls.at(-1)?.[0]).toBe("DELETE");
    http.mockResolvedValue(response({ body: "Other edit", user: { login: "reader" }, issue_url: "https://api.github.com/repos/team/repo/issues/7" }));
    const count = http.mock.calls.length; await expect(changeIssueComment(access, item, comment, "New")).rejects.toThrow("changed"); expect(http.mock.calls.length).toBe(count + 1);
    http.mockResolvedValue(response({ body: "Original", user: { login: "other" } })); await expect(changeIssueComment(access, item, comment, "New")).rejects.toThrow("own");
  });
  it("does not write after an account change during the fresh read", async () => {
    let current = true; const http = vi.spyOn(ipc, "http").mockImplementation(async () => { current = false; return response({ body: "Original", user: { login: "reader" } }); });
    await expect(changeIssueComment({ ...access, stillCurrent: () => current }, item, comment, "New")).rejects.toThrow("changed"); expect(http).toHaveBeenCalledTimes(1);
  });
  it("uses GitLab issue notes and refuses injected IDs before requests", async () => {
    const http = vi.spyOn(ipc, "http").mockResolvedValue(response({ body: "Original", author: { username: "reader" } }));
    await changeIssueComment({ ...access, target: { ...target, provider: "gitlab" }, apiBase: "https://gitlab.test/api/v4" }, item, comment, "Edited");
    expect(http.mock.calls[1][0]).toBe("PUT"); expect(http.mock.calls[1][1]).toContain("/issues/7/notes/12");
    const count = http.mock.calls.length; await expect(changeIssueComment(access, item, { ...comment, id: "../1" }, "New")).rejects.toThrow(); expect(http).toHaveBeenCalledTimes(count);
  });
});
describe("server-reported linked requests", () => {
  it("paginates timeline references, deduplicates and rejects foreign servers", async () => {
    const ref = (url: string) => ({ event: "cross-referenced", source: { issue: { number: 4, title: "Search", state: "open", html_url: url, pull_request: {} } } });
    const http = vi.spyOn(ipc, "http").mockResolvedValue(response([ref("https://github.com/team/repo/pull/4"), ref("https://github.com/team/repo/pull/4"), ref("https://evil.test/team/repo/pull/4"), { event: "commented" }]));
    const page = await issueLinkedRequests(access, item, 2); expect(page.items).toHaveLength(1); expect(page.more).toBe(false); expect(http.mock.calls[0][1]).toContain("/issues/7/timeline?per_page=30&page=2");
  });
  it("uses GitLab's related merge requests endpoint", async () => {
    const http = vi.spyOn(ipc, "http").mockResolvedValue(response([{ iid: 9, title: "Search", state: "opened", web_url: "https://gitlab.test/team/repo/-/merge_requests/9" }]));
    const result = await issueLinkedRequests({ ...access, target: { ...target, host: "gitlab.test", provider: "gitlab" }, apiBase: "https://gitlab.test/api/v4" }, item);
    expect(result.items[0].number).toBe(9); expect(http.mock.calls[0][1]).toContain("/related_merge_requests?");
  });
});
