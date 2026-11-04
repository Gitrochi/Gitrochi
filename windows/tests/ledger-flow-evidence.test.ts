import { afterEach, describe, expect, it, vi } from "vitest";
vi.hoisted(() => vi.stubGlobal("matchMedia", () => ({ matches: false, addEventListener() {}, removeEventListener() {} })));
const git = vi.hoisted(() => vi.fn());
vi.mock("@/shared/platform", async (original) => ({ ...(await original<typeof import("@/shared/platform")>()), git }));
import { flowEngine } from "@/entities/flow";
import { flowEvidenceFolders, flowOutcome, latestFlowResults, type LedgerFlowRun, sessionInRepository } from "@/widgets/ledger-workspace/lib/flow-evidence";
import { LedgerFlowEvidenceStore } from "@/widgets/ledger-workspace/model/flow-evidence";
import { session } from "./ledger-fixtures";

afterEach(() => { vi.restoreAllMocks(); git.mockReset(); });

const head = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678";
const run = (runId: string, flow: string, state: string, finishedAt: number | null = 1_000, sha = head): LedgerFlowRun => ({ runId, flow, state, sha, finishedAt });

describe("the Checks row's results", () => {
  it("are the newest finished run of each flow recorded for the branch head", () => {
    const runs = [run("r1", "pre-push", "FAILED", 1_000), run("r2", "pre-push", "SUCCEEDED", 2_000), run("r3", "deploy", "ROLLBACK_FAILED", 1_500), run("r4", "nightly", "SUCCEEDED", 9_000, "ffff"),
      run("r5", "lint", "RUNNING", null), run("r6", "lint", "REJECTED", 500), run("r7", "smoke", "CANCELLED", 400)];
    const latest = latestFlowResults(runs, head.toUpperCase());
    expect(latest.map((r) => r.run.runId)).toEqual(["r2", "r3", "r6", "r7"]);
    expect(latest.map((r) => r.outcome)).toEqual(["passed", "held", "held", "canceled"]);
    expect(latestFlowResults(runs, "")).toEqual([]);
    expect(latestFlowResults(runs, "0000")).toEqual([]);
  });

  it("count only recorded results", () => {
    expect([flowOutcome("SUCCEEDED"), flowOutcome("FAILED"), flowOutcome("ROLLED_BACK"), flowOutcome("REJECTED"), flowOutcome("ROLLBACK_FAILED"), flowOutcome("CANCELLED")]).toEqual(["passed", "failed", "failed", "held", "held", "canceled"]);
    for (const state of ["PENDING", "PREFLIGHT", "RUNNING", "ROLLING_BACK", "SOMETHING_NEW"]) expect(flowOutcome(state)).toBeNull();
  });
});

describe("which sessions and folders", () => {
  const repo = { path: "C:/work/atlas", worktrees: [{ path: "C:/work/atlas-worktrees/fix-retry" }], project: "atlas" };
  it("belong to the open repository or one of its worktrees", () => {
    expect(sessionInRepository(session({ links: { repoPath: "c:\\work\\atlas\\" } }), repo)).toBe(true);
    expect(sessionInRepository(session({ links: { worktree: "C:/work/atlas-worktrees/fix-retry" } }), repo)).toBe(true);
    expect(sessionInRepository(session({ links: { repoPath: "C:/work/harbor" } }), repo)).toBe(false);
    expect(sessionInRepository(session({ project: "atlas", links: { branch: "fix/retry" } }), repo)).toBe(true);
    expect(sessionInRepository(session({ project: "harbor", links: { branch: "fix/retry" } }), repo)).toBe(false);
    expect(sessionInRepository(session({ links: { repoPath: "C:/work/atlas" } }), { ...repo, path: null })).toBe(false);
  });

  it("read the repository and the worktrees that have the branch or that the session names", () => {
    const worktrees = [
      { path: "C:/work/atlas", branch: "main", prunable: false },
      { path: "C:/work/atlas-worktrees/fix-retry", branch: "refs/heads/fix/retry", prunable: false },
      { path: "C:/work/atlas-worktrees/docs", branch: "docs/guide", prunable: false },
      { path: "C:/work/atlas-worktrees/gone", branch: "fix/retry", prunable: true },
    ];
    expect(flowEvidenceFolders("C:/work/atlas", worktrees, "fix/retry")).toEqual(["C:/work/atlas", "C:/work/atlas-worktrees/fix-retry"]);
    expect(flowEvidenceFolders("C:/work/atlas", worktrees, "feature/other", "C:/work/atlas-worktrees/docs")).toEqual(["C:/work/atlas", "C:/work/atlas-worktrees/docs"]);
  });
});

describe("the evidence cache", () => {
  const rows = [
    { runId: "r3", flow: "pre-push", state: "RUNNING", running: true },
    { runId: "r2", flow: "pre-push", state: "SUCCEEDED" },
    { runId: "r1", flow: "deploy", state: "FAILED" },
  ];
  const records: Record<string, Record<string, unknown>> = {
    r2: { runId: "r2", flow: "pre-push", state: "SUCCEEDED", finishedAt: "2026-11-01T10:00:00.000Z", git: { sha: head, branch: "fix/retry", clean: true } },
    r1: { runId: "r1", flow: "deploy", state: "FAILED", finishedAt: "2026-11-01T09:00:00.000Z", git: { sha: "0000", branch: "fix/retry", clean: true } },
  };
  const engine = () => {
    vi.spyOn(flowEngine, "executable").mockResolvedValue("/fixture/gitch-flow");
    const runs = vi.spyOn(flowEngine, "runs").mockResolvedValue(rows);
    const record = vi.spyOn(flowEngine, "record").mockImplementation(async (id) => records[id]);
    git.mockResolvedValue({ status: 0, stdout: `${head}\n`, stderr: "" });
    return { runs, record };
  };

  it("reads the head and each finished record once, through the Flows workspace's engine calls only", async () => {
    const { runs, record } = engine();
    const cache = new LedgerFlowEvidenceStore();
    await cache.refresh("C:/work/atlas", "fix/retry", ["C:/work/atlas"]);
    const evidence = cache.get("C:/work/atlas", "fix/retry");
    expect(evidence?.head).toBe(head);
    expect(evidence?.results.map((r) => [r.run.flow, r.outcome])).toEqual([["pre-push", "passed"]]);
    expect(git).toHaveBeenCalledWith(["rev-parse", "--verify", "--quiet", "refs/heads/fix/retry^{commit}"], "C:/work/atlas", { ok: [0, 1, 128] });
    // a running run is not read; finished records are kept
    expect(record.mock.calls.map(([id]) => id)).toEqual(["r2", "r1"]);
    await cache.refresh("C:/work/atlas", "fix/retry", ["C:/work/atlas"]);
    expect(record).toHaveBeenCalledTimes(2);
    expect(runs).toHaveBeenCalledTimes(2);
  });

  it("shows nothing without the engine or the branch", async () => {
    engine();
    vi.spyOn(flowEngine, "executable").mockResolvedValue(null);
    const cache = new LedgerFlowEvidenceStore();
    await cache.refresh("C:/work/atlas", "fix/retry", ["C:/work/atlas"]);
    expect(cache.get("C:/work/atlas", "fix/retry")).toBeNull();
    vi.spyOn(flowEngine, "executable").mockResolvedValue("/fixture/gitch-flow");
    git.mockResolvedValue({ status: 1, stdout: "", stderr: "" });
    await cache.refresh("C:/work/atlas", "gone", ["C:/work/atlas"]);
    expect(cache.get("C:/work/atlas", "gone")).toBeNull();
  });
});
