import { afterEach, describe, expect, it, vi } from "vitest";
import {
  accountWorkPage,
  accountWorkOrigin,
  markAccountWorkRead,
  type ReviewAccess,
} from "@/entities/hosting";
import { ipc } from "@/shared/api";
const access = (provider: "github" | "gitlab" = "github"): ReviewAccess => ({
  target: {
    provider,
    remote: "",
    host: provider === "github" ? "github.com" : "gitlab.example",
    path: "",
  },
  token: "fixture",
  apiBase:
    provider === "github"
      ? "https://api.github.com"
      : "https://gitlab.example/api/v4",
  me: "selected-account",
});
const response = (o: unknown) => ({ status: 200, body: JSON.stringify(o) });
afterEach(() => vi.restoreAllMocks());
describe("selected-account work without a local repository", () => {
  it("loads GitHub notifications across repositories and uses safe external details", async () => {
    const http = vi.spyOn(ipc, "http").mockResolvedValue(
      response([
        {
          id: "14",
          unread: true,
          subject: {
            title: "Review",
            type: "PullRequest",
            url: "https://api.github.com/repos/team/other/pulls/9",
          },
          repository: { full_name: "team/other" },
        },
        {
          id: "15",
          unread: true,
          subject: {
            title: "Release",
            type: "Release",
            url: "https://api.github.com/repos/team/other/releases/10",
          },
          repository: { full_name: "team/other" },
        },
      ]),
    );
    const r = await accountWorkPage(access(), "inbox");
    expect(http.mock.calls[0][1]).toContain(
      "https://api.github.com/notifications?",
    );
    expect(r.items[0].repository).toBe("team/other");
    expect(r.items[0].url).toBe("https://github.com/team/other/pull/9");
    expect(r.items[1].url).toBe("https://github.com/team/other");
    expect(r.items[1].number).toBe(0);
  });
  it("uses only the selected GitHub account in authored/assigned/review search", async () => {
    const http = vi.spyOn(ipc, "http").mockResolvedValue(
      response({
        items: [
          {
            id: 1,
            number: 7,
            title: "Across repos",
            html_url: "https://github.com/org/other/pull/7",
            repository_url: "https://api.github.com/repos/org/other",
            state: "open",
          },
        ],
        total_count: 31,
      }),
    );
    for (const [kind, qualifier] of [
      ["mine", "author:"],
      ["assignedRequests", "assignee:"],
      ["review", "review-requested:"],
      ["issues", "assignee:"],
      ["myIssues", "author:"],
    ] as const) {
      const r = await accountWorkPage(access(), kind, 1);
      expect(
        new URL(http.mock.calls.at(-1)![1]).searchParams.get("q"),
      ).toContain(`${qualifier}selected-account`);
      expect(r.items[0].repository).toBe("org/other");
      expect(r.more).toBe(true);
    }
  });
  it("uses GitLab todos and keeps items only on the chosen server", async () => {
    vi.spyOn(ipc, "http").mockResolvedValue(
      response([
        {
          id: 21,
          target_type: "MergeRequest",
          target_url: "https://gitlab.example/group/other/-/merge_requests/4",
          target: { iid: 4, title: "Review" },
          project: { path_with_namespace: "group/other" },
        },
        {
          id: 22,
          target_url: "https://other.example/group/repo/-/issues/2",
          project: { path_with_namespace: "group/repo" },
        },
      ]),
    );
    const r = await accountWorkPage(access("gitlab"), "inbox");
    expect(r.items).toHaveLength(1);
    expect(r.items[0].readID).toBe("21");
    expect(r.items[0].unread).toBe(true);
  });
  it("filters GitLab global requests and issues by the requested account role", async () => {
    const http = vi.spyOn(ipc, "http").mockResolvedValue(response([]));
    await accountWorkPage(access("gitlab"), "mine");
    expect(new URL(http.mock.calls.at(-1)![1]).searchParams.get("scope")).toBe(
      "created_by_me",
    );
    await accountWorkPage(access("gitlab"), "assignedRequests");
    expect(new URL(http.mock.calls.at(-1)![1]).searchParams.get("scope")).toBe(
      "assigned_to_me",
    );
    await accountWorkPage(access("gitlab"), "review");
    expect(
      new URL(http.mock.calls.at(-1)![1]).searchParams.get("reviewer_username"),
    ).toBe("selected-account");
    await accountWorkPage(access("gitlab"), "myIssues");
    expect(http.mock.calls.at(-1)![1]).toContain("/issues?");
  });
  it("rejects cross-server detail URLs and repository API references", async () => {
    vi.spyOn(ipc, "http").mockResolvedValue(
      response({
        items: [
          {
            id: 1,
            number: 2,
            title: "Wrong",
            html_url: "https://github.com.evil.example/repo/issue/2",
            repository_url: "https://api.github.com/repos/org/repo",
          },
          {
            id: 2,
            number: 3,
            title: "Wrong",
            html_url: "https://github.com/org/repo/issues/3",
            repository_url: "https://evil.example/repos/org/repo",
          },
        ],
        total_count: 2,
      }),
    );
    expect((await accountWorkPage(access(), "mine")).items).toEqual([]);
  });
  it("marks only selected-server notifications read and stops stale contexts", async () => {
    const http = vi
      .spyOn(ipc, "http")
      .mockResolvedValue({ status: 204, body: "" });
    const item = {
      id: "inbox-14-org/repo",
      title: "Fixture",
      repository: "org/repo",
      host: "github.com",
      url: "https://github.com/org/repo/issues/2",
      number: 2,
      state: "open",
      author: "",
      unread: true,
      readID: "14",
      origin: accountWorkOrigin(access()),
    };
    await markAccountWorkRead(access(), item);
    expect(http.mock.calls[0][0]).toBe("PATCH");
    expect(http.mock.calls[0][1]).toBe(
      "https://api.github.com/notifications/threads/14",
    );
    await expect(
      markAccountWorkRead(access(), { ...item, host: "elsewhere" }),
    ).rejects.toThrow();
    await expect(
      accountWorkPage({ ...access(), stillCurrent: () => false }, "inbox"),
    ).rejects.toThrow("changed");
    expect(http).toHaveBeenCalledTimes(1);
  });
  it("does not send old-account notification IDs with another account on the same server", async () => {
    const c = access();
    const http = vi
      .spyOn(ipc, "http")
      .mockResolvedValue(
        response([
          {
            id: "14",
            unread: true,
            subject: {
              title: "Old account",
              type: "Issue",
              url: "https://api.github.com/repos/org/repo/issues/2",
            },
            repository: { full_name: "org/repo" },
          },
        ]),
      );
    const { items } = await accountWorkPage(c, "inbox", 1, "profile-a");
    http.mockClear();
    await expect(
      markAccountWorkRead({ ...c, me: "another-user" }, items[0], "profile-b"),
    ).rejects.toThrow("Invalid notification");
    await expect(markAccountWorkRead(c, items[0], "profile-b")).rejects.toThrow(
      "Invalid notification",
    );
    await expect(
      markAccountWorkRead(
        { ...c, apiBase: "https://other.example/api" },
        items[0],
        "profile-a",
      ),
    ).rejects.toThrow("Invalid notification");
    await expect(
      markAccountWorkRead(
        { ...c, target: { ...c.target, provider: "gitlab" } },
        items[0],
        "profile-a",
      ),
    ).rejects.toThrow("Invalid notification");
    expect(http).not.toHaveBeenCalled();
  });
});
