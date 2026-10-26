import { afterEach, describe, expect, it, vi } from "vitest";
import { CIAPI, type CIAccess } from "../src/entities/ci/api/ci-api";
import { ipc } from "@/shared/api";

const access = (provider: "github" | "gitlab" = "github"): CIAccess => ({ target: { provider, host: provider === "github" ? "github.com" : "gitlab.example.com", path: "team/repo", remote: "origin" }, apiBase: provider === "github" ? "https://api.github.com" : "https://gitlab.example.com/api/v4", token: "fixture-only" });
const response = (value: unknown) => ({ status: 200, body: JSON.stringify(value) });
afterEach(() => vi.restoreAllMocks());

describe("request commit checks and CI runs", () => {
  it("loads external check runs and commit statuses independently of Actions", async () => {
    const http = vi.spyOn(ipc, "http").mockImplementation(async (_method, url) => response(url.includes("/check-runs?") ? {
      total_count: 2, check_runs: [{ id: 1, name: "External analysis", status: "completed", conclusion: "failure", details_url: "https://ci.example.com/result/1", output: { title: "Type check failed" } }],
    } : { total_count: 2, statuses: [{ id: 2, context: "Deploy preview", state: "success", target_url: "https://preview.example.com", description: "Ready" }, { id: 3, context: "Legacy CI", state: "error", target_url: "https://ci.example.com/result/3" }] }));
    const result = await CIAPI.requestChecks(access(), "head123");
    expect(result.checks).toMatchObject([{ id: "check:1", name: "External analysis", status: "failed", url: "https://ci.example.com/result/1", summary: "Type check failed" }, { id: "status:2", status: "success" }, { id: "status:3", status: "failed" }]);
    expect(result.truncated).toBe(true);
    expect(http.mock.calls.every(([method, url]) => method === "GET" && url.includes("/commits/head123/"))).toBe(true);
  });

  it("queries workflow and pipeline runs for the selected commit without a branch filter", async () => {
    const http = vi.spyOn(ipc, "http").mockImplementation(async (_method, url) => response(url.includes("/actions/runs?") ? { workflow_runs: [] } : []));
    await CIAPI.pipelines(access(), null, "selected/head");
    await CIAPI.pipelines(access("gitlab"), null, "selected/head");
    const github = new URL(http.mock.calls[0][1]), gitlab = new URL(http.mock.calls[1][1]);
    expect(github.searchParams.get("head_sha")).toBe("selected/head");
    expect(github.searchParams.has("branch")).toBe(false);
    expect(gitlab.searchParams.get("sha")).toBe("selected/head");
    expect(gitlab.searchParams.has("ref")).toBe(false);
  });

  it("includes the authoritative GitLab merged-result pipeline and uses its fork project for jobs", async () => {
    const http = vi.spyOn(ipc, "http").mockImplementation(async (_method, url) => response(url.includes("/merge_requests/7") ? { head_pipeline: { id: 90, iid: 4, project_id: 42, sha: "merged-result-sha", ref: "refs/merge-requests/7/merge", status: "failed", web_url: "https://gitlab.example.com/fork/repo/-/pipelines/90" } } : url.includes("/jobs?") ? [{ id: 2, name: "Tests", stage: "test", status: "failed", web_url: "https://gitlab.example.com/fork/repo/-/jobs/2" }] : []));
    const runs = await CIAPI.requestPipelines(access("gitlab"), 7, "source-sha");
    expect(runs[0]).toMatchObject({ id: 90, projectID: 42, sha: "merged-result-sha", status: "failed" });
    await CIAPI.jobs(access("gitlab"), runs[0].id, runs[0].projectID);
    expect(http.mock.calls.at(-1)?.[1]).toContain("/projects/42/pipelines/90/jobs?");
    expect(http.mock.calls.some(([, url]) => url.includes("sha=source-sha"))).toBe(true);
  });

  it("preserves GitLab external status result links and descriptions", async () => {
    vi.spyOn(ipc, "http").mockResolvedValue(response([{ id: 9, name: "External tests", status: "running", target_url: "https://ci.example.com/job/9", description: "Integration suite" }]));
    const result = await CIAPI.requestChecks(access("gitlab"), "head123");
    expect(result).toEqual({ checks: [{ id: "status:9", name: "External tests", status: "running", url: "https://ci.example.com/job/9", summary: "Integration suite" }], truncated: false });
  });
});
