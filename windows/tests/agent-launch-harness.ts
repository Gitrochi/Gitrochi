import { vi } from "vitest";
import { type AgentHost, agents } from "@/entities/agent";
import type { TerminalSession } from "@/entities/terminal";
import { type EnvInfo, ipc, type ProcOutput } from "@/shared/api";
import { initEnv } from "@/shared/config";
import { tools } from "@/shared/platform";

/**
 * Starts the agent center the way the app does, with every native call faked, and records what it writes and what it
 * asks the terminal to run. The same harness made agent-launch-main.json from main, so a test can compare byte for byte.
 */

export const AGENT_ID = "0f0e0d0c-0b0a-4908-8706-050403020100";
export const FOLDER = "C:/Work/example-app";

export const windowsEnv: EnvInfo = {
  os: "windows",
  home: "C:/Users/example",
  dataDir: "C:/Users/example/AppData/Roaming/Gitrochi",
  exe: "C:\\Program Files\\Gitrochi's tools\\Gitrochi.exe",
  temp: "C:/Users/example/AppData/Local/Temp",
  shell: "powershell.exe",
  version: "0.3.13",
  selftest: null,
  selftestOpen: null,
  appData: "C:/Users/example/AppData/Roaming",
  localAppData: "C:/Users/example/AppData/Local",
  resourceDir: "C:\\Program Files\\Gitrochi's tools",
};

export interface TerminalSpec {
  path: string;
  spec: { program?: string; args?: string[]; env?: Record<string, string>; title?: string; cwd?: string } | undefined;
}

export interface Capture {
  /** The last content written to each file */
  files: Record<string, string>;
  terminals: TerminalSpec[];
  runs: { program: string; args: string[]; cwd?: string }[];
}

/** Fakes the native side; `run` answers processes (git, claude mcp get) and `ledger` the ledger core */
export function fakeNative(o: { run?: (program: string, args: string[]) => ProcOutput; ledger?: (method: string, args: Record<string, unknown>) => unknown; exists?: (path: string) => boolean } = {}): Capture {
  const capture: Capture = { files: {}, terminals: [], runs: [] };
  vi.spyOn(ipc, "mkdirs").mockResolvedValue();
  vi.spyOn(ipc, "list").mockResolvedValue([]);
  vi.spyOn(ipc, "remove").mockResolvedValue();
  vi.spyOn(ipc, "readText").mockResolvedValue(null);
  vi.spyOn(ipc, "writeText").mockImplementation(async (path, content) => {
    capture.files[path] = content;
  });
  vi.spyOn(ipc, "exists").mockImplementation(async (path) => o.exists?.(path) ?? false);
  vi.spyOn(ipc, "run").mockImplementation(async (program, args, opts) => {
    capture.runs.push({ program, args, ...(opts?.cwd ? { cwd: opts.cwd } : {}) });
    return o.run?.(program, args) ?? { status: 1, stdout: "", stderr: "not faked" };
  });
  if (o.ledger) vi.spyOn(ipc, "ledgerCall").mockImplementation(async (method, args) => o.ledger!(method, args));
  vi.spyOn(crypto, "randomUUID").mockReturnValue(AGENT_ID);
  return capture;
}

export function fakeHost(capture: Capture): AgentHost {
  return {
    terminals: [],
    newTerminal: (path, spec) => {
      capture.terminals.push({ path, spec: spec && JSON.parse(JSON.stringify(spec)) });
      return { running: true, pid: 4242, onExit: null, terminate() {} } as unknown as TerminalSession;
    },
    focusTerminal: () => {},
  };
}

/** Claude Code as a Windows program, or inside WSL */
export function fakeClaude(where: "native" | "wsl") {
  vi.spyOn(tools, "command").mockReturnValue(where === "native" ? { kind: "native", exe: "C:/Users/example/.local/bin/claude.exe" } : { kind: "wsl", distro: "Ubuntu", path: "/home/example/.local/bin/claude" });
}

/** init() and one start, as the Start agent sheet calls it */
export async function startOnce(capture: Capture, task: string, mode: string | null) {
  await initEnv(windowsEnv);
  await agents.init();
  await agents.start(fakeHost(capture), "claude", FOLDER, task, mode);
  agents.dispose();
}
