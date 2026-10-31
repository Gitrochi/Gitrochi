import { ipc } from "@/shared/api";
import { dirname, env, isWindows, joinPath, samePath, settings, slash, toWslPath } from "@/shared/config";
import { t } from "@/shared/i18n";
import { Observable } from "@/shared/lib";
import { gitRaw, wslArgs } from "@/shared/platform";
import { nativeLedgerBackend } from "../api/backend";
import { ledgerStore } from "./store";
import type { LedgerAutoContinue, LedgerSettings } from "./types";

/** How Claude Code is started: a Windows program, or a command inside a WSL distribution */
export type AgentCommand = { kind: "native"; exe: string } | { kind: "wsl"; distro: string; path: string };

/** A launch the Ledger tracks: the session the agent reports to, and the MCP config that gives it the Ledger's tools */
export interface LedgerLaunch {
  sessionId: string;
  /** For `--mcp-config` (a WSL path for agents in WSL); null when Claude Code already has a gitrochi-ledger server */
  mcpConfig: string | null;
}

/** The app touches `app.alive` next to the database this often; hooks wait only while it is under 15 s old (§9.1) */
export const LEDGER_HEARTBEAT_MS = 5000;
export const DEFAULT_WAIT_SEC = 30;
/** A Windows program as Claude Code starts an MCP server: with backslashes, as the Connect sheet shows it */
const nativePath = (p: string) => (isWindows() ? p.replace(/\//g, "\\") : p);

/**
 * The repository a folder belongs to: its main checkout, also for a linked worktree, from `git rev-parse
 * --path-format=absolute --show-toplevel --git-common-dir`; the folder itself outside a repository.
 */
export function repositoryRoot(folder: string, output: string | null): string {
  const [top, common] = (output ?? "").split(/\r?\n/).map((l) => l.trim());
  if (!top) return folder;
  // a linked worktree shares the main checkout's .git; a bare or unusual layout counts as its own checkout
  return common && /[\\/]\.git$/.test(common) ? dirname(common) : top;
}

/** The repositories' policies in the ledger's auto-continue setting (`autoContinue.repositories`), as `track` reads them */
export function repositoryPolicies(autoContinue: LedgerSettings["autoContinue"]): Record<string, LedgerAutoContinue> {
  const all = autoContinue.repositories;
  return all && typeof all === "object" && !Array.isArray(all) ? (all as Record<string, LedgerAutoContinue>) : {};
}

/** A repository's policy, found as the app compares paths (on Windows without case and with either separator) */
export function repositoryPolicy(autoContinue: LedgerSettings["autoContinue"], repoPath: string): LedgerAutoContinue | null {
  return Object.entries(repositoryPolicies(autoContinue)).find(([path]) => samePath(path, repoPath))?.[1] ?? null;
}

/** The auto-continue setting with one repository's policy set, or removed with null; a repository keeps the key it had */
export function withRepositoryPolicy(autoContinue: LedgerSettings["autoContinue"], repoPath: string, policy: LedgerAutoContinue | null): LedgerSettings["autoContinue"] {
  const all = { ...repositoryPolicies(autoContinue) };
  const key = Object.keys(all).find((path) => samePath(path, repoPath)) ?? slash(repoPath).replace(/\/+$/, "");
  if (policy) all[key] = { enabled: policy.enabled, delaySec: policy.delaySec };
  else delete all[key];
  const { repositories: _old, ...rest } = autoContinue;
  return Object.keys(all).length ? { ...rest, repositories: all } : rest;
}

/**
 * The Ledger's MCP server for one launched agent. The session goes in its environment too, since Claude Code does not
 * promise that servers inherit the agent's; in WSL, WSLENV carries it to the Windows program.
 */
export function ledgerMcpConfig(command: string, sessionId: string, wsl: boolean): string {
  const vars: Record<string, string> = { GITROCHI_LEDGER_SESSION: sessionId, ...(wsl ? { WSLENV: "GITROCHI_LEDGER_SESSION" } : {}) };
  return JSON.stringify({ mcpServers: { "gitrochi-ledger": { command, args: ["mcp"], env: vars } } }, null, 2);
}

/** Whether Claude Code already has a server called gitrochi-ledger for this folder (user or project scope) */
async function hasLedgerServer(claude: AgentCommand, folder: string): Promise<boolean> {
  try {
    const args = ["mcp", "get", "gitrochi-ledger"];
    const r = claude.kind === "native" ? await ipc.run(claude.exe, args, { cwd: folder, timeoutMs: 20_000 }) : await ipc.run("wsl.exe", wslArgs(claude.distro, claude.path, args, { cwd: folder }), { env: { WSL_UTF8: "1" }, timeoutMs: 30_000 });
    return r.status === 0;
  } catch {
    // the check failed: adding the server for this launch is the safer guess
    return false;
  }
}

/**
 * Track agents I start (Settings › Ledger; off until a person turns it on, D13). For each Claude Code session the agent
 * center starts, the core's `track` registers a ledger session before launch, working out the project, title, base and
 * the repository's auto-continue policy from the checkout; the agent gets its ID as GITROCHI_LEDGER_SESSION, the ledger
 * CLI's hooks and the Ledger's tools. While tracking is on, the app touches `ledger/app.alive` so waiting hooks know a
 * person can answer here (docs/ledger/DESIGN.md §7.11, §9). Only with the Ledger preview; without it nothing here runs.
 * (macOS: Services/Agents.swift)
 */
export class LedgerTracking extends Observable {
  /** Why the last launch could not be tracked; it started untracked */
  lastError: string | null = null;
  private heartbeat: ReturnType<typeof setInterval> | null = null;
  private cliPath: Promise<string | null> | null = null;
  private cliFolder = "";

  /** Tracking applies: the Ledger preview is on and a person turned it on */
  get on(): boolean {
    return !!env.ledgerPreview && settings.get<boolean>("ledgerTrackAgents", false);
  }

  /** The switch itself, as Settings shows it */
  get chosen(): boolean {
    return settings.get<boolean>("ledgerTrackAgents", false);
  }

  setChosen(on: boolean) {
    settings.set("ledgerTrackAgents", on || undefined);
    this.emit();
    void this.syncHeartbeat();
  }

  /** Give them the Ledger tools: the MCP server for each tracked agent (on unless a person turns it off) */
  get tools(): boolean {
    return settings.get<boolean>("ledgerAgentTools", true);
  }

  setTools(on: boolean) {
    settings.set("ledgerAgentTools", on ? undefined : false);
    this.emit();
  }

  /** The bundled ledger CLI (`gitrochi-ledger.exe` next to the app's other tools), when it is there */
  cli(): Promise<string | null> {
    if (this.cliFolder !== env.resourceDir) this.cliPath = null;
    this.cliFolder = env.resourceDir;
    this.cliPath ??= (async () => {
      if (!env.resourceDir) return null;
      const path = joinPath(env.resourceDir, "gitrochi-ledger.exe");
      try {
        return (await ipc.exists(path)) ? path : null;
      } catch {
        return null;
      }
    })();
    return this.cliPath;
  }

  /** The CLI the hooks file names, only while tracking is on */
  async hooksCli(): Promise<string | null> {
    return this.on ? this.cli() : null;
  }

  /**
   * Registers a Claude Code launch in `folder` with the core's `track`. The app adds what the core compares by exact path:
   * the project bound to the repository and the repository's own policy, found as the app compares paths. Null when
   * tracking is off; a failure is kept in `lastError` and the agent starts untracked.
   */
  async launch(o: { agentId: string; folder: string; claude: AgentCommand; dir: string }): Promise<LedgerLaunch | null> {
    if (!this.on) return null;
    try {
      const cli = await this.cli();
      if (!cli) throw new Error(t("gitrochi-ledger.exe was not found next to Gitrochi."));
      const wsl = o.claude.kind === "wsl";
      // a server of the person's own with that name wins: the launch's would hide it (§15)
      const [repoPath, ownServer] = await Promise.all([this.repository(o.folder), this.tools ? hasLedgerServer(o.claude, o.folder) : Promise.resolve(false)]);
      const store = ledgerStore(repoPath);
      const [projects, stored] = await Promise.all([store.readProjects(), store.readSettings()]);
      const bound = projects.find((p) => p.repoPath && samePath(p.repoPath, repoPath));
      const policy = repositoryPolicy(stored.autoContinue, repoPath);
      const { session } = await store.backend.call("track", { cwd: o.folder, repoPath, agentId: o.agentId, ...(bound ? { project: bound.key } : {}), ...(policy ? { autoContinue: policy } : {}) });
      void store.refresh(true);
      let mcpConfig: string | null = null;
      if (this.tools && !ownServer) {
        const file = joinPath(o.dir, `${o.agentId}.mcp.json`);
        await ipc.writeText(file, ledgerMcpConfig(wsl ? toWslPath(cli) : nativePath(cli), session.id, wsl));
        mcpConfig = wsl ? toWslPath(file) : file;
      }
      this.setError(null);
      return { sessionId: session.id, mcpConfig };
    } catch (e) {
      this.setError(e instanceof Error ? e.message : String(e));
      return null;
    }
  }

  private setError(message: string | null) {
    if (message === this.lastError) return;
    this.lastError = message;
    this.emit();
  }

  private async repository(folder: string): Promise<string> {
    try {
      const r = await gitRaw(["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir"], folder, { timeoutMs: 15_000 });
      return repositoryRoot(folder, r.status === 0 ? r.stdout : null);
    } catch {
      return folder;
    }
  }

  /** Starts or stops the heartbeat with tracking (not for the demo, which has no database) */
  async syncHeartbeat() {
    if (!this.on || env.ledgerDemo) {
      if (this.heartbeat) clearInterval(this.heartbeat);
      this.heartbeat = null;
      return;
    }
    if (this.heartbeat) return;
    try {
      const info = await nativeLedgerBackend.call("info", {});
      if (!info.enabled || !this.on || this.heartbeat) return;
      const file = joinPath(dirname(info.dbPath), "app.alive");
      // new content each time: rewriting an empty file does not move its time on Windows
      const touch = () => void ipc.writeText(file, String(Math.floor(Date.now() / 1000))).catch(() => {});
      touch();
      this.heartbeat = setInterval(touch, LEDGER_HEARTBEAT_MS);
    } catch {
      // no database: the hooks then answer nothing and the terminal asks (D10)
    }
  }
}

export const ledgerTracking = new LedgerTracking();
