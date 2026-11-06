import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ipc } from "@/shared/api";
import { settings } from "@/shared/config";

describe("Saving settings", () => {
  const original = ipc.writeText;
  let writes: string[] = [];

  beforeEach(() => {
    vi.useFakeTimers();
    writes = [];
    ipc.writeText = async (_path, text) => { writes.push(text); };
  });
  afterEach(async () => {
    settings.set("settingsSaveFixture", undefined);
    await settings.flush();
    vi.useRealTimers();
    ipc.writeText = original;
  });

  it("saves once, shortly after the last change", async () => {
    settings.set("settingsSaveFixture", 1);
    await vi.advanceTimersByTimeAsync(200);
    settings.set("settingsSaveFixture", 2);
    await vi.advanceTimersByTimeAsync(200);
    expect(writes).toHaveLength(0);
    await vi.advanceTimersByTimeAsync(100);
    expect(writes).toHaveLength(1);
    expect(JSON.parse(writes[0]).settingsSaveFixture).toBe(2);
  });

  // The self-test flushes between steps so that no step's save lands in the next step's fakes
  it("leaves nothing to fire later once flushed", async () => {
    settings.set("settingsSaveFixture", 1);
    await settings.flush();
    expect(writes).toHaveLength(1);
    await vi.advanceTimersByTimeAsync(1000);
    expect(writes).toHaveLength(1);
  });
});
