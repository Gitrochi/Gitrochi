import type { AgentProcess, AgentScan, ProcessLink } from "@/shared/api";
import type { AgentKind } from "../model/agents";

/**
 * An agent Gitrochi did not start, in another app or typed into Gitrochi's own terminal, and the app that runs it
 * (macOS: ExternalAgent in Services/ExternalAgents.swift)
 */
export interface ExternalAgent {
  pid: number;
  kind: AgentKind;
  cwd: string;
  /** Seconds since 1970; null when unknown */
  started: number | null;
  /** The app window's process; null when no ancestor owns a window */
  hostPid: number | null;
  /** The app's executable, e.g. "WindowsTerminal.exe"; empty when unknown */
  hostExe: string;
  /** The shell of the Gitrochi terminal tab it was typed into; null when another app runs it */
  terminalPid: number | null;
}

const stem = (name: string) => name.toLowerCase().replace(/\.exe$/, "");

/**
 * Which agent a process is: its executable, or for npm installs the script that node or bun runs
 * (Claude Code and Gemini CLI run as `node …/cli.js`, the Codex shim as node starting codex-<target>.exe)
 */
export function externalAgentKind(name: string, args: readonly string[]): AgentKind | null {
  const exe = stem(name);
  if (exe === "claude") return "claude";
  if (exe === "codex" || exe.startsWith("codex-")) return "codex";
  if (exe === "gemini") return "gemini";
  if (exe !== "node" && exe !== "bun") return null;
  const script = args.join(" ").toLowerCase().replace(/\\/g, "/");
  if (script.includes("@anthropic-ai/claude-code") || /(^|\/)claude(\.js|\.cmd)?( |$)/.test(script)) return "claude";
  if (script.includes("@google/gemini-cli") || /(^|\/)gemini(\.js|\.cmd)?( |$)/.test(script)) return "gemini";
  if (script.includes("@openai/codex") || /(^|\/)codex(\.js|\.cmd)?( |$)/.test(script)) return "codex";
  return null;
}

/**
 * The app that runs an agent: the first ancestor that owns a visible window. "own" when Gitrochi itself is on the way:
 * its own sessions, and agents typed into its terminal.
 */
export function agentHost(ancestors: readonly ProcessLink[], own: number): ProcessLink | "own" | null {
  for (const link of ancestors) {
    if (link.pid === own) return "own";
    if (link.window) return link;
  }
  return null;
}

/**
 * The shell of the Gitrochi terminal tab an agent was typed into: the ancestor right below Gitrochi.
 * Null when Gitrochi started the agent directly, with no shell between.
 */
export function terminalShell(ancestors: readonly ProcessLink[], own: number): number | null {
  const at = ancestors.findIndex((link) => link.pid === own);
  return at > 0 ? ancestors[at - 1].pid : null;
}

/**
 * The scan's agents Gitrochi did not start, newest first; a wrapper's child agent counts once (the outermost process).
 * Below Gitrochi only agents typed into its terminal count.
 */
export function resolveExternalAgents(scan: AgentScan): ExternalAgent[] {
  const matched = new Map<number, { process: AgentProcess; kind: AgentKind }>();
  for (const process of scan.processes) {
    const kind = externalAgentKind(process.name, process.args);
    if (kind) matched.set(process.pid, { process, kind });
  }
  const found: ExternalAgent[] = [];
  for (const { process, kind } of matched.values()) {
    if (process.ancestors.some((a) => matched.get(a.pid)?.kind === kind)) continue;
    const host = agentHost(process.ancestors, scan.own);
    const agent = { pid: process.pid, kind, cwd: process.cwd, started: process.started > 0 ? process.started : null };
    if (host !== "own") {
      found.push({ ...agent, hostPid: host?.pid ?? null, hostExe: host?.name ?? "", terminalPid: null });
      continue;
    }
    const terminalPid = terminalShell(process.ancestors, scan.own);
    if (terminalPid !== null) found.push({ ...agent, hostPid: scan.own, hostExe: "", terminalPid });
  }
  return found.sort((a, b) => (b.started ?? 0) - (a.started ?? 0));
}

/** Path comparison key: forward slashes, no trailing slash, case-insensitive for Windows drive paths */
function pathKey(path: string) {
  const s = path.replace(/\\/g, "/").replace(/\/+$/, "");
  return /^[a-z]:\//i.test(s) || s.startsWith("//") ? s.toLowerCase() : s;
}

/** The deepest folder that contains the working directory (a worktree root or the folder itself), or null */
export function containingRoot(cwd: string, roots: readonly string[]): string | null {
  const path = pathKey(cwd);
  let best: string | null = null;
  for (const root of roots) {
    const r = pathKey(root);
    if ((path === r || path.startsWith(r + "/")) && (!best || r.length > pathKey(best).length)) best = root;
  }
  return best;
}

/** The working directory below its root ("" for the root itself) */
export function relativeFolder(cwd: string, root: string): string {
  return cwd.replace(/\\/g, "/").replace(/\/+$/, "").slice(pathKey(root).length).replace(/^\/+/, "");
}

const appNames: Record<string, string> = {
  windowsterminal: "Windows Terminal", code: "VS Code", "code - insiders": "VS Code Insiders", cursor: "Cursor", windsurf: "Windsurf",
  cmd: "Command Prompt", powershell: "Windows PowerShell", pwsh: "PowerShell", "wezterm-gui": "WezTerm", alacritty: "Alacritty",
  tabby: "Tabby", hyper: "Hyper", mintty: "Git Bash", cmux: "cmux", idea64: "IntelliJ IDEA", webstorm64: "WebStorm",
  pycharm64: "PyCharm", rider64: "Rider", goland64: "GoLand", zed: "Zed", sublime_text: "Sublime Text", terminal: "Terminal", iterm2: "iTerm2",
};

/** A readable name for the app's executable; unknown apps show their executable name without ".exe" */
export function appDisplayName(exe: string): string {
  const key = stem(exe);
  return appNames[key] ?? exe.replace(/\.exe$/i, "");
}
