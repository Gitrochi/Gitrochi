import { ipc } from "@/shared/api";
import { basename, env, isWindows, joinPath, settings } from "@/shared/config";
import { t } from "@/shared/i18n";
import { Observable } from "@/shared/lib";
import { commandVersion, findCommand, isExecutable, listDistros } from "./wsl";

/**
 * 외부 프로그램(git·AI CLI·gh·셸) 위치. PC 마다 설치 위치가 달라
 * ① 설정에서 직접 고른 경로 → ② 흔한 설치 위치 → ③ PATH 순서로 찾는다.
 */
export type ToolId = "git" | "claude" | "codex" | "gemini" | "gh" | "node" | "shell";

export interface ToolInfo {
  id: ToolId;
  title: string;
  detail: string;
  required?: boolean;
  /** PATH 에서 찾을 이름 */
  command: string;
  versionArgs: string[];
  install?: string;
}

export const toolList: ToolInfo[] = [
  { id: "git", title: "Git", detail: t("Used for all repository operations."), required: true, command: "git", versionArgs: ["--version"], install: "https://git-scm.com/download/win" },
  { id: "claude", title: "Claude Code", detail: t("Writing and agent sessions with your Claude login"), command: "claude", versionArgs: ["--version"], install: "https://claude.com/claude-code" },
  { id: "codex", title: "Codex CLI", detail: t("Writing and agent sessions with your ChatGPT login"), command: "codex", versionArgs: ["--version"], install: "https://developers.openai.com/codex/cli" },
  { id: "gemini", title: "Gemini CLI", detail: t("Writing and agent sessions with your Google login"), command: "gemini", versionArgs: ["--version"], install: "https://github.com/google-gemini/gemini-cli" },
  { id: "gh", title: "GitHub CLI (gh)", detail: t("When importing the gh login as a GitHub account"), command: "gh", versionArgs: ["--version"], install: "https://cli.github.com" },
  { id: "node", title: "Node.js", detail: t("Read-only repository assistant and MCP connection (Node.js 22 or later)"), command: "node", versionArgs: ["--version"], install: "https://nodejs.org/" },
  { id: "shell", title: t("Terminal shell"), detail: t("Shell opened in the terminal panel below (PowerShell, cmd, Git Bash, etc.)"), command: "", versionArgs: [] },
];

export type ToolSource = "custom" | "auto" | "none";

interface ToolState {
  path: string | null;
  source: ToolSource;
  version: string | null;
}

/** WSL 안에 설치된 도구(배포판 + 리눅스 절대 경로) */
export interface WslTool {
  distro: string;
  path: string;
  version?: string | null;
  /** 자동으로 찾은 것인지(사용자가 고른 게 아니면 true) */
  auto?: boolean;
}

/** WSL 에서도 돌릴 수 있는 도구(AI CLI) */
export const wslCapable: ToolId[] = ["claude", "codex", "gemini"];

export type ToolCommand = { kind: "native"; exe: string } | { kind: "wsl"; distro: string; path: string };

/** 흔한 설치 위치(PATH 에 없을 때) */
function candidates(id: ToolId): string[] {
  const home = env.home,
    roaming = env.appData,
    local = env.localAppData;
  if (isWindows()) {
    const pf = ["C:/Program Files", "C:/Program Files (x86)"];
    switch (id) {
      case "git":
        return [...pf.map((p) => p + "/Git/cmd/git.exe"), joinPath(local, "Programs/Git/cmd/git.exe"), joinPath(home, "scoop/shims/git.exe")];
      case "claude":
        return [joinPath(home, ".local/bin/claude.exe"), joinPath(roaming, "npm/claude.cmd"), joinPath(home, "scoop/shims/claude.exe")];
      case "codex":
        return [joinPath(roaming, "npm/codex.cmd"), joinPath(home, ".local/bin/codex.exe"), joinPath(home, "scoop/shims/codex.exe")];
      case "gemini":
        return [joinPath(roaming, "npm/gemini.cmd"), joinPath(home, "scoop/shims/gemini.exe")];
      case "gh":
        return [...pf.map((p) => p + "/GitHub CLI/gh.exe"), joinPath(local, "Programs/GitHub CLI/gh.exe"), joinPath(home, "scoop/shims/gh.exe")];
      case "node":
        return [...pf.map((p) => p + "/nodejs/node.exe"), joinPath(home, "scoop/shims/node.exe")];
      case "shell":
        return ["C:/Program Files/PowerShell/7/pwsh.exe", "C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"];
    }
  }
  const brew = ["/opt/homebrew/bin", "/usr/local/bin"];
  switch (id) {
    case "git":
      return [...brew.map((b) => b + "/git"), "/usr/bin/git"];
    case "claude":
      return [joinPath(home, ".local/bin/claude"), joinPath(home, ".claude/local/claude"), ...brew.map((b) => b + "/claude")];
    case "codex":
      return [...brew.map((b) => b + "/codex"), joinPath(home, ".local/bin/codex")];
    case "gemini":
      return [...brew.map((b) => b + "/gemini"), joinPath(home, ".local/bin/gemini")];
    case "gh":
      return brew.map((b) => b + "/gh");
    case "node":
      return brew.map((b) => b + "/node");
    case "shell":
      return [env.shell, "/bin/zsh", "/bin/bash"];
  }
}

class Tools extends Observable {
  state: Record<ToolId, ToolState> = Object.fromEntries(toolList.map((tool) => [tool.id, { path: null, source: "none", version: null }])) as Record<ToolId, ToolState>;

  private custom(): Partial<Record<ToolId, string>> {
    return settings.get<Partial<Record<ToolId, string>>>("toolPaths", {});
  }

  /** WSL 에서 실행하도록 정한 도구 */
  wsl(id: ToolId): WslTool | null {
    return settings.get<Partial<Record<ToolId, WslTool>>>("toolWsl", {})[id] ?? null;
  }

  private setWslConfig(id: ToolId, v: WslTool | null) {
    const all = { ...settings.get<Partial<Record<ToolId, WslTool>>>("toolWsl", {}) };
    if (v) all[id] = v;
    else delete all[id];
    settings.set("toolWsl", all);
    this.emit();
  }

  /** 실행 방법: WSL 로 정했으면 WSL, 아니면 윈도 실행 파일 */
  command(id: ToolId): ToolCommand | null {
    const w = this.wsl(id);
    if (w) return { kind: "wsl", distro: w.distro, path: w.path };
    const p = this.path(id);
    return p ? { kind: "native", exe: p } : null;
  }

  available(id: ToolId) {
    return !!this.command(id);
  }

  /** 화면에 보여 줄 위치 */
  describe(id: ToolId): string | null {
    const w = this.wsl(id);
    if (w) return `WSL (${w.distro}) ${w.path}`;
    return this.path(id);
  }

  /** 이 도구를 WSL 배포판 안의 것으로 쓴다 */
  async useWsl(id: ToolId, distro: string, auto = false) {
    const info = this.toolList(id);
    const found = await findCommand(distro, info.command);
    if (!found.path) {
      throw new Error(
        t("Couldn't find {1} in {0}.\n", distro, info.command) +
          t("In a WSL terminal, run 'which {0}' to find where it's installed, then choose that file under \\\\wsl.localhost\\{1}\\… with 'Locate…'.\n\n(What was checked: {2})", info.command, distro, found.detail),
      );
    }
    await this.saveWsl(id, distro, found.path, auto);
  }

  /** 불러오기로 고른 \\wsl.localhost\배포판\… 파일을 WSL 도구로 쓴다 */
  async useWslPath(id: ToolId, distro: string, path: string) {
    if (!(await isExecutable(distro, path))) throw new Error(t("{0} isn't an executable file in {1} (check chmod +x).", path, distro));
    await this.saveWsl(id, distro, path, false);
  }

  private async saveWsl(id: ToolId, distro: string, path: string, auto: boolean) {
    this.setWslConfig(id, { distro, path, auto, version: null });
    const version = await commandVersion(distro, path);
    const cur = this.wsl(id);
    if (cur && cur.path === path) this.setWslConfig(id, { ...cur, version });
  }

  /** 윈도에 설치된 것으로 되돌린다 */
  useWindows(id: ToolId) {
    this.setWslConfig(id, null);
  }

  /**
   * 윈도에서 못 찾은 AI CLI 를 기본 WSL 배포판에서 한 번 찾아 둔다(찾으면 기억해서 다음부터는 바로 씀).
   * WSL 을 깨우는 데 몇 초 걸릴 수 있어 시작하고 조금 뒤 뒤에서 한다.
   */
  async probeWsl() {
    if (!isWindows()) return;
    const missing = wslCapable.filter((id) => !this.path(id) && !this.wsl(id));
    if (!missing.length || settings.get("wslProbed", false)) return;
    const distros = await listDistros();
    settings.set("wslProbed", true);
    if (!distros.length) return;
    for (const id of missing) {
      try {
        await this.useWsl(id, distros[0], true);
      } catch {
        /* 그 배포판에 없음 */
      }
    }
  }

  path(id: ToolId): string | null {
    return this.state[id].path;
  }

  async detectAll() {
    await Promise.all(toolList.map((tool) => this.detect(tool.id)));
  }

  async detect(id: ToolId) {
    const info = toolList.find((tool) => tool.id === id)!;
    const custom = this.custom()[id];
    let path: string | null = null;
    let source: ToolSource = "none";
    if (custom && custom.startsWith("wsl:")) {
      // 셸을 WSL 배포판으로 고른 경우
      path = custom;
      source = "custom";
    } else if (custom && (await ipc.exists(custom))) {
      path = custom;
      source = "custom";
    } else {
      if (id === "shell") path = env.shell || null;
      else {
        path = await ipc.which(info.command);
        if (!path) for (const c of candidates(id)) if (c && (await ipc.exists(c))) { path = c; break; }
      }
      if (path) source = "auto";
    }
    this.state[id] = { path, source, version: null };
    this.emit();
    if (path && info.versionArgs.length && !path.startsWith("wsl:")) void this.readVersion(id, path);
  }

  private async readVersion(id: ToolId, path: string) {
    try {
      const r = await ipc.run(path, this.toolList(id).versionArgs, { cwd: env.temp, timeoutMs: 20000 });
      const line = (r.stdout || r.stderr).trim().split(/\r?\n/)[0] ?? "";
      if (this.state[id].path === path) {
        this.state[id] = { ...this.state[id], version: r.status === 0 ? line.slice(0, 80) : null };
        this.emit();
      }
    } catch {
      /* 버전을 못 읽어도 경로는 쓴다 */
    }
  }

  private toolList(id: ToolId) {
    return toolList.find((tool) => tool.id === id)!;
  }

  /** 직접 고른 실행 파일로 바꾼다. 실행해 보고 안 되면 이유를 던진다. */
  async setCustom(id: ToolId, path: string) {
    const info = this.toolList(id);
    if (info.versionArgs.length) {
      let r;
      try {
        r = await ipc.run(path, info.versionArgs, { cwd: env.temp, timeoutMs: 20000 });
      } catch (e) {
        throw new Error(t("Couldn't run {0}: {1}", basename(path), String(e)));
      }
      if (r.status !== 0) throw new Error(t("{0} didn't respond correctly (exit code {1}). Check that it's the {2} executable.", basename(path), r.status, info.title));
    }
    settings.set("toolPaths", { ...this.custom(), [id]: path });
    await this.detect(id);
  }

  async resetToAuto(id: ToolId) {
    const c = { ...this.custom() };
    delete c[id];
    settings.set("toolPaths", c);
    await this.detect(id);
  }

  /** 셸을 WSL 배포판으로(path 는 "wsl:배포판") */
  setShellWsl(distro: string) {
    settings.set("toolPaths", { ...this.custom(), shell: `wsl:${distro}` });
    void this.detect("shell");
  }

  /** 셸에 맞는 시작 인자 */
  shellArgs(path: string): string[] {
    const n = basename(path).toLowerCase();
    if (n.startsWith("pwsh") || n.startsWith("powershell")) return ["-NoLogo"];
    if (n.startsWith("bash") || n.startsWith("zsh") || n.startsWith("fish")) return isWindows() ? ["--login", "-i"] : ["-l"];
    if (n.startsWith("cmd")) return [];
    return isWindows() ? [] : ["-l"];
  }
}

export const tools = new Tools();
