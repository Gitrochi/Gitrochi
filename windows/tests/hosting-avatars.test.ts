import { afterEach, describe, expect, it, vi } from "vitest";
import { avatarURL, createPullRequest, inboxDetail, inboxPage, issuePage, requestPage, ReviewAPI, type InboxItem, type ReviewAccess } from "@/entities/hosting";
import type { RepoStore } from "@/entities/repo";
import { ipc } from "@/shared/api";
import { ownAvatarURL } from "@/widgets/inspector/lib/own-avatar";

const access = (provider: "github" | "gitlab" = "github"): ReviewAccess => ({ target: { provider, host: `${provider}.example.com`, path: "team/repo", remote: "origin" }, token: "fixture", apiBase: `https://${provider}.example.com/api`, me: "reviewer" });
const response = (value: unknown) => ({ status: 200, body: JSON.stringify(value) });
const photo = "https://avatars.githubusercontent.com/u/42?s=64";
const ghPull = { number: 7, title: "Request", body: "Description", user: { login: "author", avatar_url: photo }, head: { ref: "work", sha: "head", repo: { full_name: "team/repo" } }, base: { ref: "main", sha: "base" }, html_url: "https://github.example.com/team/repo/pull/7", state: "open" };
const notification: InboxItem = { id: "mention-1", kind: "mention", number: 7, title: "Issue", body: "", url: "", state: "Issue", updated: null, author: "", unread: true };
afterEach(() => vi.restoreAllMocks());

describe("hosting profile avatars", () => {
  it("accepts photos from the connected host and known CDNs, including GitLab relative photos", () => {
    expect(avatarURL(access(), photo)).toBe(photo);
    expect(avatarURL(access("gitlab"), "/uploads/profile.png")).toBe("https://gitlab.example.com/uploads/profile.png");
    for (const url of ["http://github.example.com/photo.png", "https://elsewhere.example.com/photo.png", "//elsewhere.example.com/photo.png", "https://user:password@github.example.com/photo.png", "data:image/png;base64,eA=="]) expect(avatarURL(access(), url)).toBeNull();
    expect(avatarURL(access("gitlab"), photo)).toBeNull();
  });

  it("retains each GitHub pull author photo for both list and creation responses without extra API requests", async () => {
    const http = vi.spyOn(ipc, "http").mockImplementation(async method => response(method === "POST" ? ghPull : [ghPull]));
    expect((await requestPage(access(), { scope: "open", search: "", page: 1 })).items[0].authorAvatarURL).toBe(photo);
    expect((await createPullRequest(access().target, "fixture", access().apiBase, { title: "Request", body: "", source: "work", target: "main", draft: false })).authorAvatarURL).toBe(photo);
    expect(http).toHaveBeenCalledTimes(2);
  });

  it("retains GitLab merge request author photos on the connected host", async () => {
    vi.spyOn(ipc, "http").mockResolvedValue(response([{ iid: 7, title: "Request", author: { username: "author", avatar_url: "/uploads/author.png" }, source_branch: "work", target_branch: "main", sha: "head", web_url: "https://gitlab.example.com/team/repo/-/merge_requests/7", state: "opened" }]));
    expect((await requestPage(access("gitlab"), { scope: "open", search: "", page: 1 })).items[0].authorAvatarURL).toBe("https://gitlab.example.com/uploads/author.png");
  });

  it("keeps issue photos in assigned and workspace lists, then refreshes blank notification authors and comments", async () => {
    const issue = { number: 7, title: "Issue", body: "Description", state: "open", user: { login: "author", avatar_url: photo } };
    vi.spyOn(ipc, "http").mockImplementation(async (_method, url) => response(url.includes("/comments?") ? [{ id: 9, body: "Reply", user: { login: "reply-author", avatar_url: "https://avatars.githubusercontent.com/u/43" } }] : url.endsWith("/issues/7") ? issue : [issue]));
    expect((await inboxPage(access(), "issue")).items[0].authorAvatarURL).toBe(photo);
    expect((await issuePage(access(), "open")).items[0].authorAvatarURL).toBe(photo);
    const detail = await inboxDetail(access(), notification);
    expect(detail.item).toMatchObject({ author: "author", authorAvatarURL: photo });
    expect(detail.comments[0]).toMatchObject({ author: "reply-author", authorAvatarURL: "https://avatars.githubusercontent.com/u/43" });
  });

  it("preserves photos in GitHub comments, line threads and submitted reviews", async () => {
    vi.spyOn(ipc, "http").mockImplementation(async (_method, url) => {
      if (url.endsWith("/pulls/7")) return response(ghPull);
      if (url.includes("/reviews?")) return response([{ id: 3, state: "APPROVED", body: "Ready", user: { login: "reviewer", avatar_url: photo } }]);
      if (url.includes("/files?")) return response([]);
      if (url.includes("/comments?")) return response([{ id: 1, body: "Comment", path: "file.ts", line: 1, user: { login: "author", avatar_url: photo } }]);
      return response({});
    });
    const review = await ReviewAPI.load(access(), 7);
    expect(review.comments).toHaveLength(3);
    expect(review.comments.every(comment => comment.authorAvatarURL === photo)).toBe(true);
  });

  it("preserves GitLab discussion authors and rejects unexpected image hosts", async () => {
    vi.spyOn(ipc, "http").mockImplementation(async (_method, url) => response(url.includes("/discussions?") ? [{ id: "thread", notes: [{ id: 1, body: "Safe", author: { username: "author", avatar_url: "/uploads/photo.png" } }, { id: 2, body: "Fallback", author: { username: "other", avatar_url: "https://elsewhere.example.com/photo.png" } }] }] : url.includes("/diffs?") ? [] : url.endsWith("/approvals") ? {} : { diff_refs: { head_sha: "head", base_sha: "base", start_sha: "base" } }));
    const review = await ReviewAPI.load(access("gitlab"), 7);
    expect(review.comments.map(comment => comment.authorAvatarURL)).toEqual(["https://gitlab.example.com/uploads/photo.png", null]);
  });

  it("uses the author's response photo first and derives public GitHub profiles only for that host", () => {
    const store = { target: { ...access().target, host: "github.com" }, hostingAccount: { username: "author", avatarURL: "https://avatars.githubusercontent.com/u/1" } } as RepoStore;
    expect(ownAvatarURL(store, "author", photo)).toBe(photo);
    expect(ownAvatarURL(store, "AUTHOR")).toBe("https://avatars.githubusercontent.com/u/1");
    expect(ownAvatarURL(store, "other")).toBe("https://github.com/other.png?size=64");
    expect(ownAvatarURL(store, "../other")).toBeNull();
    store.target = access("gitlab").target;
    expect(ownAvatarURL(store, "other")).toBeNull();
    expect(ownAvatarURL(store, "other", "https://gitlab.example.com/uploads/photo.png")).toBe("https://gitlab.example.com/uploads/photo.png");
    store.target = { ...access().target, host: "enterprise.example.com" };
    expect(ownAvatarURL(store, "other")).toBeNull();
  });
});
