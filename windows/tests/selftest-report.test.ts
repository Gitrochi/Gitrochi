import { describe, expect, it } from "vitest";
import { SelfTestRecorder } from "../src/app/lib/selftest-report";

describe("self-test reporting", () => {
  it("keeps progress separate from the completion signal", async () => {
    const files = new Map<string, string>();
    const report = new SelfTestRecorder(async (file, content) => { files.set(file, content); }, "windows");
    await report.progress("Load application");
    expect(files.has("selftest-result.json")).toBe(false);
    expect(JSON.parse(files.get("selftest-progress.json")!)).toMatchObject({ complete: false, ok: false, stage: "Load application" });
    await report.finish([{ name: "Rendered", ok: true }]);
    expect(JSON.parse(files.get("selftest-result.json")!)).toMatchObject({ complete: true, ok: true, windows: true });
  });

  it("immediately records a failing result for an uncaught startup or render error", async () => {
    const files = new Map<string, string>();
    const report = new SelfTestRecorder(async (file, content) => { files.set(file, content); }, "windows");
    await report.progress("Mount React application");
    await report.fail(new Error("Fixture render failure"));
    const result = JSON.parse(files.get("selftest-result.json")!);
    expect(result).toMatchObject({ complete: true, ok: false, stage: "Mount React application" });
    expect(result.checks[0]).toMatchObject({ name: "Uncaught application error", ok: false });
    expect(result.checks[0].detail).toContain("Fixture render failure");
    await report.finish([{ name: "Later check", ok: true }]);
    expect(JSON.parse(files.get("selftest-result.json")!).ok).toBe(false);
  });

  it("serializes snapshots and can still write the final result after a failed progress write", async () => {
    const writes: string[] = [];
    const report = new SelfTestRecorder(async (file, content) => {
      writes.push(`${file}:${JSON.parse(content).stage}`);
      if (writes.length === 1) throw new Error("Fixture write failure");
    }, "macos");
    const first = report.progress("First");
    const second = report.progress("Second", [{ name: "Failed assertion", ok: false }]);
    await expect(first).rejects.toThrow("Fixture write failure");
    await second;
    await report.finish([{ name: "Failed assertion", ok: false }]);
    expect(writes).toEqual(["selftest-progress.json:First", "selftest-progress.json:Second", "selftest-result.json:Complete"]);
  });
});
