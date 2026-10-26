import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
vi.hoisted(() => vi.stubGlobal("matchMedia", () => ({ matches: false, addEventListener() {} })));
vi.mock("@/entities/terminal", () => ({ TerminalSession: class {} }));
import { ReviewAPI, type ReviewAccess, type ReviewDraftComment, type PullRequestReview, reviewRepositoryKey } from "@/entities/hosting";
import { RepoStore } from "@/entities/repo";
import { ipc } from "@/shared/api";

const access = (provider: "github" | "gitlab" = "github"): ReviewAccess => ({ target: { provider, host: `${provider}.example`, path: "team/repo", remote: "origin" }, token: "fixture-token", apiBase: `https://${provider}.example/api`, me: "reviewer" });
const refs = { headSHA: "head-a", baseSHA: "base-a", startSHA: "start-a" };
const ghRefs = { ...refs, startSHA: refs.baseSHA };
const metadata = (c: ReviewAccess, head = refs.headSHA) => c.target.provider === "github" ? { head: { sha: head }, base: { sha: refs.baseSHA } } : { diff_refs: { head_sha: head, base_sha: refs.baseSHA, start_sha: refs.startSHA } };
const draft = (c: ReviewAccess, id: string, side: "LEFT" | "RIGHT" = "RIGHT"): ReviewDraftComment => ({ id, repositoryKey: reviewRepositoryKey(c.target), number: 1, body: `Comment ${id}`, anchor: { ...(c.target.provider === "github" ? ghRefs : refs), path: "src/new.ts", oldPath: "src/old.ts", line: side === "LEFT" ? 2 : 3, side } });
const response = (value: unknown, status = 200) => ({ status, body: JSON.stringify(value) });
const parsed = (body?: string) => body ? JSON.parse(body) : undefined;
let storage: Map<string, string>;
beforeEach(() => {
  storage = new Map();
  vi.stubGlobal("localStorage", { getItem: (k: string) => storage.get(k) ?? null, setItem: (k: string, value: string) => storage.set(k, value) });
});
afterEach(() => vi.restoreAllMocks());

function fixtureReview(c: ReviewAccess): PullRequestReview {
  return { ...(c.target.provider === "github" ? ghRefs : refs), number: 1, repositoryKey: reviewRepositoryKey(c.target), comments: [], warnings: [], files: [{ path: "src/new.ts", oldPath: "src/old.ts", kind: "renamed", additions: 1, deletions: 1, patch: "@@ -1,2 +1,2 @@\n context\n-old\n+new" }], state: { approvedBy: [], changesRequestedBy: [], approvalsLeft: null, approvedByMe: false } };
}
function fixtureStore(c = access()) {
  const s = new RepoStore();
  s.path = "C:/fixture"; s.target = c.target; s.selection = { kind: "pullRequest", number: 1 }; s.review = fixtureReview(c);
  vi.spyOn(s as unknown as { reviewAccess(): Promise<ReviewAccess> }, "reviewAccess").mockResolvedValue(c);
  s.diffSource = { kind: "review", number: 1, change: { path: "src/new.ts", oldPath: "src/old.ts", kind: "renamed", staged: false }, patch: s.review.files[0].patch! };
  return s;
}

describe("paginated PR/MR review data", () => {
  it("loads the second GitHub page of comments, line comments, reviews and files", async () => {
    const c = access();
    const http = vi.spyOn(ipc, "http").mockImplementation(async (_method, url) => {
      const u = new URL(url), page = Number(u.searchParams.get("page"));
      if (!page) return response(metadata(c));
      const ids = page === 1 ? Array.from({ length: 100 }, (_, i) => i + 1) : [101];
      if (u.pathname.endsWith("/files")) return response(ids.map((id) => ({ filename: `file-${id}`, status: "modified", additions: 1, deletions: 0, patch: "@@ -0,0 +1 @@\n+new" })));
      if (u.pathname.endsWith("/reviews")) return response(ids.map((id) => ({ id, state: "COMMENTED", body: `review-${id}`, user: { login: "user" } })));
      return response(ids.map((id) => ({ id, body: `comment-${id}`, user: { login: "user" }, ...(u.pathname.includes("/pulls/") ? { path: "code.ts", line: 1, side: "RIGHT" } : {}) })));
    });
    const review = await ReviewAPI.load(c, 1);
    expect(review.files).toHaveLength(101);
    expect(review.comments).toHaveLength(303);
    expect(review.comments.some((x) => x.id === "l101")).toBe(true);
    for (const endpoint of ["/files", "/reviews", "/comments"]) expect(http.mock.calls.some(([, url]) => url.includes(endpoint) && url.includes("page=2"))).toBe(true);
  });

  it("loads GitLab diff and discussion pages and disables omitted file patches", async () => {
    const c = access("gitlab");
    vi.spyOn(ipc, "http").mockImplementation(async (_method, url) => {
      const u = new URL(url), page = Number(u.searchParams.get("page"));
      if (u.pathname.endsWith("/approvals")) return response({});
      if (!page) return response(metadata(c));
      const ids = page === 1 ? Array.from({ length: 100 }, (_, i) => i + 1) : [101];
      if (u.pathname.endsWith("/diffs")) return response(ids.map((id) => ({ old_path: `file-${id}`, new_path: `file-${id}`, diff: "@@ -1 +1 @@\n-old\n+new", too_large: id === 101 })));
      return response(ids.map((id) => ({ id: `thread-${id}`, notes: [{ id, body: "note", resolvable: true, resolved: false, author: { username: "user" } }] })));
    });
    const review = await ReviewAPI.load(c, 1);
    expect(review.files).toHaveLength(101); expect(review.comments).toHaveLength(101);
    expect(review.files[100].patch).toBeNull(); expect(review.warnings).toHaveLength(1);
    expect(review.comments[100].threadID).toBe("thread-101");
  });
});

describe("review submission safety and recovery", () => {
  it("sends GitHub old/new sides, renamed paths and verdict in one review", async () => {
    const c = access(), writes: unknown[] = [];
    vi.spyOn(ipc, "http").mockImplementation(async (method, url, _headers, body) => {
      if (method === "POST") { writes.push(parsed(body)); return response({}); }
      return response(url.includes("/reviews?") ? [] : metadata(c));
    });
    const completed: string[] = [];
    await ReviewAPI.submit(c, 1, ghRefs, [draft(c, "old", "LEFT"), draft(c, "new")], "Please fix", "REQUEST_CHANGES", (id) => completed.push(id));
    expect(writes).toHaveLength(1);
    expect(writes[0]).toMatchObject({ commit_id: "head-a", event: "REQUEST_CHANGES", comments: [{ path: "src/new.ts", line: 2, side: "LEFT" }, { path: "src/new.ts", line: 3, side: "RIGHT" }] });
    expect(completed).toEqual(["old", "new"]);
  });

  it("reconciles a GitHub review accepted before its response was lost", async () => {
    const c = access(), accepted: { id: number; body: string; state: string }[] = [];
    let posts = 0;
    vi.spyOn(ipc, "http").mockImplementation(async (method, url, _headers, body) => {
      if (method === "POST") { posts++; accepted.push({ id: 1, body: parsed(body).body, state: "COMMENTED" }); throw new Error("response lost"); }
      return response(url.includes("/reviews?") ? accepted : metadata(c));
    });
    const drafts = [draft(c, "pending")], completed: string[] = [];
    await expect(ReviewAPI.submit(c, 1, ghRefs, drafts, "summary", "COMMENT")).rejects.toThrow("response lost");
    await ReviewAPI.submit(c, 1, ghRefs, drafts, "summary", "COMMENT", (id) => completed.push(id));
    expect(posts).toBe(1); expect(completed).toEqual(["pending"]);
  });

  it.each(["github", "gitlab"] as const)("does not clear an edited %s draft after an earlier response was lost", async (provider) => {
    const c = access(provider), accepted: Record<string, unknown>[] = [], postedBodies: string[] = [];
    vi.spyOn(ipc, "http").mockImplementation(async (method, url, _headers, body) => {
      if (method === "GET") return response(url.includes("/reviews?") || url.includes("/discussions?") ? accepted : metadata(c));
      const payload = parsed(body);
      postedBodies.push(provider === "github" ? payload.comments[0].body : payload.body);
      if (provider === "github") accepted.push({ id: accepted.length + 1, state: "COMMENTED", body: payload.body });
      else accepted.push({ id: `thread-${accepted.length}`, notes: [{ id: accepted.length, body: payload.body }] });
      if (accepted.length === 1) throw new Error("lost response");
      return response({});
    });
    const pending = draft(c, "edited"), expected = provider === "github" ? ghRefs : refs;
    await expect(ReviewAPI.submit(c, 1, expected, [pending], "", "COMMENT")).rejects.toThrow();
    pending.body = "Edited text that has not been sent";
    const completed: string[] = [];
    await ReviewAPI.submit(c, 1, expected, [pending], "", "COMMENT", (id) => completed.push(id));
    expect(postedBodies).toHaveLength(2);
    expect(postedBodies[1]).toContain("Edited text that has not been sent");
    expect(completed).toEqual(["edited"]);
  });

  it.each(["DISMISSED", "PENDING"])("does not treat a %s GitHub review as an applied verdict", async (state) => {
    const c = access(), accepted: { id: number; state: string; body: string }[] = [];
    let posts = 0;
    vi.spyOn(ipc, "http").mockImplementation(async (method, url, _headers, body) => {
      if (method === "GET") return response(url.includes("/reviews?") ? accepted : metadata(c));
      posts++; accepted.push({ id: posts, state, body: parsed(body).body }); return response({});
    });
    await ReviewAPI.submit(c, 1, ghRefs, [], "Looks good", "APPROVE");
    await ReviewAPI.submit(c, 1, ghRefs, [], "Looks good", "APPROVE");
    expect(posts).toBe(2);
  });

  it("blocks stale head, base and cross-request drafts before any write", async () => {
    const c = access();
    const http = vi.spyOn(ipc, "http").mockResolvedValue(response(metadata(c, "head-b")));
    await expect(ReviewAPI.submit(c, 1, ghRefs, [draft(c, "a")], "", "COMMENT")).rejects.toThrow("changed");
    expect(http.mock.calls.every(([method]) => method === "GET")).toBe(true);
    http.mockClear();
    await expect(ReviewAPI.submit(c, 2, ghRefs, [draft(c, "a")], "", "COMMENT")).rejects.toThrow("changed");
    expect(http).not.toHaveBeenCalled();
    http.mockResolvedValue(response({ head: { sha: "head-a" }, base: { sha: "base-b" } }));
    await expect(ReviewAPI.submit(c, 1, ghRefs, [], "", "APPROVE")).rejects.toThrow("changed");
  });

  it("preserves unsent GitLab drafts and never duplicates a confirmed or uncertain thread on retry", async () => {
    const c = access("gitlab"), accepted: { id: string; notes: { id: number; body: string }[] }[] = [], positions: unknown[] = [];
    let posts = 0;
    vi.spyOn(ipc, "http").mockImplementation(async (method, url, _headers, body) => {
      if (method === "GET") return response(url.includes("/discussions?") ? accepted : metadata(c));
      posts++;
      const payload = parsed(body); positions.push(payload.position);
      accepted.push({ id: `thread-${posts}`, notes: [{ id: posts, body: payload.body }] });
      if (posts === 2) throw new Error("response lost after accepting second thread");
      return response({});
    });
    const first = draft(c, "first", "LEFT"), second = draft(c, "second"), completed: string[] = [];
    second.anchor.oldLine = 2; second.anchor.newLine = 3;
    await expect(ReviewAPI.submit(c, 1, refs, [first, second], "", "COMMENT", (id) => completed.push(id))).rejects.toThrow("remaining drafts");
    expect(completed).toEqual(["first"]);
    expect(positions[0]).toMatchObject({ old_path: "src/old.ts", new_path: "src/new.ts", old_line: 2, head_sha: "head-a", base_sha: "base-a", start_sha: "start-a" });
    expect(positions[1]).toMatchObject({ new_line: 3, old_line: 2 });
    await ReviewAPI.submit(c, 1, refs, [second], "", "COMMENT", (id) => completed.push(id));
    expect(posts).toBe(2); expect(completed).toEqual(["first", "second"]);
  });
});

describe("review store lifecycle", () => {
  it("adds only a real displayed diff row, scopes drafts and persists edits across reload", () => {
    const store = fixtureStore();
    store.addReviewDraft(1, "src/new.ts", 999, "RIGHT"); expect(store.reviewDrafts).toHaveLength(0);
    store.addReviewDraft(1, "src/new.ts", 2, "LEFT"); expect(store.reviewDrafts).toHaveLength(1);
    const id = store.reviewDrafts[0].id; store.updateReviewDraft(id, "Needs a test");
    expect(new RepoStore().reviewDrafts[0].body).toBe("Needs a test");
    store.addReviewDraft(1, "src/new.ts", 2, "LEFT"); expect(store.reviewDrafts).toHaveLength(1);
    expect(store.reviewDraftsFor(2)).toHaveLength(0);
    store.diffSource = { ...store.diffSource!, patch: "@@ -1 +1 @@\n-old\n+changed" } as typeof store.diffSource;
    store.addReviewDraft(1, "src/new.ts", 2, "RIGHT"); expect(store.reviewDrafts).toHaveLength(1);
  });

  it("keeps drafts on stale server head and removes only confirmed GitLab drafts", async () => {
    const c = access("gitlab"), store = fixtureStore(c);
    store.reviewDrafts = [draft(c, "first"), draft(c, "second")];
    vi.spyOn(ReviewAPI, "submit").mockImplementation(async (_c, _n, _refs, _drafts, _body, _verdict, completed) => { completed!("first"); throw new Error("second failed"); });
    expect(await store.submitReview(1, "")).toBe(false);
    expect(store.reviewDrafts.map((d) => d.id)).toEqual(["second"]);
    expect(store.errorMessage).toContain("second failed");
  });

  it("keeps edits made after reset when the old submission later confirms the original draft", async () => {
    const c = access(), store = fixtureStore(c);
    store.addReviewDraft(1, "src/new.ts", 2, "LEFT");
    const id = store.reviewDrafts[0].id; store.updateReviewDraft(id, "Original text");
    let completeOld!: () => void;
    vi.spyOn(ReviewAPI, "submit").mockImplementation((_c, _n, _refs, _drafts, _body, _verdict, completed) => new Promise((resolve) => {
      completeOld = () => { completed!(id); resolve(); };
    }));
    const posting = store.submitReview(1, ""); await Promise.resolve();
    store.close();
    store.path = "C:/fixture"; store.target = c.target; store.selection = { kind: "pullRequest", number: 1 }; store.review = fixtureReview(c);
    store.updateReviewDraft(id, "New unsent text");
    completeOld(); expect(await posting).toBe(false);
    expect(store.reviewDrafts[0].body).toBe("New unsent text");
    expect(new RepoStore().reviewDrafts[0].body).toBe("New unsent text");
  });

  it("ignores an old request failure after reset and preserves a newer action's busy state", async () => {
    const c = access(), store = fixtureStore(c);
    let rejectOld!: (error: Error) => void, finishNew!: () => void;
    vi.spyOn(ReviewAPI, "submit").mockImplementationOnce(() => new Promise((_resolve, reject) => { rejectOld = reject; }))
      .mockImplementationOnce(() => new Promise((resolve) => { finishNew = resolve; }));
    vi.spyOn(store, "loadReview").mockResolvedValue(undefined);
    const old = store.postReviewComment(1, "old request");
    await Promise.resolve(); expect(store.reviewBusy).toBe(true);
    store.close();
    store.path = "C:/fixture"; store.target = c.target; store.selection = { kind: "pullRequest", number: 1 }; store.review = fixtureReview(c);
    const current = store.postReviewComment(1, "new request");
    await Promise.resolve(); expect(store.reviewBusy).toBe(true);
    rejectOld(new Error("old failure")); expect(await old).toBe(false);
    expect(store.errorMessage).toBeNull(); expect(store.reviewBusy).toBe(true);
    finishNew(); expect(await current).toBe(true); expect(store.reviewBusy).toBe(false);
  });

  it("does not load or write a different request after account lookup finishes late", async () => {
    const c = access(), store = fixtureStore(c);
    let finish!: (value: ReviewAccess) => void;
    vi.mocked((store as unknown as { reviewAccess(): Promise<ReviewAccess> }).reviewAccess).mockImplementation(() => new Promise((resolve) => { finish = resolve; }));
    const load = vi.spyOn(ReviewAPI, "load"), submit = vi.spyOn(ReviewAPI, "submit");
    const loading = store.loadReview(1);
    store.selection = { kind: "pullRequest", number: 2 }; finish(c); await loading;
    expect(load).not.toHaveBeenCalled();
    store.selection = { kind: "pullRequest", number: 1 };
    const posting = store.postReviewComment(1, "body");
    store.path = "C:/different"; store.target = { ...c.target, path: "other/repo" }; finish(c);
    expect(await posting).toBe(false); expect(submit).not.toHaveBeenCalled();
  });
});
