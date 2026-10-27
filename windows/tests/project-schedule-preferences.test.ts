import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { readProjectScheduleSettings, saveProjectScheduleSettings } from "../src/entities/hosting/model/project-schedule-preferences";

let values: Map<string, string>;
beforeEach(() => { values = new Map(); vi.stubGlobal("localStorage", { getItem: (key: string) => values.get(key) ?? null, setItem: (key: string, value: string) => values.set(key, value) }); });
afterEach(() => vi.unstubAllGlobals());
describe("schedule preference defaults", () => {
  it("makes new local projects useful without account or field setup", () => {
    expect(readProjectScheduleSettings("", "local:plan")).toEqual({ startFieldID: "local-start", dueFieldID: "local-due", statusFieldID: "local-status", completedOptionIDs: ["local-done"] });
    expect(readProjectScheduleSettings("account", "REMOTE")).toEqual({ completedOptionIDs: [] });
    const expected = readProjectScheduleSettings("", "local:plan");
    for (const invalid of ["[]", "{}", "invalid JSON", '{"completedOptionIDs":[1]}']) {
      values.set("gitrochi.project-schedule.v1:local:local:plan", invalid);
      expect(readProjectScheduleSettings("", "local:plan")).toEqual(expected);
    }
  });
  it("preserves explicit empty/None choices and keeps local preferences account-independent", () => {
    const explicit = { startFieldID: "", dueFieldID: "", statusFieldID: "", completedOptionIDs: [] };
    saveProjectScheduleSettings("", "local:plan", explicit);
    expect(readProjectScheduleSettings("different-account", "local:plan")).toEqual(explicit);
    saveProjectScheduleSettings("account-a", "REMOTE", explicit);
    expect(readProjectScheduleSettings("account-b", "REMOTE")).toEqual({ completedOptionIDs: [] });
  });
});
