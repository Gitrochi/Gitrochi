import { afterEach, describe, expect, it, vi } from "vitest";
// the CI entity brings its status icon, and with it the theme, which asks for the colour scheme
vi.hoisted(() => vi.stubGlobal("matchMedia", () => ({ matches: false, addEventListener() {}, removeEventListener() {} })));
import { ipc } from "@/shared/api";
import { ledgerRequestLink, requestPollMs, summarizeRequestChecks, suggestsRequestMerged } from "@/widgets/ledger-workspace/lib/request-status";
import { type LedgerRequestHost, LedgerRequestStatusStore } from "@/widgets/ledger-workspace/model/request-status";
import { session } from "./ledger-fixtures";

afterEach(() => vi.restoreAllMocks());

const repo = { path: "C:/work/atlas", project: "atlas", target: { host: "example.com", path: "team/atlas" } };
const pr = (over: Partial<{ host: string; number: number; url: string }> = {}) => ({ host: "example.com", number: 142, url: "https://example.com/team/atlas/pull/142", ...over });

describe("the request a session links to", () => {
  it("is read only in the open repository's hosting project", () => {
    const linked = session({ links: { repoPath: "C:\\Work\\atlas\\", pr: pr() } });
    expect(ledgerRequestLink(linked, repo)).toEqual({ host: "example.com", path: "team/atlas", number: 142, key: "example.com/team/atlas#142" });
    // GitLab addresses keep the project path before /-/merge_requests
    expect(ledgerRequestLink(session({ links: { repoPath: repo.path, pr: pr({ url: "https://example.com/team/atlas/-/merge_requests/7", number: 7 }) } }), repo)?.number).toBe(7);
    // without a folder, the session's project must be the repository's
    expect(ledgerRequestLink(session({ project: "atlas", links: { pr: pr() } }), repo)).not.toBeNull();
    expect(ledgerRequestLink(session({ project: "harbor", links: { pr: pr() } }), repo)).toBeNull();
  });

  it("is nothing for another repository, another host or project, or with no host configured", () => {
    expect(ledgerRequestLink(session({ links: { repoPath: "C:/work/harbor", pr: pr() } }), repo)).toBeNull();
    expect(ledgerRequestLink(session({ links: { repoPath: repo.path, pr: pr({ host: "other.example.com", url: "https://other.example.com/team/atlas/pull/142" }) } }), repo)).toBeNull();
    expect(ledgerRequestLink(session({ links: { repoPath: repo.path, pr: pr({ url: "https://example.com/team/atlas-fork/pull/142" }) } }), repo)).toBeNull();
    expect(ledgerRequestLink(session({ links: { repoPath: repo.path, pr: pr({ url: "not a url" }) } }), repo)).toBeNull();
    expect(ledgerRequestLink(session({ links: { repoPath: repo.path, pr: pr() } }), { ...repo, target: null })).toBeNull();
    expect(ledgerRequestLink(session({ links: { repoPath: repo.path, pr: pr() } }), { ...repo, path: null })).toBeNull();
    expect(ledgerRequestLink(session({ links: { repoPath: repo.path } }), repo)).toBeNull();
  });
});

describe("the checks summary", () => {
  it("fails on any failure, waits on anything running, and passes otherwise", () => {
    expect(summarizeRequestChecks([{ status: "success" }, { status: "failed" }, { status: "running" }])).toEqual({ state: "failing", count: 1 });
    expect(summarizeRequestChecks([{ status: "success" }, { status: "canceled" }])).toEqual({ state: "failing", count: 1 });
    expect(summarizeRequestChecks([{ status: "success" }, { status: "pending" }, { status: "waiting" }])).toEqual({ state: "pending", count: 2 });
    expect(summarizeRequestChecks([{ status: "success" }, { status: "skipped" }, { status: "neutral" }, { status: "failed", allowFailure: true }])).toEqual({ state: "passing", count: 4 });
  });

  it("is nothing when no check counts", () => {
    expect(summarizeRequestChecks([])).toBeNull();
    expect(summarizeRequestChecks([{ status: "manual" }, { status: "unknown" }])).toBeNull();
  });
});

describe("the merged suggestion and polling", () => {
  it("suggests Mark merged… only for a merged request of a session that is not finished", () => {
    const merged = { state: "merged" as const, checks: null };
    expect(suggestsRequestMerged(session({ status: "active" }), merged)).toBe(true);
    expect(suggestsRequestMerged(session({ status: "done" }), merged)).toBe(true);
    for (const status of ["merged", "closed", "dropped"] as const) expect(suggestsRequestMerged(session({ status }), merged)).toBe(false);
    expect(suggestsRequestMerged(session(), { state: "open", checks: null })).toBe(false);
    expect(suggestsRequestMerged(session(), null)).toBe(false);
  });

  it("reads again no faster than the request checks panel", () => {
    expect(requestPollMs({ state: "open", checks: { state: "pending", count: 1 } })).toBe(20_000);
    expect(requestPollMs({ state: "draft", checks: { state: "passing", count: 3 } })).toBe(120_000);
    expect(requestPollMs({ state: "open", checks: null })).toBe(120_000);
    expect(requestPollMs({ state: "merged", checks: { state: "pending", count: 1 } })).toBeNull();
    expect(requestPollMs({ state: "closed", checks: null })).toBeNull();
    expect(requestPollMs(null)).toBeNull();
  });
});

describe("the request status cache", () => {
  const target = { provider: "github" as const, remote: "origin", host: "example.com", path: "team/atlas" };
  const host = (over: Partial<LedgerRequestHost> = {}): LedgerRequestHost => ({
    path: repo.path, target, hostingAccount: { id: "fixture" },
    workspaceAccess: async () => ({ target, token: "fixture-token", apiBase: "https://api.example.com", me: "fixture" }), ...over,
  });
  const link = { host: "example.com", path: "team/atlas", number: 142, key: "example.com/team/atlas#142" };
  const github = (pull: object) => vi.spyOn(ipc, "http").mockImplementation(async (_method, url) => {
    if (url.endsWith("/pulls/142")) return { status: 200, body: JSON.stringify({ number: 142, state: "closed", merged: false, draft: false, head: { sha: "abc123" }, ...pull }) };
    if (url.includes("/check-runs")) return { status: 200, body: JSON.stringify({ total_count: 2, check_runs: [{ id: 1, name: "test", status: "completed", conclusion: "success" }, { id: 2, name: "lint", status: "in_progress" }] }) };
    if (url.includes("/status")) return { status: 200, body: JSON.stringify({ total_count: 0, statuses: [] }) };
    return { status: 404, body: "{}" };
  });

  it("reads the state and checks once, then keeps them while fresh", async () => {
    let now = 1_000_000;
    const http = github({ state: "open", draft: true });
    const cache = new LedgerRequestStatusStore(() => now);
    await Promise.all([cache.refresh(link, host()), cache.refresh(link, host())]);
    expect(cache.status(link)).toEqual({ state: "draft", checks: { state: "pending", count: 1 } });
    const reads = http.mock.calls.length;
    expect(reads).toBe(3);
    // the request's headers carry the existing account's token and nothing else is asked
    expect(http.mock.calls.every(([method, url]) => method === "GET" && url.startsWith("https://api.example.com/repos/team/atlas/"))).toBe(true);
    now += 30_000;
    await cache.refresh(link, host());
    expect(http.mock.calls.length).toBe(reads);
    now += 31_000;
    await cache.refresh(link, host());
    expect(http.mock.calls.length).toBe(reads * 2);
  });

  it("reports a merged request and leaves nothing behind on failure", async () => {
    github({ merged: true, merged_at: "2026-11-01T00:00:00Z" });
    const cache = new LedgerRequestStatusStore(() => 5_000_000);
    await cache.refresh(link, host());
    expect(cache.status(link)?.state).toBe("merged");

    vi.restoreAllMocks();
    const failing = vi.spyOn(ipc, "http").mockResolvedValue({ status: 500, body: "{}" });
    const other = new LedgerRequestStatusStore(() => 5_000_000);
    await other.refresh(link, host());
    await other.refresh(link, host());
    expect(other.status(link)).toBeNull();
    expect(failing).toHaveBeenCalledTimes(1);
  });

  it("asks nothing without access or for another repository's request", async () => {
    const http = vi.spyOn(ipc, "http");
    const cache = new LedgerRequestStatusStore();
    await cache.refresh(link, host({ workspaceAccess: async () => null }));
    await cache.refresh({ ...link, path: "team/harbor", key: "example.com/team/harbor#142" }, host());
    expect(http).not.toHaveBeenCalled();
    expect(cache.status(link)).toBeNull();
  });
});
