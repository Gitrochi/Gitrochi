import { afterEach, describe, expect, it, vi } from "vitest";
import { agentHost, agents, appDisplayName, containingRoot, externalAgentKind, relativeFolder, resolveExternalAgents } from "@/entities/agent";
import { ipc, type AgentProcess, type AgentScan } from "@/shared/api";

const own = 900;
const terminal = { pid: 10, name: "WindowsTerminal.exe", window: true };
const shell = { pid: 20, name: "pwsh.exe", window: false };
const proc = (pid: number, name: string, cwd: string, ancestors = [shell, terminal], args: string[] = [], started = 1_700_000_000): AgentProcess => ({ pid, name, args, cwd, started, ancestors });

afterEach(() => vi.restoreAllMocks());

describe("external agents", () => {
  it("recognises agent executables and the npm installs that run under node or bun", () => {
    expect(externalAgentKind("claude.exe", [])).toBe("claude");
    expect(externalAgentKind("Codex.EXE", [])).toBe("codex");
    expect(externalAgentKind("codex-x86_64-pc-windows-msvc.exe", [])).toBe("codex");
    expect(externalAgentKind("gemini", [])).toBe("gemini");
    expect(externalAgentKind("node.exe", ["C:\\Users\\me\\AppData\\Roaming\\npm\\node_modules\\@anthropic-ai\\claude-code\\cli.js"])).toBe("claude");
    expect(externalAgentKind("node", ["/usr/lib/node_modules/@google/gemini-cli/dist/index.js", "--yolo"])).toBe("gemini");
    expect(externalAgentKind("bun", ["C:/tools/node_modules/@openai/codex/bin/codex.js"])).toBe("codex");
    expect(externalAgentKind("node.exe", ["C:\\npm\\claude"])).toBe("claude");
    for (const [name, args] of [["node.exe", ["server.js"]], ["node", ["C:/work/claude-helper/app.js"]], ["code.exe", []], ["cmd.exe", []]] as [string, string[]][]) expect(externalAgentKind(name, args)).toBeNull();
  });
  it("takes the first ancestor with an app window as the host, and leaves Gitrochi's own sessions out", () => {
    expect(agentHost([shell, terminal], own)).toEqual(terminal);
    expect(agentHost([shell, { pid: own, name: "Gitrochi.exe", window: true }, terminal], own)).toBe("own");
    expect(agentHost([shell, { pid: 30, name: "explorer.exe", window: false }], own)).toBeNull();
    // a window below Gitrochi wins: the agent runs in another app that Gitrochi only launched
    expect(agentHost([{ pid: 40, name: "Code.exe", window: true }, { pid: own, name: "Gitrochi.exe", window: true }], own)).toEqual({ pid: 40, name: "Code.exe", window: true });
  });
  it("lists each agent once, outside Gitrochi, newest first", () => {
    const scan: AgentScan = {
      own,
      processes: [
        proc(100, "claude.exe", "C:/repo", [shell, terminal], [], 1_700_000_100),
        // the Codex npm shim and the native binary it starts: one agent, shown as the outer process
        proc(200, "node.exe", "C:/repo/sub", [shell, terminal], ["C:/npm/node_modules/@openai/codex/bin/codex.js"], 1_700_000_200),
        proc(201, "codex-x86_64-pc-windows-msvc.exe", "C:/repo/sub", [{ pid: 200, name: "node.exe", window: false }, shell, terminal], [], 1_700_000_201),
        proc(300, "claude.exe", "C:/repo", [{ pid: 50, name: "pwsh.exe", window: false }, { pid: own, name: "Gitrochi.exe", window: true }]),
        proc(400, "node.exe", "C:/repo", [shell, terminal], ["server.js"]),
        proc(500, "gemini.exe", "D:/elsewhere", [{ pid: 60, name: "cmd.exe", window: true }], [], 0),
      ],
    };
    const list = resolveExternalAgents(scan);
    expect(list.map((a) => [a.pid, a.kind, a.hostPid, a.hostExe])).toEqual([[200, "codex", 10, "WindowsTerminal.exe"], [100, "claude", 10, "WindowsTerminal.exe"], [500, "gemini", 60, "cmd.exe"]]);
    expect(list.find((a) => a.pid === 500)?.started).toBeNull();
  });
  it("matches working folders to the repository and its worktrees, deepest first and case-insensitive on Windows paths", () => {
    const roots = ["C:/Work/Repo", "C:/Work/Repo/.worktrees/feature", "/home/me/repo"];
    expect(containingRoot("c:\\work\\repo\\src", roots)).toBe("C:/Work/Repo");
    expect(containingRoot("C:/Work/Repo/.worktrees/feature/app", roots)).toBe("C:/Work/Repo/.worktrees/feature");
    expect(containingRoot("C:/Work/Repo", roots)).toBe("C:/Work/Repo");
    expect(containingRoot("C:/Work/Repo-other", roots)).toBeNull();
    expect(containingRoot("/home/me/Repo/src", roots)).toBeNull();
    expect(containingRoot("/home/me/repo/src/", roots)).toBe("/home/me/repo");
    expect(relativeFolder("C:\\Work\\Repo\\src\\ui", "C:/Work/Repo")).toBe("src/ui");
    expect(relativeFolder("C:/Work/Repo/", "C:/Work/Repo")).toBe("");
  });
  it("names well-known apps and falls back to the executable", () => {
    expect(appDisplayName("WindowsTerminal.exe")).toBe("Windows Terminal");
    expect(appDisplayName("Code.exe")).toBe("VS Code");
    expect(appDisplayName("cmux")).toBe("cmux");
    expect(appDisplayName("MyTerminal.exe")).toBe("MyTerminal");
  });
  it("scans at most every five seconds however many panels ask", async () => {
    const scan = vi.spyOn(ipc, "externalAgents").mockResolvedValue({ own, processes: [proc(100, "claude.exe", "C:/repo")] });
    await agents.refreshExternal(Date.now() + 60_000);
    await Promise.all([agents.refreshExternal(), agents.refreshExternal()]);
    expect(scan).toHaveBeenCalledTimes(1);
    expect(agents.externalIn(["C:/repo"]).map((a) => a.pid)).toEqual([100]);
    expect(agents.externalIn(["C:/other"])).toEqual([]);
    await agents.refreshExternal(Date.now() + 10_000);
    expect(scan).toHaveBeenCalledTimes(2);
  });
});
