import { describe, expect, it } from "vitest";
import type { LedgerConnectionCommand, LedgerIntegrationStatus } from "../src/entities/ledger";
import { DemoLedgerBackend } from "../src/entities/ledger";
import { agentConnection, browserConnection, mcpCommand } from "../src/features/connect-ledger-mcp/lib/connections";

const command = (over: Partial<LedgerConnectionCommand> = {}): LedgerConnectionCommand => ({ path: "/data/bin/gitrochi-ledger", exists: true, executable: true, writesSchema: 8, version: "0.1.0", canWrite: true, dbPath: "/data/ledger.sqlite3", sameDatabase: true, ...over });
const status = (over: Partial<LedgerIntegrationStatus> = {}): LedgerIntegrationStatus => ({ client: "claude", installed: true, cliPath: "/data/bin/gitrochi-ledger", ownedHookCount: 8, expectedHookCount: 8, requiresClientTrust: false, hooksDisabled: false, hookCommand: command(), mcp: { configPath: "/home/.claude.json", registered: false, command: null }, databaseSchema: 8, lastObservedAt: 1_000, lastReportAt: 2_000, health: "ok", ...over });

describe("Ledger connections", () => {
  it("maps every health to one of the five row states with its actions", () => {
    expect(agentConnection(status({ health: "not_installed", ownedHookCount: 0, hookCommand: null }), false)).toMatchObject({ state: "not_set_up", actions: ["setup"] });
    expect(agentConnection(status(), true)).toMatchObject({ state: "connected", lastDataAt: 2_000, actions: ["remove", "copy"] });
    expect(agentConnection(status({ health: "no_data_yet", lastObservedAt: null, lastReportAt: null }), false)).toMatchObject({ state: "no_data", lastDataAt: null, explanation: "Start or restart {0} to send activity." });
    expect(agentConnection(status({ client: "codex", requiresClientTrust: true, health: "no_data_yet" }), false).explanation).toContain("/hooks");
    expect(agentConnection(status({ health: "incomplete" }), false)).toMatchObject({ state: "repair", actions: ["repair", "remove"] });
    expect(agentConnection(status({ health: "missing_command", hookCommand: command({ exists: false, executable: false }) }), false)).toMatchObject({ state: "missing", repairsMcp: false });
  });

  it("names the outdated command and repairs the MCP entry only when the hooks are fine", () => {
    const stale = agentConnection(status({ health: "outdated_command", hookCommand: command({ writesSchema: 1, canWrite: false }) }), true);
    expect(stale).toMatchObject({ state: "repair", repairsMcp: false, explanation: "The hook command is older than this Ledger and cannot write to it." });
    const mcpOnly = agentConnection(status({ health: "outdated_command", mcp: { configPath: "/c", registered: true, command: command({ canWrite: false }) } }), true);
    expect(mcpOnly.repairsMcp).toBe(true);
    expect(mcpOnly.explanation).toContain("Copy the MCP command");
    const noHooks = agentConnection(status({ health: "missing_command", ownedHookCount: 0, hookCommand: null, mcp: { configPath: "/c", registered: true, command: command({ exists: false }) } }), false);
    expect(noHooks.actions).toEqual(["repair"]);
  });

  it("does not call an MCP-only connection unused, and says when hooks are turned off", () => {
    expect(agentConnection(status({ ownedHookCount: 0, hookCommand: null, lastObservedAt: null, lastReportAt: null, mcp: { configPath: "/c", registered: true, command: command() } }), true)).toMatchObject({ state: "connected", lastDataAt: null, actions: ["setup", "copy"] });
    expect(agentConnection(status({ hooksDisabled: true, health: "no_data_yet" }), false).explanation).toBe("Hooks are turned off in this client's settings.");
  });

  it("gives the browser extension the same states", () => {
    const base = { hostName: "com.gitrochi.ledger", manifestPath: "/m.json" };
    expect(browserConnection({ ...base, installed: false })).toMatchObject({ state: "not_set_up", actions: ["setup"] });
    expect(browserConnection({ ...base, installed: false, hostExists: false, extensionId: "x" })).toMatchObject({ state: "missing", actions: ["repair", "remove"] });
    expect(browserConnection({ ...base, installed: true, hostExists: true, lastDataAt: 5 })).toMatchObject({ state: "connected", lastDataAt: 5 });
    expect(browserConnection({ ...base, installed: true, hostExists: true, lastDataAt: null })).toMatchObject({ state: "no_data" });
  });

  it("copies an MCP registration that names the stable command and replaces an existing one", () => {
    expect(mcpCommand("claude", "/Users/me/Library/Application Support/Gitrochi/bin/gitrochi-ledger", false)).toBe("claude mcp add --scope user gitrochi-ledger -- '/Users/me/Library/Application Support/Gitrochi/bin/gitrochi-ledger' mcp");
    expect(mcpCommand("codex", "C:\\Users\\me\\AppData\\Roaming\\Gitrochi\\bin\\gitrochi-ledger.exe", true, true)).toBe("codex mcp remove gitrochi-ledger; codex mcp add gitrochi-ledger -- 'C:\\Users\\me\\AppData\\Roaming\\Gitrochi\\bin\\gitrochi-ledger.exe' mcp");
    expect(mcpCommand("claude", "/a'b", true)).toContain("claude mcp remove --scope user gitrochi-ledger; claude mcp add --scope user gitrochi-ledger -- '/a'\\''b' mcp");
  });

  it("demo connections repair an outdated command and never create the stable command on a refresh", async () => {
    const demo = new DemoLedgerBackend({ now: () => 1_000_000 });
    expect((await demo.call("integration_status", { client: "codex" })).health).toBe("outdated_command");
    expect((await demo.call("integration_command", { bundled: "x" })).refreshed).toBe(false);
    expect((await demo.call("integration_install", { client: "codex", bundled: "x" })).health).toBe("no_data_yet");
    expect((await demo.call("integration_remove", { client: "claude" })).health).toBe("not_installed");
  });
});
