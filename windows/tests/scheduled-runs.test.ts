import { afterEach, describe, expect, it, vi } from "vitest";
import {
  commitJobAction, commitJobs, commitRunBusy, commitWorkflowRuns, defaultCommitJob, parseCommitSubjects, runCommits,
} from "@/entities/ci/model/run-commits";
import { type ScheduledRunHost, ScheduledRunStore } from "@/entities/ci/model/scheduled-run-store";
import {
  canSchedule, dateTimeInputValue, decodeScheduledRuns, nextFullHour, parseDateTimeInput, scheduledCommitRun, type ScheduledRun, scheduledRunAction,
  scheduledRunRelative, scheduledRunsFor, scheduledRunTime, scheduleGrace,
} from "@/entities/ci/model/scheduled-runs";
import type { CIJob, CIPipeline } from "@/entities/ci/model/types";
import type { HostAccount } from "@/entities/git";
import { accounts } from "@/entities/hosting";
import { ipc } from "@/shared/api";
import { settings } from "@/shared/config";

/** A local time on Nov 10, 2026 */
const at = (hour: number, minute = 0, second = 0) => new Date(2026, 10, 10, hour, minute, second).getTime();
const run = (extra: Partial<ScheduledRun> = {}): ScheduledRun => ({
  id: "deploy", repoPath: "/work/demo", provider: "github", host: "github.com", remote: "origin", path: "octo/demo", accountID: "saved-account",
  workflowID: 7, workflowName: "Deploy", ref: "main", sha: null, runID: null, jobName: null, inputs: { level: "info" }, variables: [], runAt: at(15), createdAt: at(14, 10),
  state: "scheduled", message: null, ...extra,
});
// Intl puts a narrow no-break space before AM/PM in newer ICU versions
const plain = (text: string) => text.replace(/\s/g, " ");

describe("Scheduled runs", () => {
  it("offers the next full hour", () => {
    expect(nextFullHour(at(14, 10, 30))).toBe(at(15));
    expect(nextFullHour(at(14))).toBe(at(15));
    expect(nextFullHour(at(23, 59))).toBe(new Date(2026, 10, 11, 0).getTime());
  });

  it("schedules only a time still ahead", () => {
    expect(canSchedule(at(15), at(14, 59))).toBe(true);
    expect(canSchedule(at(15), at(15))).toBe(false);
    expect(canSchedule(at(14), at(15))).toBe(false);
    expect(canSchedule(null, at(15))).toBe(false);
  });

  it("starts a run within the grace window; one found later is missed, and a missed or failed one waits for a click", () => {
    const due = run();
    expect(scheduledRunAction(due, at(14, 59, 59))).toBe("wait");
    expect(scheduledRunAction(due, at(15))).toBe("start");
    expect(scheduledRunAction(due, at(15) + scheduleGrace)).toBe("start");
    expect(scheduledRunAction(due, at(15) + scheduleGrace + 1)).toBe("miss");
    expect(scheduledRunAction({ ...due, state: "missed" }, at(16))).toBe("wait");
    expect(scheduledRunAction({ ...due, state: "failed" }, at(15))).toBe("wait");
  });

  it("says how far off the run is, and how long ago once it has passed", () => {
    expect(scheduledRunRelative(at(15), at(14, 59, 30))).toBe("in 1m");
    expect(scheduledRunRelative(at(15), at(14, 10))).toBe("in 50m");
    expect(scheduledRunRelative(at(15), at(14, 0, 1))).toBe("in 1h");
    expect(scheduledRunRelative(at(15), at(12))).toBe("in 3h");
    expect(scheduledRunRelative(at(15) + 2 * 86_400_000, at(15))).toBe("in 2d");
    expect(scheduledRunRelative(at(15), at(15, 12))).toBe("12m ago");
  });

  it("names the day and time, with the year only for another year", () => {
    expect(plain(scheduledRunTime(at(15), at(9), "en"))).toBe("Nov 10, 3:00 PM");
    expect(plain(scheduledRunTime(new Date(2027, 0, 2, 9, 5).getTime(), at(9), "en"))).toBe("Jan 2, 2027, 9:05 AM");
  });

  it("reads and writes the date and time field in local time", () => {
    expect(dateTimeInputValue(at(15, 5))).toBe("2026-11-10T15:05");
    expect(parseDateTimeInput("2026-11-10T15:05")).toBe(at(15, 5));
    expect(parseDateTimeInput("2026-11-10T15:05:30")).toBe(at(15, 5, 30));
    expect(parseDateTimeInput(dateTimeInputValue(nextFullHour(at(14, 20))))).toBe(at(15));
    expect(parseDateTimeInput("")).toBeNull();
    expect(parseDateTimeInput("2026-02-30T10:00")).toBeNull();
  });

  it("lists a repository's runs soonest first and drops what a damaged settings file holds", () => {
    const runs = [run({ id: "late", runAt: at(18) }), run({ id: "other", repoPath: "/work/other" }), run({ id: "soon", runAt: at(16) })];
    expect(scheduledRunsFor(runs, "/work/demo", (a, b) => a === b).map((r) => r.id)).toEqual(["soon", "late"]);
    expect(scheduledRunsFor(runs, null, (a, b) => a === b)).toEqual([]);
    expect(decodeScheduledRuns([run(), { id: "broken" }, null, run({ id: "odd", state: "running" as never })]).map((r) => r.id)).toEqual(["deploy"]);
    expect(decodeScheduledRuns({})).toEqual([]);
  });

  it("reads a run saved before the commit choice as a run on its branch", () => {
    const { sha: _sha, runID: _runID, jobName: _jobName, ...saved } = run();
    expect(decodeScheduledRuns([saved])).toEqual([run()]);
    expect(scheduledCommitRun(decodeScheduledRuns([saved])[0])).toBeNull();
    const onCommit = decodeScheduledRuns([run({ sha: "0123456789abcdef", runID: 99, jobName: "build-job" })])[0];
    expect(scheduledCommitRun(onCommit)).toEqual({ runID: 99, jobName: "build-job" });
    expect(decodeScheduledRuns([{ ...saved, sha: 42, runID: "99", jobName: "" }])[0]).toMatchObject({ sha: null, runID: null, jobName: null });
    // a commit without the run to start again runs on the branch
    expect(scheduledCommitRun(run({ sha: "0123456789abcdef" }))).toBeNull();
  });
});

const pipeline = (extra: Partial<CIPipeline> = {}): CIPipeline => ({
  id: 1, number: 1, name: "CI", title: "", ref: "main", sha: "aaaaaaa1", status: "success", url: "", created: 100, event: "push", actor: null, ...extra,
});
const job = (id: number, name: string, status: CIJob["status"]): CIJob => ({ id, name, stage: "build", status, url: "", allowFailure: false, duration: null });

describe("Runs on a chosen commit", () => {
  it("lists the branch's commits with runs on it, newest first, with their runs", () => {
    const runs = [
      pipeline({ id: 5, sha: "bbbbbbb2", name: "Deploy", created: 300, title: "Second from the server" }),
      pipeline({ id: 4, sha: "bbbbbbb2", name: "CI", created: 290 }),
      pipeline({ id: 3, sha: "ccccccc9", ref: "feature/search", created: 280 }),
      pipeline({ id: 2, sha: "aaaaaaa1", created: 200, title: "First from the server" }),
      pipeline({ id: 1, sha: "aaaaaaa1", name: "Deploy", created: 100 }),
    ];
    const list = runCommits(runs, "main", new Map([["aaaaaaa1", "First from the log"]]));
    expect(list.map((c) => [c.sha, c.subject, c.created, c.runs.map((r) => r.id)])).toEqual([
      ["bbbbbbb2", "Second from the server", 300, [5, 4]],
      ["aaaaaaa1", "First from the log", 200, [2, 1]],
    ]);
    expect(runCommits(runs, "main", new Map(), 1)).toHaveLength(1);
    // GitHub re-runs the newest run of each workflow
    expect(commitWorkflowRuns(runCommits([...runs, pipeline({ id: 0, sha: "bbbbbbb2", name: "Deploy", created: 50 })], "main", new Map())[0]).map((r) => r.id)).toEqual([5, 4]);
  });

  it("offers the manual jobs first and starts on the first of them", () => {
    const jobs = [job(1, "test", "success"), job(2, "build-job", "manual"), job(3, "deploy-job", "created"), job(4, "later", "scheduled")];
    expect(commitJobs(jobs).map((j) => j.name)).toEqual(["build-job", "later", "test", "deploy-job"]);
    expect(defaultCommitJob(commitJobs(jobs))?.name).toBe("build-job");
    expect(defaultCommitJob([job(1, "test", "failed")])?.name).toBe("test");
    expect(defaultCommitJob([])).toBeNull();
  });

  it("presses a manual job, retries a finished one and leaves a running one alone", () => {
    expect(["manual", "scheduled"].map((s) => commitJobAction(s as CIJob["status"]))).toEqual(["play", "play"]);
    expect(["success", "failed", "canceled"].map((s) => commitJobAction(s as CIJob["status"]))).toEqual(["retry", "retry", "retry"]);
    expect(["created", "waiting", "pending", "running"].map((s) => commitJobAction(s as CIJob["status"]))).toEqual(["busy", "busy", "busy", "busy"]);
    expect(["skipped", "unknown"].map((s) => commitJobAction(s as CIJob["status"]))).toEqual(["unavailable", "unavailable"]);
    expect(commitRunBusy("running")).toBe(true);
    expect(commitRunBusy("pending")).toBe(true);
    expect(commitRunBusy("failed")).toBe(false);
  });

  it("reads the subjects from the log", () => {
    expect(parseCommitSubjects("0123456789abcdef\x1fFix the build\r\nfedcba98\x1fA subject \x1f with a separator\n\nshort\x1fignored\n")).toEqual(new Map([
      ["0123456789abcdef", "Fix the build"],
      ["fedcba98", "A subject \x1f with a separator"],
    ]));
  });
});

describe("Scheduled run store", () => {
  afterEach(() => vi.restoreAllMocks());

  /** A store on its own clock and list; `started` records what it started */
  const fixture = (runs: ScheduledRun[], now: number, fail?: string) => {
    const state = { runs, now, started: [] as string[] };
    const host: ScheduledRunHost = {
      now: () => state.now,
      read: () => state.runs,
      write: (next) => { state.runs = next; },
      start: async (r) => { state.started.push(r.id); if (fail) throw new Error(fail); },
    };
    const store = new ScheduledRunStore();
    store.useHost(host);
    return { store, state };
  };

  it("starts what is due once, keeps what waits and marks a run found too late as missed without starting it", async () => {
    const { store, state } = fixture([run({ id: "due", runAt: at(15) }), run({ id: "later", runAt: at(16) }), run({ id: "slept", runAt: at(14) })], at(15, 1));
    const started: string[] = [];
    store.onStarted = (r) => started.push(r.id);
    await Promise.all([store.check(), store.check()]);
    expect(state.started).toEqual(["due"]);
    expect(started).toEqual(["due"]);
    expect(state.runs.map((r) => [r.id, r.state])).toEqual([["later", "scheduled"], ["slept", "missed"]]);
    // a missed run stays missed on later checks; only Run now starts it
    state.now = at(16, 0, 30);
    await store.check();
    expect(state.started).toEqual(["due", "later"]);
    expect(state.runs.map((r) => [r.id, r.state])).toEqual([["slept", "missed"]]);
    await store.runNow("slept");
    expect(state.started).toEqual(["due", "later", "slept"]);
    expect(state.runs).toEqual([]);
  });

  it("keeps a run that could not start, with the reason, until it is removed", async () => {
    const { store, state } = fixture([run()], at(15), "Not Found");
    await store.check();
    expect(state.runs).toMatchObject([{ id: "deploy", state: "failed", message: "Not Found" }]);
    await store.check();
    expect(state.started).toEqual(["deploy"]);
    store.remove("deploy");
    expect(state.runs).toEqual([]);
  });

  it("starts the workflow with the saved account's token and keeps no token", async () => {
    const account: HostAccount = { id: "saved-account", provider: "github", server: "https://github.com", username: "octocat", name: null, avatarURL: null };
    const saved = accounts.accounts;
    vi.spyOn(ipc, "writeText").mockResolvedValue(undefined as never);
    vi.spyOn(accounts, "token").mockResolvedValue("fixture-token");
    const http = vi.spyOn(ipc, "http").mockResolvedValue({ status: 204, body: "" } as never);
    accounts.accounts = [account];
    try {
      const store = new ScheduledRunStore();
      store.add(run({ runAt: Date.now() - 1000 }));
      expect(JSON.stringify(settings.get("scheduledRuns", []))).not.toContain("fixture-token");
      await store.check();
      expect(http).toHaveBeenCalledTimes(1);
      const [method, url, headers, body] = http.mock.calls[0];
      expect([method, url]).toEqual(["POST", "https://api.github.com/repos/octo/demo/actions/workflows/7/dispatches"]);
      expect(headers.Authorization).toBe("Bearer fixture-token");
      expect(JSON.parse(body ?? "")).toEqual({ ref: "main", inputs: { level: "info" } });
      expect(settings.get("scheduledRuns", [null])).toEqual([]);
    } finally {
      accounts.accounts = saved;
      settings.set("scheduledRuns", undefined);
    }
  });

  it("does not start a run whose account was disconnected", async () => {
    vi.spyOn(ipc, "writeText").mockResolvedValue(undefined as never);
    const http = vi.spyOn(ipc, "http");
    const store = new ScheduledRunStore();
    try {
      store.add(run({ accountID: "gone", runAt: Date.now() - 1000 }));
      await store.check();
      expect(http).not.toHaveBeenCalled();
      expect(store.runs).toMatchObject([{ state: "failed", message: "The account for this run is no longer connected." }]);
    } finally {
      settings.set("scheduledRuns", undefined);
    }
  });

  describe("on a chosen commit", () => {
    const saved = accounts.accounts;
    afterEach(() => {
      accounts.accounts = saved;
      settings.set("scheduledRuns", undefined);
    });
    type Reply = { status: number; body: string };
    /** Starts a due run on the app's own start, with the server answering through `reply` */
    const start = async (account: HostAccount, scheduled: ScheduledRun, reply: (method: string, url: string) => Reply) => {
      vi.spyOn(ipc, "writeText").mockResolvedValue(undefined as never);
      vi.spyOn(accounts, "token").mockResolvedValue("fixture-token");
      const http = vi.spyOn(ipc, "http").mockImplementation(async (method: string, url: string) => reply(method, url) as never);
      accounts.accounts = [account];
      settings.set("scheduledRuns", undefined);
      const store = new ScheduledRunStore();
      store.add({ ...scheduled, runAt: Date.now() - 1000 });
      await store.check();
      return { store, calls: http.mock.calls.map(([method, url, , body]) => [method, url, body ? JSON.parse(body) : null]) };
    };
    const lab: HostAccount = { id: "lab-account", provider: "gitlab", server: "https://gitlab.example.com", username: "octocat", name: null, avatarURL: null };
    const hub: HostAccount = { id: "saved-account", provider: "github", server: "https://github.com", username: "octocat", name: null, avatarURL: null };
    const onLab = run({ provider: "gitlab", host: "gitlab.example.com", path: "group/demo", accountID: lab.id, workflowID: null, workflowName: null,
      sha: "0123456789abcdef", runID: 77, jobName: "build-job", inputs: {}, variables: [["DEPLOY_ENV", "prod"]] });
    const glJobs = (...list: [number, string, string][]) => ({ status: 200, body: JSON.stringify(list.map(([id, name, status]) => ({ id, name, stage: "build", status, web_url: "" }))) });
    const jobsURL = "https://gitlab.example.com/api/v4/projects/group%2Fdemo/pipelines/77/jobs?per_page=100";

    it("presses the manual job of the commit's pipeline, found again by name", async () => {
      const { store, calls } = await start(lab, onLab, (method) => (method === "GET" ? glJobs([5, "test", "success"], [8, "build-job", "manual"]) : { status: 200, body: "{}" }));
      expect(calls).toEqual([["GET", jobsURL, null], ["POST", "https://gitlab.example.com/api/v4/projects/group%2Fdemo/jobs/8/play", null]]);
      expect(store.runs).toEqual([]);
    });

    it("retries the job once it has finished, taking the newest of a retried job", async () => {
      const { calls } = await start(lab, onLab, (method) => (method === "GET" ? glJobs([8, "build-job", "failed"], [12, "build-job", "success"]) : { status: 201, body: "{}" }));
      expect(calls[1]).toEqual(["POST", "https://gitlab.example.com/api/v4/projects/group%2Fdemo/jobs/12/retry", null]);
    });

    it("does not start a job that is already running, or one that is gone", async () => {
      const busy = await start(lab, onLab, () => glJobs([8, "build-job", "running"]));
      expect(busy.calls.map(([method]) => method)).toEqual(["GET"]);
      expect(busy.store.runs).toMatchObject([{ state: "failed", message: "This job is already running." }]);
      vi.restoreAllMocks();
      const gone = await start(lab, { ...onLab, id: "gone" }, () => glJobs([5, "test", "success"]));
      expect(gone.store.runs).toMatchObject([{ id: "gone", state: "failed", message: "The job 'build-job' is no longer in this pipeline." }]);
    });

    it("re-runs the commit's GitHub run, and leaves one still running alone", async () => {
      const onHub = run({ sha: "0123456789abcdef", runID: 4242, workflowID: null, workflowName: "Deploy" });
      const ghRun = (status: string, conclusion: string | null) => ({ status: 200, body: JSON.stringify({ id: 4242, run_number: 9, head_branch: "main", head_sha: "0123456789abcdef", status, conclusion, html_url: "", event: "push" }) });
      const done = await start(hub, onHub, (method) => (method === "GET" ? ghRun("completed", "success") : { status: 201, body: "" }));
      expect(done.calls).toEqual([
        ["GET", "https://api.github.com/repos/octo/demo/actions/runs/4242", null],
        ["POST", "https://api.github.com/repos/octo/demo/actions/runs/4242/rerun", null],
      ]);
      expect(done.store.runs).toEqual([]);
      vi.restoreAllMocks();
      const going = await start(hub, { ...onHub, id: "going" }, () => ghRun("in_progress", null));
      expect(going.calls.map(([method]) => method)).toEqual(["GET"]);
      expect(going.store.runs).toMatchObject([{ id: "going", state: "failed", message: "This run is still running." }]);
    });

    it("shows the server's refusal of a run too old to re-run", async () => {
      const onHub = run({ sha: "0123456789abcdef", runID: 4242, workflowID: null });
      const { store } = await start(hub, onHub, (method) => (method === "GET"
        ? { status: 200, body: JSON.stringify({ id: 4242, run_number: 9, head_branch: "main", head_sha: "0123456789abcdef", status: "completed", conclusion: "failure", html_url: "", event: "push" }) }
        : { status: 403, body: JSON.stringify({ message: "Unable to retry this workflow run because it was created over a month ago" }) }));
      expect(store.runs[0].state).toBe("failed");
      expect(store.runs[0].message).toContain("created over a month ago");
    });
  });
});
