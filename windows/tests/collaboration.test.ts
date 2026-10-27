import { afterEach, describe, expect, it, vi } from "vitest";
import { inboxDetail, inboxPage, markInboxRead, mergeRequest, requestLifecycle, requestPage, setReviewers, postInboxComment, type ReviewAccess } from "@/entities/hosting";
import { githubReviewThreads, resolveGithubThread } from "../src/entities/hosting/api/review-threads";
import { ipc } from "@/shared/api";
const access = (provider: "github" | "gitlab" = "github"): ReviewAccess => ({ target: { provider, host: `${provider}.example`, path: "team/repo", remote: "origin" }, token: "fixture", apiBase: `https://${provider}.example/api`, me: "reviewer" });
const response = (value: unknown, status = 200) => ({ status, body: JSON.stringify(value) });
const gh = (head = "head-a") => ({ number: 1, title: "Request", body: "Description", user: { login: "reviewer" }, head: { ref: "work", sha: head, repo: { full_name: "team/repo" } }, base: { ref: "main" }, html_url: "https://github.example/team/repo/pull/1", state: "open", mergeable: true, mergeable_state: "clean", requested_reviewers: [{ login: "one" }] });
const ghRepo = { state: "success", total_count: 0, check_runs: [], allow_merge_commit: true, allow_squash_merge: true, allow_rebase_merge: false, permissions: { push: true } };
const gl = { iid: 1, title: "Request", author: { username: "reviewer" }, source_branch: "work", target_branch: "main", sha: "head-a", web_url: "https://gitlab.example/x", state: "opened", detailed_merge_status: "mergeable", user: { can_merge: true }, head_pipeline: { status: "success" } };
afterEach(() => vi.restoreAllMocks());
describe("PR lifecycle", () => {
  it("lists GitHub pulls through the REST list and narrows reviewer and text on the loaded page", async () => {
    const c = access(), http = vi.spyOn(ipc, "http").mockResolvedValue(response([{ ...gh(), requested_reviewers: [{ login: "Reviewer" }], title: "Fix things" }, { ...gh(), number: 2, title: "Other" }]));
    const r = await requestPage(c, { scope: "reviewRequested", search: "fix", page: 2 }); const url = new URL(http.mock.calls[0][1]), q = url.searchParams;
    expect(http).toHaveBeenCalledTimes(1); expect(url.pathname.endsWith("/repos/team/repo/pulls")).toBe(true); expect(q.get("state")).toBe("open"); expect(q.get("page")).toBe("2");
    expect(r.items.map((p) => p.number)).toEqual([1]); expect(r.items[0].headSHA).toBe("head-a"); expect(r.more).toBe(false); expect(r.warning).toBeTruthy();
  });
  it("tells merged from closed GitHub pulls by merged_at and reads a bigger page when filtering", async () => {
    const http = vi.spyOn(ipc, "http").mockResolvedValue(response([{ ...gh(), state: "closed", merged_at: "2026-01-01T00:00:00Z" }, { ...gh(), number: 2, state: "closed", merged_at: null }]));
    const merged = await requestPage(access(), { scope: "merged", search: "", page: 1 }); const q = new URL(http.mock.calls[0][1]).searchParams;
    expect(q.get("state")).toBe("closed"); expect(q.get("per_page")).toBe("100"); expect(merged.items.map((p) => p.number)).toEqual([1]); expect(merged.warning).toBeUndefined();
    expect((await requestPage(access(), { scope: "closed", search: "", page: 1 })).items.map((p) => p.number)).toEqual([2]);
    const open = await requestPage(access(), { scope: "open", search: "", page: 1 });
    expect(new URL(http.mock.calls[2][1]).searchParams.get("per_page")).toBe("30"); expect(open.items.length).toBe(2);
  });
  it("filters merged GitLab requests on the server", async () => {
    const http = vi.spyOn(ipc, "http").mockResolvedValue(response([gl])); await requestPage(access("gitlab"), { scope: "merged", search: "fix", page: 3 });
    const q = new URL(http.mock.calls[0][1]).searchParams; expect(q.get("state")).toBe("merged"); expect(q.get("search")).toBe("fix"); expect(q.get("page")).toBe("3");
  });
  it("blocks changed SHAs without performing a merge", async () => {
    const c = access(); let head = "head-a"; const http = vi.spyOn(ipc, "http").mockImplementation(async (_m, url) => response(url.endsWith("/pulls/1") ? gh(head) : ghRepo));
    const expected = await requestLifecycle(c, 1); head = "head-b"; await expect(mergeRequest(c, expected, "merge")).rejects.toThrow("changed"); expect(http.mock.calls.some(([m]) => m === "PUT")).toBe(false);
  });
  it("blocks unknown permissions and pending checks", async () => {
    const c = access(); vi.spyOn(ipc, "http").mockImplementation(async (_m, url) => response(url.endsWith("/pulls/1") ? { ...gh(), mergeable_state: "blocked" } : { ...ghRepo, permissions: {} }));
    const expected = await requestLifecycle(c, 1); expect(expected.blockers).toHaveLength(2); await expect(mergeRequest(c, expected, "squash")).rejects.toThrow();
  });
  it("sends the exact reviewed SHA and allowed merge method", async () => {
    const c = access(), http = vi.spyOn(ipc, "http").mockImplementation(async (m, url) => response(m === "PUT" ? { merged: true } : url.endsWith("/pulls/1") ? gh() : ghRepo));
    const expected = await requestLifecycle(c, 1); await mergeRequest(c, expected, "squash"); expect(JSON.parse(http.mock.calls.find(([m]) => m === "PUT")![3]!)).toEqual({ sha: "head-a", merge_method: "squash" });
  });
  it("stops writes if context changes during readiness lookup", async () => {
    const c = access(); let current = true; c.stillCurrent = () => current;
    const http = vi.spyOn(ipc, "http").mockImplementation(async (_m, url) => response(url.endsWith("/pulls/1") ? gh() : ghRepo));
    const expected = await requestLifecycle(c, 1); http.mockImplementation(async (_m, url) => { if (url.endsWith("/pulls/1")) current = false; return response(url.endsWith("/pulls/1") ? gh() : ghRepo); });
    await expect(mergeRequest(c, expected, "merge")).rejects.toThrow("changed"); expect(http.mock.calls.some(([m]) => m === "PUT")).toBe(false);
  });
  it("obeys GitLab squash policy and blocks unverified approvals", async () => {
    const c = access("gitlab"), http = vi.spyOn(ipc, "http").mockImplementation(async (_m, url) => url.includes("/approvals") ? response({}, 403) : response(url.includes("/merge_requests/1") ? gl : { merge_method: "ff", squash_option: "always" }));
    const expected = await requestLifecycle(c, 1); expect(expected.methods).toEqual(["squash"]); expect(expected.blockers.join(" ")).toContain("approval");
    http.mockImplementation(async (m, url) => response(m === "PUT" ? { state: "merged" } : url.includes("/approvals") ? { approvals_left: 0 } : url.includes("/merge_requests/1") ? gl : { merge_method: "ff", squash_option: "always" }));
    await mergeRequest(c, expected, "squash"); expect(JSON.parse(http.mock.calls.find(([m]) => m === "PUT")![3]!)).toEqual({ sha: "head-a", squash: true, should_remove_source_branch: false });
  });
  it("resolves all GitLab reviewers before writing", async () => {
    const http = vi.spyOn(ipc, "http").mockImplementation(async (_m, url) => response(url.includes("username=one") ? [{ id: 4, username: "one" }] : []));
    await expect(setReviewers(access("gitlab"), 1, ["one", "missing"], [])).rejects.toThrow("not found"); expect(http.mock.calls.some(([m]) => m === "PUT")).toBe(false);
  });
});
describe("repository inbox", () => {
  it("excludes pull requests from assigned issues and retains next-page state", async () => {
    vi.spyOn(ipc, "http").mockResolvedValue(response(Array.from({ length: 30 }, (_, n) => ({ number: n + 1, title: `Issue${n}`, state: "open", ...(n ? {} : { pull_request: {} }) }))));
    const p = await inboxPage(access(), "issue"); expect(p.items).toHaveLength(29); expect(p.more).toBe(true);
  });
  it("filters GitLab todos to the selected repository", async () => {
    const todo = { id: 9, action_name: "mentioned", target_type: "MergeRequest", target_url: "https://gitlab.example/x", body: "Mention", project: { path_with_namespace: "team/repo" }, target: { iid: 7, title: "Review", state: "opened" }, author: { username: "other" } };
    vi.spyOn(ipc, "http").mockResolvedValue(response([todo, { ...todo, project: { path_with_namespace: "elsewhere/repo" } }])); const p = await inboxPage(access("gitlab"), "mention");
    expect(p.items).toHaveLength(1); expect(p.items[0].isRequest).toBe(true); expect(p.items[0].readID).toBe("9");
  });
  it("preserves mention request type for replies and acknowledges todo ids", async () => {
    const c = access("gitlab"), item = { id: "mention-9", kind: "mention" as const, number: 7, title: "Review", url: "https://gitlab.example/x", body: "", state: "MergeRequest", author: "other", unread: true, updated: null, readID: "9", isRequest: true };
    const http = vi.spyOn(ipc, "http").mockImplementation(async (m, url) => response(m === "POST" ? {} : url.includes("/notes?") ? [{ id: 3, body: "note", author: { username: "other" } }] : { title: "Review", state: "opened", description: "Body" }));
    const d = await inboxDetail(c, item); await postInboxComment(c, d.item, "reply"); expect(http.mock.calls.at(-1)![1]).toContain("/merge_requests/7/notes"); await markInboxRead(c, item); expect(http.mock.calls.at(-1)![1]).toContain("/todos/9/mark_as_done");
  });
});
describe("GitHub review threads", () => {
  it("paginates thread identities and resolves GraphQL ids", async () => {
    const c = access(), http = vi.spyOn(ipc, "http").mockImplementation(async (_m, _url, _h, body) => { const b = JSON.parse(body!); return response(b.query.startsWith("mutation") ? { data: { resolveReviewThread: { thread: { id: "PRRT_1", isResolved: true } } } } : { data: { repository: { pullRequest: { reviewThreads: { nodes: [{ id: b.variables.after ? "PRRT_2" : "PRRT_1", isResolved: false, viewerCanResolve: true, comments: { nodes: [{ databaseId: b.variables.after ? 2 : 1 }] } }], pageInfo: { hasNextPage: !b.variables.after, endCursor: "next" } } } } } }); });
    expect((await githubReviewThreads(c, 1)).size).toBe(2); await resolveGithubThread(c, "PRRT_1", true); expect(JSON.parse(http.mock.calls.at(-1)![3]!).variables.id).toBe("PRRT_1");
  });
  it("reports GraphQL errors and rejects REST comment ids", async () => {
    vi.spyOn(ipc, "http").mockResolvedValue(response({ errors: [{ message: "No permission" }] })); await expect(githubReviewThreads(access(), 1)).rejects.toThrow("No permission"); await expect(resolveGithubThread(access(), "123", true)).rejects.toThrow("Refresh");
  });
});
