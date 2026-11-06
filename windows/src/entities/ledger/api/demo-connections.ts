import type { LedgerConnectionCommand, LedgerIntegrationStatus, LedgerStableCommand, Ms } from "../model/types";

type Client = LedgerIntegrationStatus["client"];

const STABLE = "demo\\bin\\gitrochi-ledger.exe";

/**
 * The demo's local connections, one in each state the Connections list draws: Claude Code delivering, Codex running
 * an outdated command until it is repaired. Nothing outside the demo is read or written.
 * (macOS: Services/LedgerDemoBackend.swift, integration methods)
 */
export class DemoConnections {
  private stable = true;
  private hooks: Record<Client, { installed: boolean; command: string; schema: number; observedAt: Ms | null }>;
  private registered = new Set<Client>();

  constructor(now: Ms) {
    this.hooks = {
      claude: { installed: true, command: STABLE, schema: 8, observedAt: now - 5 * 60_000 },
      codex: { installed: true, command: "demo\\old\\gitrochi-ledger.exe", schema: 1, observedAt: null },
    };
  }

  call(method: string, args: Record<string, unknown>): unknown {
    if (method === "integration_command") {
      const created = args.create === true && !this.stable;
      if (args.create === true) this.stable = true;
      return { path: STABLE, exists: this.stable, current: this.stable, refreshed: created, held: false } satisfies LedgerStableCommand;
    }
    const client: Client = args.client === "codex" ? "codex" : "claude";
    const hooks = this.hooks[client];
    if (method === "integration_install") {
      this.stable = true;
      this.hooks[client] = { ...hooks, installed: true, command: STABLE, schema: 8 };
    } else if (method === "integration_remove") {
      this.hooks[client] = { ...hooks, installed: false };
    } else if (method === "integration_mcp") {
      if (args.action === "remove") this.registered.delete(client);
      else { this.stable = true; this.registered.add(client); }
    }
    return this.status(client, method === "integration_install" ? "install" : method === "integration_remove" ? "remove" : "status");
  }

  private status(client: Client, action: string): LedgerIntegrationStatus & { action: string } {
    const hooks = this.hooks[client];
    const command: LedgerConnectionCommand | null = hooks.installed
      ? { path: hooks.command, exists: true, executable: true, writesSchema: hooks.schema, version: "0.1.0", canWrite: hooks.schema >= 8, dbPath: "demo", sameDatabase: true }
      : null;
    const registered = this.registered.has(client);
    const health = !hooks.installed ? (registered ? "ok" : "not_installed") : command?.canWrite === false ? "outdated_command" : hooks.observedAt === null ? "no_data_yet" : "ok";
    return {
      client,
      action,
      installed: hooks.installed,
      cliPath: STABLE,
      ownedHookCount: hooks.installed ? (client === "claude" ? 8 : 7) : 0,
      expectedHookCount: client === "claude" ? 8 : 7,
      requiresClientTrust: client === "codex",
      hooksDisabled: false,
      hookCommand: command,
      mcp: { configPath: client === "claude" ? "demo\\.claude.json" : "demo\\.codex\\config.toml", registered, command: null },
      databaseSchema: 8,
      lastObservedAt: hooks.installed ? hooks.observedAt : null,
      lastReportAt: null,
      health,
    };
  }
}
