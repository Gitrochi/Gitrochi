import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
vi.hoisted(() => vi.stubGlobal("matchMedia", () => ({ matches: false, addEventListener() {} })));
vi.mock("@/entities/terminal", () => ({ TerminalSession: class {} }));

import { workValidationFixture } from "@/app/lib/work-validation-selftest";
import { agents } from "@/entities/agent";
import { ipc } from "@/shared/api";
import { env, initEnv } from "@/shared/config";

// As in the real-app self-test, the agent center polls its folder every 2 s while the fixture is in use.
beforeEach(async () => {
  vi.useFakeTimers();
  await initEnv({ ...env, dataDir: "C:/data" });
  vi.spyOn(ipc, "mkdirs").mockResolvedValue();
  vi.spyOn(ipc, "remove").mockResolvedValue();
  vi.spyOn(ipc, "writeText").mockResolvedValue();
  vi.spyOn(ipc, "list").mockResolvedValue([]);
  vi.spyOn(ipc, "readText").mockResolvedValue(null);
  await agents.init();
});

afterEach(() => {
  agents.dispose();
  vi.restoreAllMocks();
  vi.useRealTimers();
});

const ids = () => agents.sessions.map((session) => session.id);

describe("work validation fixture", () => {
  it("keeps its agent sessions while the agent center polls", async () => {
    const fixture = await workValidationFixture();
    try {
      await vi.advanceTimersByTimeAsync(10_000);
      expect(ids()).toEqual(["agent-a", "agent-b"]);
    } finally { fixture.dispose(); }
  });

  it("keeps its agent sessions from a reload that was already under way", async () => {
    let release!: (names: string[]) => void;
    vi.mocked(ipc.list).mockImplementationOnce(() => new Promise((resolve) => { release = resolve; }));
    await vi.advanceTimersByTimeAsync(2000);
    const fixture = await workValidationFixture();
    try {
      release([]);
      await vi.advanceTimersByTimeAsync(0);
      expect(ids()).toEqual(["agent-a", "agent-b"]);
    } finally { fixture.dispose(); }
  });

  it("hands the sessions back to the agent center when disposed", async () => {
    (await workValidationFixture()).dispose();
    expect(agents.sessions).toEqual([]);
    vi.mocked(ipc.list).mockResolvedValue(["real.meta"]);
    vi.mocked(ipc.readText).mockImplementation(async (path) => path.endsWith("real.meta") ? JSON.stringify({ kind: "codex", path: "C:/repo", created: 1 }) : null);
    await vi.advanceTimersByTimeAsync(2000);
    expect(ids()).toEqual(["real"]);
  });
});
