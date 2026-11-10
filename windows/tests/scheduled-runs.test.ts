import { afterEach, describe, expect, it, vi } from "vitest";
import { type ScheduledRunHost, ScheduledRunStore } from "@/entities/ci/model/scheduled-run-store";
import {
  canSchedule, dateTimeInputValue, decodeScheduledRuns, nextFullHour, parseDateTimeInput, type ScheduledRun, scheduledRunAction,
  scheduledRunRelative, scheduledRunsFor, scheduledRunTime, scheduleGrace,
} from "@/entities/ci/model/scheduled-runs";
import type { HostAccount } from "@/entities/git";
import { accounts } from "@/entities/hosting";
import { ipc } from "@/shared/api";
import { settings } from "@/shared/config";

/** A local time on Nov 10, 2026 */
const at = (hour: number, minute = 0, second = 0) => new Date(2026, 10, 10, hour, minute, second).getTime();
const run = (extra: Partial<ScheduledRun> = {}): ScheduledRun => ({
  id: "deploy", repoPath: "/work/demo", provider: "github", host: "github.com", remote: "origin", path: "octo/demo", accountID: "saved-account",
  workflowID: 7, workflowName: "Deploy", ref: "main", inputs: { level: "info" }, variables: [], runAt: at(15), createdAt: at(14, 10),
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
});
