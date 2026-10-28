import type { TerminalSession } from "@/entities/terminal";
import { ipc } from "@/shared/api";
import { env, isWindows, joinPath, samePath, settings, slash, toWslPath, wslDistroOf } from "@/shared/config";
import { t } from "@/shared/i18n";
import { Observable } from "@/shared/lib";
import { tempFile, type ToolId, tools, withWslEnv, wslArgs } from "@/shared/platform";
import { agentArguments } from "../lib/arguments";
import { containingRoot, type ExternalAgent, resolveExternalAgents } from "../lib/external-agents";

/** 세션 상태: Claude Code 는 훅 이벤트로 자세히, 다른 에이전트는 실행 중/종료만 */
export type AgentStatus = "starting" | "working" | "permission" | "waiting" | "running" | "ended";

export const agentStatusTitle: Record<AgentStatus, string> = {
  starting: t("Waiting for input"),
  working: t("Working"),
  permission: t("Needs permission"),
  waiting: t("Waiting for input"),
  running: t("Running"),
  ended: t("Ended"),
};

export const isActiveStatus = (s: AgentStatus) => s === "working" || s === "permission" || s === "running";

/** 아래 터미널에서 띄울 수 있는 코딩 에이전트 */
export type AgentKind = "claude" | "codex" | "gemini";

export interface AgentKindInfo {
  id: AgentKind;
  title: string;
  tool: ToolId;
  modes: { value: string; label: string }[];
}

export const agentKinds: AgentKindInfo[] = [
  {
    id: "claude",
    title: "Claude Code",
    tool: "claude",
    modes: [
      { value: "", label: t("Default (ask every time)") },
      { value: "acceptEdits", label: t("Auto-approve file edits") },
      { value: "plan", label: t("Plan only") },
      { value: "auto", label: t("Auto") },
      { value: "bypassPermissions", label: t("Skip all permission checks") },
    ],
  },
  {
    id: "codex",
    title: "Codex (ChatGPT)",
    tool: "codex",
    modes: [
      { value: "", label: t("Default") },
      { value: "read-only", label: t("Read-only") },
      { value: "workspace-write", label: t("Allow writing to the working folder") },
      { value: "bypass", label: t("Skip all permission checks") },
    ],
  },
  {
    id: "gemini",
    title: "Gemini CLI",
    tool: "gemini",
    modes: [
      { value: "", label: t("Default (ask every time)") },
      { value: "auto_edit", label: t("Auto-approve file edits") },
      { value: "plan", label: t("Plan only (read-only)") },
      { value: "yolo", label: t("Skip all permission checks") },
    ],
  },
];

export const agentKind = (id: AgentKind) => agentKinds.find((k) => k.id === id) ?? agentKinds[0];

export interface AgentSession {
  id: string;
  kind: AgentKind;
  path: string;
  task: string;
  /** Permission mode it was started with ("" = default) */
  mode: string;
  created: number;
  status: AgentStatus;
  detail: string | null;
  updated: number;
}

/** 세션을 띄울 저장소 창(탭) — 순환 참조를 피하려고 필요한 것만 */
export interface AgentHost {
  readonly terminals: readonly TerminalSession[];
  newTerminal(path: string, spec?: { program?: string; args?: string[]; env?: Record<string, string>; title?: string; cwd?: string }): TerminalSession;
  focusTerminal(term: TerminalSession): void;
}

/** An agent typed into a tab of the terminal below, and that tab */
export interface TerminalAgent {
  agent: ExternalAgent;
  term: TerminalSession;
  host: AgentHost;
}

const events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "Notification", "Stop", "SessionEnd"];

/**
 * Gitrochi 가 띄운 에이전트(Claude Code·Codex·Gemini CLI) 세션 추적. (맥 버전 AgentCenter)
 *
 * 세션은 아래 터미널 패널의 탭에서 돈다. 띄울 때 `--settings` 로 훅을 더해 두면(사용자 설정·훅은 그대로 유지)
 * 각 이벤트마다 Gitrochi 실행 파일이 `--agent-hook` 으로 불려 <데이터>/agents/<id>.state 에 마지막 상태를 쓴다.
 */
class AgentCenter extends Observable {
  sessions: AgentSession[] = [];
  private dir = "";
  private hooksFile = "";
  private terminals = new Map<string, { term: TerminalSession; host: AgentHost }>();
  private timer: ReturnType<typeof setInterval> | null = null;

  async init() {
    this.dir = joinPath(env.dataDir, "agents");
    this.hooksFile = joinPath(this.dir, "hooks.json");
    await ipc.mkdirs(this.dir);
    // 지난번 실행의 세션은 터미널과 함께 끝났으므로 지운다
    for (const name of await ipc.list(this.dir)) if (/\.(meta|state|tmp)$/.test(name)) await ipc.remove(joinPath(this.dir, name));
    await this.installHooks();
    this.timer = setInterval(() => void this.load(), 2000);
  }

  /** WSL 안의 Claude Code 가 읽는 훅 설정(윈도 실행 파일을 /mnt/c/… 경로로 부른다) */
  private get hooksWslFile() {
    return joinPath(this.dir, "hooks-wsl.json");
  }

  private async installHooks() {
    // Windows 경로도 / 로 쓰면 cmd·Git Bash 어느 셸로 실행돼도 그대로 통한다
    const exe = isWindows() ? slash(env.exe) : env.exe;
    const hooks: Record<string, unknown> = {};
    for (const e of events) {
      hooks[e] = [{ matcher: "", hooks: [{ type: "command", command: `"${exe}" --agent-hook ${e}`, timeout: 5 }] }];
    }
    await ipc.writeText(this.hooksFile, JSON.stringify({ hooks }, null, 2));
    if (isWindows()) {
      const wslExe = toWslPath(env.exe).replace(/'/g, "'\\''");
      const wslHooks: Record<string, unknown> = {};
      for (const e of events) wslHooks[e] = [{ matcher: "", hooks: [{ type: "command", command: `'${wslExe}' --agent-hook ${e}`, timeout: 10 }] }];
      await ipc.writeText(this.hooksWslFile, JSON.stringify({ hooks: wslHooks }, null, 2));
    }
  }

  sessionsIn(path: string) {
    return this.sessions.filter((s) => samePath(s.path, path));
  }

  private async json(name: string): Promise<Record<string, unknown> | null> {
    const text = await ipc.readText(joinPath(this.dir, name));
    if (!text) return null;
    try {
      return JSON.parse(text);
    } catch {
      return null;
    }
  }

  async load() {
    if (!this.dir) return;
    const names = await ipc.list(this.dir);
    const list: AgentSession[] = [];
    for (const name of names.filter((n) => n.endsWith(".meta"))) {
      const id = name.slice(0, -5);
      const meta = await this.json(name);
      if (!meta) continue;
      const created = Number(meta.created) || 0;
      let status: AgentStatus = "starting";
      let detail: string | null = null;
      let updated = created;
      const state = await this.json(id + ".state");
      if (state) {
        updated = Number(state.time) || created;
        const payload = (state.payload ?? {}) as Record<string, unknown>;
        switch (state.event) {
          case "SessionStart":
            status = "starting";
            break;
          case "UserPromptSubmit":
            status = "working";
            break;
          case "PreToolUse":
            status = "working";
            detail = (payload.tool_name as string) ?? null;
            break;
          case "PermissionRequest":
            status = "permission";
            detail = (payload.tool_name as string) ?? null;
            break;
          case "Notification": {
            const m = (payload.message as string) ?? null;
            status = m?.toLowerCase().includes("permission") ? "permission" : "waiting";
            detail = m;
            break;
          }
          case "Stop":
            status = "waiting";
            break;
          case "SessionEnd":
            status = "ended";
            break;
        }
      }
      const kind = (meta.kind as AgentKind) ?? "claude";
      // 훅이 없는 에이전트는 터미널이 살아 있으면 실행 중
      if (kind !== "claude" && !state) status = "running";
      const term = this.terminals.get(id);
      if (!term || !term.term.running) status = "ended";
      list.push({ id, kind, path: String(meta.path ?? ""), task: String(meta.task ?? ""), mode: String(meta.mode ?? ""), created, status, detail, updated });
    }
    list.sort((a, b) => b.created - a.created);
    if (JSON.stringify(list) !== JSON.stringify(this.sessions)) {
      this.sessions = list;
      this.emit();
    }
  }

  /** 마지막으로 고른 에이전트(빠른 시작에 씀). 없으면 설치된 것 중 첫 번째. */
  get defaultKind(): AgentKind {
    const saved = settings.get<AgentKind | null>("agentKind", null);
    if (saved && tools.available(agentKind(saved).tool)) return saved;
    return agentKinds.find((k) => tools.available(k.tool))?.id ?? "claude";
  }

  /** 폴더에서 에이전트를 아래 터미널의 새 탭으로 띄운다. task 가 있으면 첫 요청으로 보낸다. */
  async start(host: AgentHost, kind: AgentKind, path: string, task: string, mode: string | null) {
    const info = agentKind(kind);
    const cmd = tools.command(info.tool);
    if (!cmd) throw new Error(t("Couldn't find {0}. Locate the executable in Settings > Tools or find it in WSL.", info.title));
    const inWsl = cmd.kind === "wsl";
    settings.set("agentKind", kind);
    const id = crypto.randomUUID().toLowerCase();
    const text = task.trim();
    const meta = { id, kind, path, task: text, mode: mode ?? "", created: Date.now() / 1000 };
    await ipc.writeText(joinPath(this.dir, id + ".meta"), JSON.stringify(meta));
    const args = agentArguments(kind, inWsl ? toWslPath(this.hooksWslFile) : this.hooksFile, text, mode);
    const title = info.title.split(" (")[0];
    let term: TerminalSession;
    if (cmd.kind === "native") {
      term = host.newTerminal(path, { program: cmd.exe, args, env: { GITROCHI_AGENT_ID: id }, title });
    } else {
      // WSL: 작업 폴더를 리눅스 경로로 바꾸고, 훅이 부르는 윈도 실행 파일까지 세션 ID 가 넘어가게(WSLENV)
      const mapped: string[] = [];
      for (const a of args) {
        if (a.includes("\n")) mapped.push("@file:" + (await tempFile("task.txt", a)).wsl);
        else mapped.push(a);
      }
      term = host.newTerminal(path, {
        program: "wsl.exe",
        args: wslArgs(cmd.distro, cmd.path, mapped, { cwd: path, interactive: true }),
        env: withWslEnv({ GITROCHI_AGENT_ID: id }),
        cwd: wslDistroOf(path) ? env.home : undefined,
        title: `${title} · WSL`,
      });
    }
    this.terminals.set(id, { term, host });
    term.onExit = () => void this.load();
    await this.load();
  }

  focus(s: AgentSession) {
    const term = this.terminals.get(s.id);
    if (term) term.host.focusTerminal(term.term);
  }

  stop(s: AgentSession) {
    this.terminals.get(s.id)?.term.terminate();
    void this.load();
  }

  async remove(id: string) {
    for (const ext of [".meta", ".state", ".state.tmp"]) await ipc.remove(joinPath(this.dir, id + ext));
    this.terminals.delete(id);
    this.sessions = this.sessions.filter((s) => s.id !== id);
    this.emit();
  }

  async clearEnded() {
    for (const s of this.sessions.filter((x) => x.status === "ended")) await this.remove(s.id);
  }

  canFocus(s: AgentSession) {
    return s.status !== "ended" && this.terminals.has(s.id);
  }

  dispose() {
    if (this.timer) clearInterval(this.timer);
  }

  /** Agents running in other apps (Windows Terminal, VS Code …), from the last scan (macOS: AgentCenter.external) */
  external: ExternalAgent[] = [];
  private externalScanned = 0;
  private externalScanning = false;

  /** Scans the process table; several open Agents panels share one scan at most every 5 seconds */
  async refreshExternal(now = Date.now()) {
    if (this.externalScanning || now - this.externalScanned < 4500) return;
    this.externalScanning = true;
    try {
      const list = resolveExternalAgents(await ipc.externalAgents());
      this.externalScanned = Date.now();
      if (JSON.stringify(list) !== JSON.stringify(this.external)) { this.external = list; this.emit(); }
    } catch {
      // a failed scan keeps the last list; the next refresh tries again
    } finally {
      this.externalScanning = false;
    }
  }

  /** The agents in other apps working in one of the folders (the repository and its worktrees) */
  externalIn(roots: string[]) {
    return this.external.filter((a) => a.terminalPid === null && containingRoot(a.cwd, roots) !== null);
  }

  /**
   * Agents typed into a tab of the terminal below, working in one of the folders, with the tab they run in
   * (macOS: AgentCenter.terminalAgents). A tab that runs a session started here is that session's.
   */
  terminalAgentsIn(roots: string[], hosts: readonly AgentHost[]): TerminalAgent[] {
    const sessionTabs = new Set([...this.terminals.values()].map((s) => s.term));
    return this.external.flatMap((agent) => {
      if (agent.terminalPid === null || containingRoot(agent.cwd, roots) === null) return [];
      for (const host of hosts) {
        const term = host.terminals.find((x) => x.running && x.pid === agent.terminalPid);
        if (term) return sessionTabs.has(term) ? [] : [{ agent, term, host }];
      }
      return [];
    });
  }

  /** Brings the app that runs the agent to the front */
  async bringForward(agent: ExternalAgent) {
    if (agent.hostPid === null) throw new Error(t("The app running this agent was not found."));
    await ipc.bringAppForward(agent.hostPid);
  }
}

export const agents = new AgentCenter();
