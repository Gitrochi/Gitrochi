import { describe, expect, it } from "vitest";
import {
  ciDuration, commonWorkflow, jobGroups, runBaseRef, runCount, runHistory, runSegments, runStreak, runSummaryCard, runTook, visibleRuns,
} from "@/entities/ci/model/actions-page";
import type { CIJob, CIPipeline, CIStatus } from "@/entities/ci/model/types";

const run = (id: number, status: CIStatus, extra: Partial<CIPipeline> = {}): CIPipeline =>
  ({ id, number: id, name: "CI", title: "Run", ref: "topic", sha: `s${id}`, status, url: "", created: id, event: "push", actor: null, ...extra });
const job = (id: number, status: CIStatus): CIJob => ({ id, name: `job${id}`, stage: "", status, url: "", allowFailure: false, duration: null });
const title = (value: CIPipeline) => value.title;

describe("Actions page", () => {
  const runs = [
    run(9, "running", { ref: "other" }), run(8, "waiting", { ref: "main", name: "Deploy" }), run(7, "success", { ref: "main" }), run(6, "success"),
    run(5, "failed", { ref: "fix", title: "Rework focus" }), run(4, "success"), run(3, "success"), run(2, "canceled", { ref: "x" }),
  ];

  it("counts only what failed, runs or waits; a cancelled or passed run is only under All", () => {
    expect(runSegments.map((segment) => runCount(runs, segment))).toEqual([8, 1, 1, 1]);
  });

  it("filters by segment and search, in either order", () => {
    expect(visibleRuns(runs, "failed", "", false, title).map((value) => value.id)).toEqual([5]);
    expect(visibleRuns(runs, "all", " MAIN ", true, title).map((value) => value.id)).toEqual([7, 8]);
    expect(visibleRuns(runs, "all", "focus", false, title).map((value) => value.id)).toEqual([5]);
    expect(visibleRuns(runs, "all", "#4", false, title).map((value) => value.id)).toEqual([4]);
    expect(visibleRuns(runs, "all", "deploy", false, title).map((value) => value.id)).toEqual([8]);
    // the order is a view: the list itself stays newest first
    expect(runs[0].id).toBe(9);
  });

  it("leaves the workflow most runs belong to unsaid", () => {
    expect(commonWorkflow(runs)).toBe("CI");
    expect(commonWorkflow([])).toBeNull();
  });

  it("shows this branch's latest runs, oldest first, and what the newest one says", () => {
    expect(runHistory(runs, "topic").map((value) => value.id)).toEqual([3, 4, 6]);
    expect(runHistory(runs, "topic", 2).map((value) => value.id)).toEqual([4, 6]);
    expect(runHistory(runs, null)).toEqual([]);
    expect(runHistory([{ ...runs[0], id: 20, ref: "mixed", name: "Windows" }, { ...runs[0], id: 19, ref: "mixed", name: "macOS" }, { ...runs[0], id: 18, ref: "mixed", name: "Windows" }], "mixed").map((value) => value.id)).toEqual([18, 20]);
    expect(runStreak(runHistory(runs, "topic"))).toEqual({ kind: "passing", count: 3 });
    expect(runStreak([run(1, "failed"), run(2, "success")])).toEqual({ kind: "passing", count: 1 });
    expect(runStreak([run(1, "success"), run(2, "failed")])).toEqual({ kind: "failed", run: run(2, "failed") });
    expect(runStreak([run(1, "success"), run(2, "pending")])).toEqual({ kind: "running", run: run(2, "pending") });
    expect(runStreak([run(2, "manual")])).toEqual({ kind: "waiting", run: run(2, "manual") });
    expect(runStreak([run(2, "canceled")])).toEqual({ kind: "none" });
    expect(runStreak([])).toEqual({ kind: "none" });
  });

  it("says how long a run took only when it finished and both times are known", () => {
    expect(runTook(run(1, "success", { started: 100, updated: 448 }))).toBe(348);
    expect(runTook(run(2, "running", { started: 100, updated: 448 }))).toBeNull();
    expect(runTook(run(3, "success", { created: null }))).toBeNull();
  });

  it("compares runs with main, or master where there is no main", () => {
    expect(runBaseRef(["topic", "master", "main"])).toBe("main");
    expect(runBaseRef(["topic", "master"])).toBe("master");
    expect(runBaseRef(["topic"])).toBeNull();
  });

  it("groups jobs by result, what failed first", () => {
    const groups = jobGroups([job(1, "success"), job(2, "failed"), job(3, "skipped"), job(4, "manual"), job(5, "running"), job(6, "success")]);
    expect(groups.map((entry) => entry.group)).toEqual(["failed", "running", "waiting", "passed", "other"]);
    expect(groups.map((entry) => entry.jobs.map((value) => value.id))).toEqual([[2], [5], [4], [1, 6], [3]]);
  });

  it("writes how long a job took in minutes and seconds", () => {
    expect(ciDuration(192)).toBe("3m 12s");
    expect(ciDuration(41.4)).toBe("41s");
  });

  it("gives the summary card a state from the first frame and says there are no runs only after a read", () => {
    expect(runSummaryCard(0, 0, true, false)).toBe("loading");
    expect(runSummaryCard(0, 0, false, true)).toBe("empty");
    // a list that could not be read has not shown there are none
    expect(runSummaryCard(0, 0, false, false)).toBe("unknown");
    // a refresh keeps what the last read said: runs, but none on this branch
    expect(runSummaryCard(0, 4, true, false)).toBe("empty");
    expect(runSummaryCard(3, 4, true, false)).toBe("runs");
    expect(runSummaryCard(3, 4, false, true)).toBe("runs");
  });
});
