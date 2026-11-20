import { describe, expect, it } from "vitest";
import { readTerminalMeta, sessionsToRestore, terminalMeta } from "@/entities/terminal/lib/host-session";

const same = (a: string, b: string) => a.replace(/\\/g, "/").toLowerCase() === b.replace(/\\/g, "/").toLowerCase();

describe("terminal host sessions", () => {
  it("keeps how a tab was started, without the session it resumed", () => {
    const meta = terminalMeta("C:\\work\\repo", {
      directory: "C:\\work\\repo\\wt",
      program: "claude",
      args: ["--resume"],
      title: "Claude",
      resume: "old",
      repository: "C:\\work\\repo",
    });
    expect(meta).toEqual({
      app: "gitrochi",
      repository: "C:\\work\\repo",
      spec: { directory: "C:\\work\\repo\\wt", program: "claude", args: ["--resume"], env: undefined, title: "Claude", cwd: undefined },
    });
    expect(readTerminalMeta(JSON.parse(JSON.stringify(meta)))).toEqual(meta);
  });

  it("ignores sessions that are not ours or are malformed", () => {
    expect(readTerminalMeta(null)).toBeNull();
    expect(readTerminalMeta({ app: "other", repository: "/r", spec: { directory: "/r" } })).toBeNull();
    expect(readTerminalMeta({ app: "gitrochi", repository: "/r" })).toBeNull();
    expect(readTerminalMeta({ app: "gitrochi", repository: "/r", spec: { directory: "/r", args: [1] } })).toBeNull();
    expect(readTerminalMeta({ app: "gitrochi", repository: "/r", spec: { directory: "/r", env: { A: 1 } } })).toBeNull();
    expect(readTerminalMeta({ app: "gitrochi", repository: "/r", spec: { directory: "/r", program: null } })?.spec.program).toBeUndefined();
  });

  it("restores this repository's sessions that are not shown yet, in order", () => {
    const meta = (repository: string) => terminalMeta(repository, { directory: repository });
    const sessions = [
      { id: "a", meta: meta("C:/work/repo") },
      { id: "b", meta: meta("C:/work/other") },
      { id: "c", meta: { app: "else" } },
      { id: "d", meta: meta("c:\\work\\REPO") },
      { id: "e", meta: meta("C:/work/repo") },
    ];
    const restored = sessionsToRestore(sessions, "C:\\work\\repo", new Set(["e"]), same);
    expect(restored.map((r) => r.session.id)).toEqual(["a", "d"]);
  });
});
