import { afterEach, describe, expect, it, vi } from "vitest";
vi.hoisted(() =>
  vi.stubGlobal("matchMedia", () => ({
    matches: false,
    addEventListener() {},
  })),
);
vi.mock("@/entities/terminal", () => ({ TerminalSession: class {} }));
import {
  accounts,
  issuePage,
  saveWorkspaceIssue,
  searchWorkspaceRepositories,
  workspaceJobLog,
  redactWorkspaceLog,
  type ReviewAccess,
} from "@/entities/hosting";
import { RepoStore } from "@/entities/repo";
import { ipc } from "@/shared/api";
const access = (provider: "github" | "gitlab" = "github"): ReviewAccess => ({
  target: {
    provider,
    host: `${provider}.example`,
    path: "team/repo",
    remote: "origin",
  },
  token: "fixture-token",
  apiBase: `https://${provider}.example/api`,
  me: "me",
});
const response = (o: unknown) => ({ status: 200, body: JSON.stringify(o) });
afterEach(() => vi.restoreAllMocks());
describe("workspace issues and repositories", () => {
  it("searches GitHub issues server-side within the selected repository and state", async () => {
    const http = vi.spyOn(ipc, "http").mockResolvedValue(
      response({
        items: [
          {
            number: 7,
            title: "Found",
            state: "closed",
            user: { login: "me" },
          },
        ],
        total_count: 70,
      }),
    );
    const p = await issuePage(access(), "closed", 'fix" repo:other', 2);
    const q = new URL(http.mock.calls[0][1]).searchParams;
    expect(q.get("q")).toContain(
      'repo:team/repo is:issue is:closed "fix  repo:other"',
    );
    expect(q.get("page")).toBe("2");
    expect(p.more).toBe(true);
    expect(p.items[0].number).toBe(7);
  });
  it("filters GitHub pull requests from all-issue lists and preserves pagination", async () => {
    vi.spyOn(ipc, "http").mockResolvedValue(
      response(
        Array.from({ length: 30 }, (_, i) => ({
          number: i + 1,
          title: "Issue",
          state: "open",
          ...(i ? {} : { pull_request: {} }),
        })),
      ),
    );
    const p = await issuePage(access(), "all");
    expect(p.items).toHaveLength(29);
    expect(p.more).toBe(true);
  });
  it("uses GitLab issue states/search and URL-encodes the project", async () => {
    const http = vi.spyOn(ipc, "http").mockResolvedValue(
      response([
        {
          iid: 4,
          title: "Task",
          description: "body",
          state: "opened",
          author: { username: "me" },
        },
      ]),
    );
    const p = await issuePage(access("gitlab"), "open", "nested task", 3);
    const u = new URL(http.mock.calls[0][1]);
    expect(u.pathname).toContain("team%2Frepo/issues");
    expect(u.searchParams.get("state")).toBe("opened");
    expect(u.searchParams.get("search")).toBe("nested task");
    expect(p.items[0].body).toBe("body");
  });
  it("creates and edits issues using each provider's method and body", async () => {
    const http = vi
      .spyOn(ipc, "http")
      .mockResolvedValue(response({ iid: 8, title: "Saved", state: "opened" }));
    await saveWorkspaceIssue(access("gitlab"), " New ", "Description");
    expect(http.mock.calls[0][0]).toBe("POST");
    expect(JSON.parse(http.mock.calls[0][3]!)).toEqual({
      title: "New",
      description: "Description",
    });
    await saveWorkspaceIssue(access(), "Edit", "Body", 8);
    expect(http.mock.calls[1][0]).toBe("PATCH");
    expect(http.mock.calls[1][1]).toContain("/issues/8");
    expect(JSON.parse(http.mock.calls[1][3]!)).toEqual({
      title: "Edit",
      body: "Body",
    });
  });
  it("blocks invalid titles, issue numbers, and stale contexts before writing", async () => {
    const http = vi.spyOn(ipc, "http");
    await expect(saveWorkspaceIssue(access(), " ", "body")).rejects.toThrow();
    await expect(
      saveWorkspaceIssue(access(), "Title", "body", -1),
    ).rejects.toThrow();
    await expect(
      saveWorkspaceIssue(
        { ...access(), stillCurrent: () => false },
        "Title",
        "body",
      ),
    ).rejects.toThrow("changed");
    expect(http).not.toHaveBeenCalled();
  });
  it("searches only the explicitly chosen server and pages results", async () => {
    const http = vi.spyOn(ipc, "http").mockResolvedValue(
      response({
        items: [
          {
            full_name: "team/remote",
            clone_url: "https://github.example/team/remote.git",
            private: true,
          },
        ],
        total_count: 31,
      }),
    );
    const p = await searchWorkspaceRepositories(access(), "team repo", 1);
    expect(new URL(http.mock.calls[0][1]).origin).toBe(
      "https://github.example",
    );
    expect(new URL(http.mock.calls[0][1]).searchParams.get("q")).toBe(
      "team repo",
    );
    expect(p.items[0].isPrivate).toBe(true);
    expect(p.more).toBe(true);
  });
  it("lists GitLab membership for an empty search and searches without membership for explicit queries", async () => {
    const http = vi.spyOn(ipc, "http").mockResolvedValue(response([]));
    await searchWorkspaceRepositories(access("gitlab"), "");
    expect(new URL(http.mock.calls[0][1]).searchParams.get("membership")).toBe(
      "true",
    );
    await searchWorkspaceRepositories(access("gitlab"), "mobile");
    expect(new URL(http.mock.calls[1][1]).searchParams.has("membership")).toBe(
      false,
    );
  });
});
describe("workspace job logs", () => {
  it("uses bounded native fetch and redacts token, ANSI and common credentials before copying/display", async () => {
    const log = vi.spyOn(ipc, "ciLog").mockResolvedValue({
      body: "\x1b[31mfixture-token\x1b[0m\nAuthorization: Bearer leaked\npassword=abc\nghp_abcdefghijklmnopqrstu",
      truncated: true,
    });
    const result = await workspaceJobLog(access(), 9);
    expect(log).toHaveBeenCalledWith(
      "github",
      "https://github.example/api",
      "team/repo",
      9,
      "fixture-token",
    );
    expect(result.body).not.toContain("fixture-token");
    expect(result.body).not.toContain("leaked");
    expect(result.body).not.toContain("abc");
    expect(result.body).not.toContain("ghp_");
    expect(result.body).not.toContain("\x1b");
    expect(result.truncated).toBe(true);
  });
  it("ignores a log returned after the repository context changed", async () => {
    let current = true;
    vi.spyOn(ipc, "ciLog").mockImplementation(async () => {
      current = false;
      return { body: "late", truncated: false };
    });
    await expect(
      workspaceJobLog({ ...access(), stillCurrent: () => current }, 1),
    ).rejects.toThrow("changed");
  });
  it("does not change harmless job output", () =>
    expect(redactWorkspaceLog("build passed\n2 tests")).toBe(
      "build passed\n2 tests",
    ));
});

describe("CI log credential variants", () => {
  it("masks quoted JSON keys and escaped secret values while retaining valid JSON", () => {
    const value = redactWorkspaceLog(
      JSON.stringify({
        password: 'escaped"secret',
        API_TOKEN: "json-token",
        database_secret: "secret with spaces",
        normal: "keep",
      }),
    );
    expect(JSON.parse(value)).toEqual({
      password: "[redacted]",
      API_TOKEN: "[redacted]",
      database_secret: "[redacted]",
      normal: "keep",
    });
  });
  it("masks environment suffix keys and single-quoted values", () => {
    const value = redactWorkspaceLog(
      "MY_SECRET=secret-one\nDB_PASSWORD = 'secret with spaces'\nPIPELINE_ACCESS_TOKEN=another-token\nNORMAL=keep",
    );
    expect(value).not.toContain("secret-one");
    expect(value).not.toContain("secret with spaces");
    expect(value).not.toContain("another-token");
    expect(value).toContain("NORMAL=keep");
  });
  it("masks complete and truncated PEM private keys without removing public keys", () => {
    const publicKey =
      "-----BEGIN PUBLIC KEY-----\npublic-material\n-----END PUBLIC KEY-----";
    for (const kind of [
      "PRIVATE KEY",
      "RSA PRIVATE KEY",
      "EC PRIVATE KEY",
      "DSA PRIVATE KEY",
      "OPENSSH PRIVATE KEY",
      "ENCRYPTED PRIVATE KEY",
      "PGP PRIVATE KEY BLOCK",
    ]) {
      const value = redactWorkspaceLog(
        `-----BEGIN ${kind}-----\nprivate-material\n-----END ${kind}-----\n${publicKey}`,
      );
      expect(value).not.toContain("private-material");
      expect(value).toContain(publicKey);
      expect(redactWorkspaceLog(`-----BEGIN ${kind}-----\ntruncated-private-material`)).toBe("[redacted private key]");
    }
  });
  it("removes ANSI before matching the connected token", () =>
    expect(redactWorkspaceLog("fi\x1b[31mxture-token", "fixture-token")).toBe(
      "[redacted]",
    ));
});
describe("workspace account epochs", () => {
  it("does not return access if the same repository was reset while a token loaded", async () => {
    const store = new RepoStore();
    store.path = "fixture";
    store.target = access().target;
    Object.defineProperty(store, "hostingAccount", {
      get: () => ({
        id: "fixture",
        provider: "github",
        server: "https://github.com",
        username: "me",
      }),
    });
    let release: (v: string) => void = () => {};
    vi.spyOn(accounts, "token").mockImplementation(
      () =>
        new Promise((resolve) => {
          release = resolve;
        }),
    );
    const pending = store.workspaceAccess();
    (store as unknown as { resetState: () => void }).resetState();
    release("token");
    expect(await pending).toBeNull();
  });
});
