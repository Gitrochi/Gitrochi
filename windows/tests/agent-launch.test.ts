import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { agents } from "@/entities/agent";
import { agentHookEvents, agentHooksJson, type HookGroup, ledgerHookGroups } from "@/entities/agent/lib/hooks";
import { launchArguments, launchEnv } from "@/entities/agent/lib/launch";
import { ledgerMcpConfig, ledgerTracking, repositoryPolicy, repositoryRoot, withRepositoryPolicy } from "@/entities/ledger";
import { env, initEnv, settings } from "@/shared/config";
import { AGENT_ID, type Capture, fakeClaude, fakeHost, fakeNative, FOLDER, startOnce, windowsEnv } from "./agent-launch-harness";
import main from "./agent-launch-main.json";

// Track agents I start (docs/ledger/DESIGN.md §5, §7.11): with it off, Gitrochi writes and runs exactly what main does.

const DIR = "C:/Users/example/AppData/Roaming/Gitrochi/agents";
const HOOKS = `${DIR}/hooks.json`, HOOKS_WSL = `${DIR}/hooks-wsl.json`;
const CLI = "C:/Program Files/Gitrochi's tools/gitrochi-ledger.exe";
const cases: [string, string, string | null][] = [["plain", "", null], ["task and mode", "fix the login retry", "plan"], ["multi-line task", "line one\nline two", "acceptEdits"]];
const mainLaunches = main.launches as Record<string, Capture["terminals"]>;
const mainFiles = main.files as Record<string, Record<string, string>>;

function resetLedgerSettings() {
  for (const key of ["ledgerTrackAgents", "ledgerAgentTools", "agentKind"]) settings.set(key, undefined);
}

beforeEach(() => resetLedgerSettings());
afterEach(async () => {
  resetLedgerSettings();
  await ledgerTracking.syncHeartbeat();
  vi.restoreAllMocks();
  vi.useRealTimers();
});

/** The ledger as the core answers a launch; `projects` and `autoContinue` are what Settings › Ledger stored */
function fakeLedger(calls: [string, Record<string, unknown>][], o: { projects?: unknown[]; autoContinue?: Record<string, unknown> } = {}) {
  return (method: string, args: Record<string, unknown>) => {
    calls.push([method, args]);
    switch (method) {
      case "info":
        return { schemaVersion: 1, dbPath: "C:/Users/example/AppData/Roaming/Gitrochi/ledger/ledger.sqlite3", rev: 1, enabled: true };
      case "projects":
        return { projects: o.projects ?? [] };
      case "settings":
        return { staleHours: 72, kinds: {}, autoContinue: o.autoContinue ?? { enabled: false, delaySec: 30 }, backupKeep: 14 };
      case "track":
        return { ok: true, rev: 3, session: { id: "S1031-07", project: args.project ?? "example-app", title: "feature/login", links: {} } };
      case "rev":
        return { rev: 3 };
      default:
        return { error: { code: "NOT_FOUND", message: `not faked: ${method}` } };
    }
  };
}

/** git and `claude mcp get` as a repository with a linked worktree answers them */
function fakeRun(o: { ownServer?: boolean } = {}) {
  return (program: string, args: string[]) => {
    if (args.includes("rev-parse")) return { status: 0, stdout: "C:/Work/example-app\nC:/Work/example-app/.git\n", stderr: "" };
    if (args.includes("mcp")) return o.ownServer ? { status: 0, stdout: "gitrochi-ledger:\n  Scope: User config", stderr: "" } : { status: 1, stdout: "", stderr: "No MCP server found with name: gitrochi-ledger" };
    return { status: 1, stdout: "", stderr: `not faked: ${program}` };
  };
}

describe("Agent launches with Track agents I start off", () => {
  for (const where of ["native", "wsl"] as const) {
    for (const [name, task, mode] of cases) {
      it(`writes both hooks files and starts ${where} · ${name} byte for byte as main`, async () => {
        const capture = fakeNative();
        fakeClaude(where);
        await startOnce(capture, task, mode);
        expect(capture.files[HOOKS]).toBe(main.hooks[HOOKS as keyof typeof main.hooks]);
        expect(capture.files[HOOKS_WSL]).toBe(main.hooks[HOOKS_WSL as keyof typeof main.hooks]);
        expect(capture.terminals).toEqual(mainLaunches[`${where} · ${name}`]);
        for (const [path, content] of Object.entries(mainFiles[`${where} · ${name}`] ?? {})) expect(capture.files[path]).toBe(content);
        // nothing reaches the ledger, git or Claude Code before the launch
        expect(capture.runs).toEqual([]);
      });
    }
  }

  it("stays as main when only one of the two switches is on", async () => {
    for (const [preview, chosen] of [["1", false], [null, true]] as const) {
      const capture = fakeNative({ exists: () => true, run: fakeRun(), ledger: fakeLedger([]) });
      fakeClaude("native");
      await initEnv({ ...windowsEnv, ledgerPreview: preview });
      settings.set("ledgerTrackAgents", chosen || undefined);
      await agents.init();
      await agents.start(fakeHost(capture), "claude", FOLDER, "fix the login retry", "plan");
      agents.dispose();
      expect(capture.files[HOOKS]).toBe(main.hooks[HOOKS as keyof typeof main.hooks]);
      expect(capture.files[HOOKS_WSL]).toBe(main.hooks[HOOKS_WSL as keyof typeof main.hooks]);
      expect(capture.terminals).toEqual(mainLaunches["native · task and mode"]);
      expect(capture.runs).toEqual([]);
      vi.restoreAllMocks();
    }
  });
});

describe("Agent launches with Track agents I start on", () => {
  async function trackedStart(where: "native" | "wsl", o: { ownServer?: boolean; tools?: boolean; kind?: "claude" | "codex"; projects?: unknown[]; autoContinue?: Record<string, unknown>; ledger?: (method: string, args: Record<string, unknown>) => unknown } = {}) {
    const calls: [string, Record<string, unknown>][] = [];
    const capture = fakeNative({ exists: (path) => path === CLI, run: fakeRun(o), ledger: o.ledger ?? fakeLedger(calls, o) });
    fakeClaude(where);
    await initEnv({ ...windowsEnv, ledgerPreview: "1" });
    settings.set("ledgerTrackAgents", true);
    if (o.tools === false) settings.set("ledgerAgentTools", false);
    await agents.init();
    await agents.start(fakeHost(capture), o.kind ?? "claude", FOLDER, "fix the login retry", "plan");
    agents.dispose();
    return { capture, calls };
  }
  const parse = (text: string) => (JSON.parse(text) as { hooks: Record<string, HookGroup[]> }).hooks;

  it("keeps every existing hooks entry and adds the ledger's after them", async () => {
    const { capture } = await trackedStart("native");
    for (const [file, ledger] of [[HOOKS, `"C:/Program Files/Gitrochi's tools/gitrochi-ledger.exe" hook`], [HOOKS_WSL, `'/mnt/c/Program Files/Gitrochi'\\''s tools/gitrochi-ledger.exe' hook`]] as const) {
      const before = parse(main.hooks[file as keyof typeof main.hooks]), after = parse(capture.files[file]);
      for (const event of agentHookEvents) expect(after[event][0]).toEqual(before[event][0]);
      expect(Object.keys(after)).toEqual([...agentHookEvents, "PostToolUse", "PostToolUseFailure"]);
      const added = Object.fromEntries(Object.entries(after).map(([event, groups]) => [event, groups.slice(event in before ? 1 : 0)]));
      for (const [event, groups] of Object.entries(added)) {
        if (event === "Notification") expect(groups).toEqual([]);
        else expect(groups.map((g) => g.hooks[0].command)).toEqual([`${ledger} ${event}`]);
      }
      expect(added.PreToolUse[0].matcher).toBe("AskUserQuestion|ExitPlanMode");
      expect(added.Stop[0].hooks[0]).toMatchObject({ async: true, asyncRewake: true, timeout: 310 });
      expect(added.PermissionRequest[0].hooks[0].timeout).toBe(310);
      for (const event of ["SessionStart", "UserPromptSubmit", "SessionEnd", "PostToolUse", "PostToolUseFailure"]) expect(added[event][0].hooks[0].timeout).toBe(10);
    }
  });

  it("registers the session first and passes it to the agent with the Ledger's tools", async () => {
    const { capture, calls } = await trackedStart("native");
    // the core works out the project, title, base and worktree from the checkout
    expect(calls.find(([method]) => method === "track")![1]).toEqual({ cwd: FOLDER, repoPath: "C:/Work/example-app", agentId: AGENT_ID });
    const config = `${DIR}/${AGENT_ID}.mcp.json`;
    const [mainLaunch] = mainLaunches["native · task and mode"];
    expect(capture.terminals).toEqual([{ ...mainLaunch, spec: { ...mainLaunch.spec, args: ["--mcp-config", config, ...mainLaunch.spec!.args!], env: { GITROCHI_AGENT_ID: AGENT_ID, GITROCHI_LEDGER_SESSION: "S1031-07" } } }]);
    expect(JSON.parse(capture.files[config])).toEqual({ mcpServers: { "gitrochi-ledger": { command: "C:\\Program Files\\Gitrochi's tools\\gitrochi-ledger.exe", args: ["mcp"], env: { GITROCHI_LEDGER_SESSION: "S1031-07" } } } });
    expect(capture.runs.find((r) => r.args[0] === "mcp")).toEqual({ program: "C:/Users/example/.local/bin/claude.exe", args: ["mcp", "get", "gitrochi-ledger"], cwd: FOLDER });
  });

  it("carries the session through WSLENV for an agent in WSL", async () => {
    const { capture } = await trackedStart("wsl");
    const spec = capture.terminals[0].spec!;
    const [mainLaunch] = mainLaunches["wsl · task and mode"];
    const claude = mainLaunch.spec!.args!.indexOf("/home/example/.local/bin/claude");
    expect(spec.args).toEqual([...mainLaunch.spec!.args!.slice(0, claude + 1), "--mcp-config", `/mnt/c/Users/example/AppData/Roaming/Gitrochi/agents/${AGENT_ID}.mcp.json`, ...mainLaunch.spec!.args!.slice(claude + 1)]);
    expect(spec.env).toEqual({ GITROCHI_AGENT_ID: AGENT_ID, GITROCHI_LEDGER_SESSION: "S1031-07", WSLENV: "GITROCHI_AGENT_ID:GITROCHI_LEDGER_SESSION" });
    const config = JSON.parse(capture.files[`${DIR}/${AGENT_ID}.mcp.json`]);
    expect(config.mcpServers["gitrochi-ledger"]).toEqual({ command: "/mnt/c/Program Files/Gitrochi's tools/gitrochi-ledger.exe", args: ["mcp"], env: { GITROCHI_LEDGER_SESSION: "S1031-07", WSLENV: "GITROCHI_LEDGER_SESSION" } });
  });

  it("leaves the tools out when Claude Code has its own gitrochi-ledger server, or when they are turned off", async () => {
    const own = await trackedStart("native", { ownServer: true });
    expect(own.capture.terminals[0].spec!.args![0]).toBe("--settings");
    expect(own.capture.terminals[0].spec!.env).toEqual({ GITROCHI_AGENT_ID: AGENT_ID, GITROCHI_LEDGER_SESSION: "S1031-07" });
    vi.restoreAllMocks();
    const off = await trackedStart("native", { tools: false });
    expect(off.capture.terminals[0].spec!.args).toEqual(mainLaunches["native · task and mode"][0].spec!.args);
    expect(off.capture.runs.some((r) => r.args[0] === "mcp")).toBe(false);
  });

  it("names the project bound to the repository and its policy, whatever the case or separators", async () => {
    const projects = [{ key: "atlas", name: "Atlas", repoPath: "C:\\work\\Example-App", baselineSource: "tags", baselinePattern: "", scanFiles: false, scanSubdirs: [] }];
    const autoContinue = { enabled: false, delaySec: 30, repositories: { "c:\\work\\example-app\\": { enabled: true, delaySec: 45 } } };
    const { calls } = await trackedStart("native", { projects, autoContinue });
    expect(calls.find(([method]) => method === "track")![1]).toEqual({ cwd: FOLDER, repoPath: "C:/Work/example-app", agentId: AGENT_ID, project: "atlas", autoContinue: { enabled: true, delaySec: 45 } });
  });

  it("starts other agents, and agents it cannot register, exactly as before", async () => {
    const codex = await trackedStart("native", { kind: "codex" });
    expect(codex.calls.some(([method]) => method === "track")).toBe(false);
    expect(codex.capture.terminals[0].spec!.env).toEqual({ GITROCHI_AGENT_ID: AGENT_ID });
    vi.restoreAllMocks();
    const failing = await trackedStart("native", { ledger: (method) => (method === "track" ? { error: { code: "DATABASE", message: "The ledger is locked" } } : fakeLedger([])(method, {})) });
    expect(failing.capture.terminals).toEqual(mainLaunches["native · task and mode"]);
    expect(ledgerTracking.lastError).toBe("The ledger is locked");
  });

  it("touches app.alive next to the database every 5 seconds while tracking is on", async () => {
    vi.useFakeTimers();
    const capture = fakeNative({ ledger: fakeLedger([]) });
    await initEnv({ ...windowsEnv, ledgerPreview: "1" });
    settings.set("ledgerTrackAgents", true);
    await ledgerTracking.syncHeartbeat();
    const alive = "C:/Users/example/AppData/Roaming/Gitrochi/ledger/app.alive";
    const first = capture.files[alive];
    expect(Number(first)).toBe(Math.floor(Date.now() / 1000));
    await vi.advanceTimersByTimeAsync(5000);
    expect(Number(capture.files[alive])).toBe(Number(first) + 5);
    settings.set("ledgerTrackAgents", undefined);
    await ledgerTracking.syncHeartbeat();
    await vi.advanceTimersByTimeAsync(10_000);
    expect(Number(capture.files[alive])).toBe(Number(first) + 5);
    // the demo has no database to stand next to
    await initEnv({ ...windowsEnv, ledgerPreview: "1", ledgerDemo: "1" });
    settings.set("ledgerTrackAgents", true);
    delete capture.files[alive];
    await ledgerTracking.syncHeartbeat();
    expect(capture.files[alive]).toBeUndefined();
  });
});

describe("Ledger launch pieces", () => {
  it("mirrors gitrochi-autocontinue's hook settings, plus SessionStart and SessionEnd", () => {
    const groups = ledgerHookGroups((e) => `ledger hook ${e}`);
    expect(groups.map(([event, g]) => [event, g.matcher, g.hooks[0].timeout, !!g.hooks[0].asyncRewake])).toEqual([
      ["SessionStart", "", 10, false],
      ["UserPromptSubmit", "", 10, false],
      ["PreToolUse", "AskUserQuestion|ExitPlanMode", 310, false],
      ["PermissionRequest", "", 310, false],
      ["Stop", "", 310, true],
      ["SessionEnd", "", 10, false],
      ["PostToolUse", "", 10, false],
      ["PostToolUseFailure", "", 10, false],
    ]);
    expect(agentHooksJson((e) => `app ${e}`, 5)).toBe(agentHooksJson((e) => `app ${e}`, 5, null));
  });

  it("adds nothing to the command line or the environment without a ledger session", () => {
    const args = ["--settings", "h.json", "fix it"];
    expect(launchArguments(args, null)).toBe(args);
    expect(launchArguments(args, "m.json")).toEqual(["--mcp-config", "m.json", ...args]);
    expect(launchEnv("a1", null)).toEqual({ GITROCHI_AGENT_ID: "a1" });
    expect(launchEnv("a1", "S1031-01")).toEqual({ GITROCHI_AGENT_ID: "a1", GITROCHI_LEDGER_SESSION: "S1031-01" });
  });

  it("finds the repository a folder belongs to, also from a linked worktree", () => {
    expect(repositoryRoot("C:/w/app", "C:/w/app\nC:/w/app/.git\n")).toBe("C:/w/app");
    expect(repositoryRoot("C:/w/app-login/src", "C:/w/app-login\nC:/w/app/.git\n")).toBe("C:/w/app");
    expect(repositoryRoot("C:/w/bare", "C:/w/bare\nC:/w/bare.git\n")).toBe("C:/w/bare");
    expect(repositoryRoot("C:/notes", null)).toBe("C:/notes");
  });

  it("keeps each repository's policy under one key in the ledger's setting", async () => {
    await initEnv(windowsEnv);
    const base = { enabled: false, delaySec: 30 };
    const one = withRepositoryPolicy(base, "C:\\Work\\App\\", { enabled: true, delaySec: 60 });
    expect(one).toEqual({ enabled: false, delaySec: 30, repositories: { "C:/Work/App": { enabled: true, delaySec: 60 } } });
    // the same repository written another way keeps its key; another one gets its own
    const two = withRepositoryPolicy(withRepositoryPolicy(one, "c:/work/app", { enabled: false, delaySec: 90 }), "D:/Other", { enabled: true, delaySec: 20 });
    expect(two.repositories).toEqual({ "C:/Work/App": { enabled: false, delaySec: 90 }, "D:/Other": { enabled: true, delaySec: 20 } });
    expect(repositoryPolicy(two, "C:\\work\\app")).toEqual({ enabled: false, delaySec: 90 });
    expect(repositoryPolicy(two, "C:/Work/Apps")).toBeNull();
    expect(withRepositoryPolicy(withRepositoryPolicy(two, "D:/Other", null), "C:/Work/App", null)).toEqual(base);
  });

  it("gives each launched agent its session in the MCP server's environment", () => {
    expect(JSON.parse(ledgerMcpConfig("C:\\Tools\\gitrochi-ledger.exe", "S1031-02", false))).toEqual({ mcpServers: { "gitrochi-ledger": { command: "C:\\Tools\\gitrochi-ledger.exe", args: ["mcp"], env: { GITROCHI_LEDGER_SESSION: "S1031-02" } } } });
    expect(JSON.parse(ledgerMcpConfig("/mnt/c/Tools/gitrochi-ledger.exe", "S1031-02", true)).mcpServers["gitrochi-ledger"].env).toEqual({ GITROCHI_LEDGER_SESSION: "S1031-02", WSLENV: "GITROCHI_LEDGER_SESSION" });
  });

  it("keeps the switches only with the Ledger preview", async () => {
    await initEnv({ ...windowsEnv, ledgerPreview: null });
    settings.set("ledgerTrackAgents", true);
    expect(ledgerTracking.chosen).toBe(true);
    expect(ledgerTracking.on).toBe(false);
    await initEnv({ ...windowsEnv, ledgerPreview: "1" });
    expect(ledgerTracking.on).toBe(true);
    expect(env.ledgerPreview).toBe("1");
    expect(ledgerTracking.tools).toBe(true);
  });
});
