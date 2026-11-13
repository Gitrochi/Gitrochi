import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { agentHookEvents, agentHooksJson, type HookGroup } from "@/entities/agent/lib/hooks";
import { settings } from "@/shared/config";
import { type Capture, fakeClaude, fakeNative, startOnce } from "./agent-launch-harness";
import main from "./agent-launch-main.json";

// What starting an agent writes and runs must stay byte for byte what agent-launch-main.json holds.

const DIR = "C:/Users/example/AppData/Roaming/Gitrochi/agents";
const HOOKS = `${DIR}/hooks.json`, HOOKS_WSL = `${DIR}/hooks-wsl.json`;
const cases: [string, string, string | null][] = [["plain", "", null], ["task and mode", "fix the login retry", "plan"], ["multi-line task", "line one\nline two", "acceptEdits"]];
const mainLaunches = main.launches as Record<string, Capture["terminals"]>;
const mainFiles = main.files as Record<string, Record<string, string>>;

beforeEach(() => settings.set("agentKind", undefined));
afterEach(() => {
  settings.set("agentKind", undefined);
  vi.restoreAllMocks();
});

describe("Agent launches", () => {
  for (const where of ["native", "wsl"] as const) {
    for (const [name, task, mode] of cases) {
      it(`writes both hooks files and starts ${where} · ${name} byte for byte as the fixture`, async () => {
        const capture = fakeNative();
        fakeClaude(where);
        await startOnce(capture, task, mode);
        expect(capture.files[HOOKS]).toBe(main.hooks[HOOKS as keyof typeof main.hooks]);
        expect(capture.files[HOOKS_WSL]).toBe(main.hooks[HOOKS_WSL as keyof typeof main.hooks]);
        expect(capture.terminals).toEqual(mainLaunches[`${where} · ${name}`]);
        for (const [path, content] of Object.entries(mainFiles[`${where} · ${name}`] ?? {})) expect(capture.files[path]).toBe(content);
        // nothing reaches git or Claude Code before the launch
        expect(capture.runs).toEqual([]);
      });
    }
  }

  it("gives every event the Agents panel follows one entry", () => {
    const hooks = (JSON.parse(agentHooksJson((e) => `app ${e}`, 5)) as { hooks: Record<string, HookGroup[]> }).hooks;
    expect(Object.keys(hooks)).toEqual(agentHookEvents);
    for (const e of agentHookEvents) expect(hooks[e]).toEqual([{ matcher: "", hooks: [{ type: "command", command: `app ${e}`, timeout: 5 }] }]);
  });
});
