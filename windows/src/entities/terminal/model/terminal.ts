import { FitAddon } from "@xterm/addon-fit";
import { type ITheme, Terminal } from "@xterm/xterm";
import { ipc, type PtyEvent } from "@/shared/api";
import { basename, env, isMac, isWindows, toWslPath } from "@/shared/config";
import { t } from "@/shared/i18n";
import { Observable } from "@/shared/lib";
import { tools } from "@/shared/platform";
import { theme as appTheme } from "@/shared/ui";
import { shellBusy } from "../lib/panel-layout";
import { pastedImageName, shellPath } from "../lib/paths";
import { terminalMeta } from "../lib/host-session";
import { linkTokens } from "../lib/terminal-word";

/** Ctrl (⌘ on a Mac) is held: links get their underline only then, as in macOS (SwiftTerm hoverWithModifier) */
let linkModifier = false;
const trackModifier = (e: KeyboardEvent | MouseEvent) => (linkModifier = isMac() ? e.metaKey : e.ctrlKey);
if (typeof window !== "undefined") for (const type of ["keydown", "keyup", "mousemove"] as const) window.addEventListener(type, trackModifier, true);

export interface TerminalSpec {
  directory: string;
  /** 비우면 로그인 셸(Windows: PowerShell) */
  program?: string;
  args?: string[];
  env?: Record<string, string>;
  /** 탭 이름(셸이 제목을 정하면 그걸 따름) */
  title?: string;
  /** 프로세스를 띄울 윈도 쪽 폴더(비우면 directory). WSL 안 폴더(\\wsl.localhost\…)는 윈도 프로그램이 못 들어가서 따로 준다. */
  cwd?: string;
  /** The repository whose panel the tab is in: a relaunched app restores the tab there */
  repository?: string;
  /** A terminal host session to take up instead of starting a program (a tab restored after a relaunch) */
  resume?: string;
}

function termTheme(): ITheme {
  const css = getComputedStyle(document.documentElement);
  const v = (name: string, fallback: string) => css.getPropertyValue(name).trim() || fallback;
  const dark = appTheme.isDark;
  return {
    background: v("--term-bg", dark ? "#1c1c1f" : "#fcfcfc"),
    foreground: v("--text", dark ? "#e6e6e6" : "#1d1d1f"),
    cursor: v("--accent", "#2f6fec"),
    cursorAccent: v("--term-bg", "#fff"),
    selectionBackground: dark ? "rgba(90,140,255,0.40)" : "rgba(47,111,236,0.25)",
    // 밝은 배경에서도 읽히는 기본 색
    ...(dark
      ? {}
      : { yellow: "#a06c00", brightYellow: "#8a6200", white: "#6e6e73", brightWhite: "#3a3a3c", cyan: "#0a7d8c", brightCyan: "#0a6d7a" }),
  };
}

const fontFamily = '"Cascadia Mono", "Cascadia Code", Consolas, "D2Coding", "SF Mono", Menlo, "Malgun Gothic", monospace';

/** 그래프 아래 터미널 패널의 셸 하나. 패널을 숨겨도, 탭을 바꿔도 셸은 계속 살아 있다. */
export class TerminalSession extends Observable {
  readonly id = crypto.randomUUID();
  readonly term: Terminal;
  readonly fit = new FitAddon();
  /** xterm 이 그려지는 요소. 세션이 들고 있다가 패널이 보일 때 붙인다. */
  readonly host: HTMLDivElement;
  directory: string;
  title: string;
  running = false;
  started = false;
  exitCode: number | null = null;
  /** 보고 있지 않을 때 새 출력이 있었는지(탭에 점 표시) */
  unseenOutput = false;
  visible = false;
  onExit?: (code: number | null) => void;
  /** Takes a Ctrl-clicked web address or file path (the repository store opens it) */
  onOpenLink?: (text: string, candidates?: string[]) => void;
  /** The shell's process id while it runs; an agent typed into this tab has it as an ancestor */
  pid: number | null = null;
  /** A command or program runs in it (the tab's ring); a tab that runs a program instead of the shell is busy while it lives */
  busy = false;
  /** The fewest processes seen below the shell: what it has at its prompt */
  private idleChildren: number | null = null;

  private ptyId: string | null = null;
  /** The host session still to take up on the first start */
  private resumeId: string | null;
  private opened = false;
  private shellTitle: string | null = null;
  /** 설정 > 화면의 테마가 바뀌면 터미널 색도 */
  private unsubscribeTheme: () => void = () => undefined;

  constructor(readonly spec: TerminalSpec) {
    super();
    this.directory = spec.directory;
    this.resumeId = spec.resume ?? null;
    this.title = spec.title ?? basename(spec.directory);
    this.host = document.createElement("div");
    this.host.className = "terminal-host";
    this.term = new Terminal({
      fontFamily,
      fontSize: 13,
      lineHeight: 1.15,
      cursorBlink: true,
      allowProposedApi: true,
      scrollback: 10000,
      macOptionIsMeta: false,
      windowsPty: isWindows() ? { backend: "conpty" } : undefined,
      theme: termTheme(),
    });
    this.term.loadAddon(this.fit);
    this.term.onData((d) => {
      if (this.ptyId && this.running) void ipc.ptyWrite(this.ptyId, d).catch(() => {});
    });
    this.term.onResize(({ cols, rows }) => {
      if (this.ptyId && this.running) void ipc.ptyResize(this.ptyId, cols, rows).catch(() => {});
    });
    this.term.onTitleChange((text) => {
      this.shellTitle = text.trim() || null;
      this.updateTitle();
    });
    this.term.attachCustomKeyEventHandler((e) => this.keyFilter(e));
    this.term.registerLinkProvider({ provideLinks: (y, done) => done(this.linksOn(y)) });
    this.unsubscribeTheme = appTheme.subscribe(() => (this.term.options.theme = termTheme()));
    // Dropped files and pasted images go in as paths, like Windows Terminal. The webview hands over contents, not paths,
    // so each one is saved under the temp folder first (macOS: ShellView pastes the original path).
    this.host.addEventListener(
      "paste",
      (e) => {
        const files = Array.from(e.clipboardData?.files ?? []);
        if (!files.length) return;
        e.preventDefault();
        e.stopPropagation();
        void this.pasteFiles(files);
      },
      true,
    );
    this.host.addEventListener("dragover", (e) => {
      if (!e.dataTransfer?.types.includes("Files")) return;
      e.preventDefault();
      e.dataTransfer.dropEffect = "copy";
    });
    this.host.addEventListener("drop", (e) => {
      const files = Array.from(e.dataTransfer?.files ?? []);
      if (!files.length) return;
      e.preventDefault();
      void this.pasteFiles(files).then(() => this.focus());
    });
  }

  /** Web addresses and path-like words on a buffer line (1-based y), with cell ranges that follow wide characters */
  private linksOn(y: number) {
    const line = this.term.buffer.active.getLine(y - 1);
    if (!line) return undefined;
    let text = "";
    const cols: number[] = [];
    for (let x = 0; x < line.length; x++) {
      const cell = line.getCell(x);
      if (!cell || cell.getWidth() === 0) continue;
      const chars = cell.getChars() || " ";
      for (let i = 0; i < chars.length; i++) cols.push(x);
      text += chars;
    }
    const links = linkTokens(text).map((token) => ({
      text: token.text,
      range: { start: { x: cols[token.start] + 1, y }, end: { x: cols[token.end - 1] + 1, y } },
      decorations: { underline: linkModifier, pointerCursor: linkModifier },
      activate: (event: MouseEvent, value: string) => {
        if (isMac() ? event.metaKey : event.ctrlKey) this.onOpenLink?.(value, token.candidates);
      },
    }));
    return links.length ? links : undefined;
  }

  /** Saves the files under the temp folder and types their paths, each followed by a space */
  async pasteFiles(files: File[]) {
    const at = new Date();
    const paths: string[] = [];
    for (let i = 0; i < files.length; i++) {
      const name = pastedImageName(files[i], at, files.length > 1 ? `-${i + 1}` : "");
      paths.push(await ipc.writeTemp(name, new Uint8Array(await files[i].arrayBuffer())));
    }
    const wsl = !this.spec.program && (tools.path("shell") ?? "").startsWith("wsl:");
    this.term.paste(paths.map((p) => shellPath(p, wsl)).join(" ") + " ");
  }

  /** 앱 단축키는 터미널이 먹지 않게 넘기고, Windows 터미널처럼 Ctrl+C(선택 있을 때)·Ctrl+V 로 복사·붙여넣기 */
  private keyFilter(e: KeyboardEvent): boolean {
    if (e.type !== "keydown") return true;
    const k = e.key.toLowerCase();
    if (e.ctrlKey && e.code === "Backquote") return false;
    if (e.ctrlKey && e.key === "Tab") return false;
    if (isMac()) {
      if (e.metaKey && k !== "c" && k !== "v") return false; // ⌘ 단축키는 앱으로
      return true;
    }
    if (e.ctrlKey && !e.altKey && k === "c" && this.term.hasSelection()) {
      void navigator.clipboard.writeText(this.term.getSelection());
      this.term.clearSelection();
      return false;
    }
    if (e.ctrlKey && !e.altKey && k === "v") return false; // 브라우저 붙여넣기 이벤트로 처리
    if (e.ctrlKey && e.shiftKey && k === "c") {
      void navigator.clipboard.writeText(this.term.getSelection());
      return false;
    }
    if (e.ctrlKey && (e.shiftKey || e.altKey) && /^[a-z,]$/.test(k)) return false;
    if (e.ctrlKey && k === ",") return false;
    return true;
  }

  private updateTitle() {
    const text = this.spec.title ?? this.shellTitle ?? basename(this.directory);
    // PowerShell 기본 제목(실행 파일 경로)은 폴더 이름이 더 알아보기 쉽다
    const shown = /\\|\.exe$/i.test(text) ? this.spec.title ?? basename(this.directory) : text;
    if (shown !== this.title) {
      this.title = shown;
      this.emit();
    }
  }

  /** 패널에 붙이기. 처음 붙을 때 셸을 시작한다(크기를 알아야 해서). */
  attach(container: HTMLElement) {
    if (this.host.parentElement !== container) container.appendChild(this.host);
    if (!this.opened) {
      this.term.open(this.host);
      this.opened = true;
    }
    this.visible = true;
    this.unseenOutput = false;
    this.term.options.theme = termTheme();
    this.refit();
    if (!this.started) void this.start();
    this.emit();
  }

  detach() {
    this.host.remove();
    this.visible = false;
  }

  refit() {
    if (!this.host.isConnected || this.host.clientWidth < 20 || this.host.clientHeight < 20) return;
    try {
      this.fit.fit();
    } catch {
      /* 아직 그릴 수 없음 */
    }
  }

  focus() {
    this.term.focus();
  }

  /** What the status line names: the program this tab runs, or the shell */
  get program(): string {
    const name = (path: string) => basename(path).replace(/\.exe$/i, "");
    if (this.spec.program) return this.spec.title ?? name(this.spec.program);
    const shell = tools.path("shell") ?? (isWindows() ? "powershell.exe" : env.shell || "/bin/zsh");
    return shell.startsWith("wsl:") ? shell.slice(4) || "WSL" : name(shell);
  }

  /** The WSL distro the tab runs in: a "wsl:<distro>" shell, or a program started with wsl.exe -d <distro>; "" for the default one */
  get wslDistro(): string | null {
    if (!isWindows()) return null;
    if (!this.spec.program) {
      const shell = tools.path("shell") ?? "";
      return shell.startsWith("wsl:") ? shell.slice(4) : null;
    }
    if (!/^wsl(\.exe)?$/i.test(basename(this.spec.program))) return null;
    const args = this.spec.args ?? [];
    const at = args.findIndex((a) => a === "-d" || a === "--distribution");
    return at >= 0 ? args[at + 1] ?? "" : "";
  }

  /** Takes the number of processes below the shell from the panel's poll */
  noteChildren(count: number) {
    this.idleChildren = this.idleChildren === null ? count : Math.min(this.idleChildren, count);
    const busy = shellBusy(count, this.idleChildren);
    if (busy === this.busy) return;
    this.busy = busy;
    this.emit();
  }

  /** 셸에 글자를 보낸다(키를 친 것처럼) */
  send(data: string) {
    if (this.ptyId && this.running) return ipc.ptyWrite(this.ptyId, data);
    return Promise.resolve();
  }

  /** 설정 > 도구의 셸(직접 고른 것 → PowerShell/로그인 셸). "wsl:배포판" 이면 그 배포판의 셸을 저장소 폴더에서 연다. */
  private defaultShell(): { program: string; args: string[]; cwd?: string } {
    const program = tools.path("shell") ?? (isWindows() ? "powershell.exe" : env.shell || "/bin/zsh");
    if (program.startsWith("wsl:")) {
      return { program: "wsl.exe", args: ["-d", program.slice(4), "--cd", toWslPath(this.directory)], cwd: env.home };
    }
    return { program, args: tools.shellArgs(program) };
  }

  /** The terminal host session the tab shows, or will once it is first shown */
  get hostSession(): string | null {
    return this.resumeId ?? this.ptyId;
  }

  async start() {
    if (this.resumeId) return this.resume(this.resumeId);
    this.started = true;
    this.exitCode = null;
    this.running = true;
    this.idleChildren = null;
    this.busy = !!this.spec.program;
    this.emit();
    const shell = this.spec.program ? { program: this.spec.program, args: this.spec.args ?? [], cwd: this.spec.cwd } : this.defaultShell();
    const { program, args } = shell;
    const vars: Record<string, string> = {
      TERM: "xterm-256color",
      COLORTERM: "truecolor",
      TERM_PROGRAM: "Gitrochi",
      TERM_PROGRAM_VERSION: env.version,
      ...(this.spec.env ?? {}),
    };
    if (!isWindows()) vars.LANG = vars.LANG ?? "ko_KR.UTF-8";
    const ptyId = crypto.randomUUID();
    this.ptyId = ptyId;
    const meta = terminalMeta(this.spec.repository ?? this.directory, { ...this.spec, resume: undefined });
    try {
      const pid = await ipc.ptySpawn(ptyId, program, args, shell.cwd ?? this.directory, vars, this.term.cols, this.term.rows, meta, (ev) => this.received(ptyId, ev));
      // the shell may already have ended before the spawn call returned
      if (this.ptyId === ptyId && this.running) this.pid = pid;
    } catch (e) {
      this.running = false;
      this.busy = false;
      this.term.write(t("\r\n\u001b[31mCouldn't start the terminal: {0}\u001b[0m\r\n", String(e)));
      this.emit();
    }
  }

  private received(ptyId: string, ev: PtyEvent) {
    if (this.ptyId !== ptyId) return;
    if (ev.kind === "data") {
      this.term.write(ev.data);
      if (!this.visible && !this.unseenOutput) {
        this.unseenOutput = true;
        this.emit();
      }
    } else {
      this.running = false;
      this.pid = null;
      this.busy = false;
      this.exitCode = ev.code;
      this.emit();
      this.onExit?.(ev.code);
    }
  }

  /** Takes up a session the terminal host kept: its output so far, then what follows. Starting again later runs the program anew. */
  private async resume(id: string) {
    this.resumeId = null;
    this.started = true;
    this.exitCode = null;
    this.running = true;
    this.idleChildren = null;
    this.busy = !!this.spec.program;
    this.ptyId = id;
    this.emit();
    try {
      const session = await ipc.ptyAttach(id, this.term.cols, this.term.rows, (ev) => this.received(id, ev));
      if (this.ptyId === id && this.running) this.pid = session.pid;
    } catch (e) {
      this.running = false;
      this.busy = false;
      this.term.write(t("\r\n\u001b[31mCouldn't start the terminal: {0}\u001b[0m\r\n", String(e)));
      this.emit();
    }
  }

  /** Lets go of the program without ending it: the terminal host keeps it for the next run of the app */
  release() {
    this.ptyId = null;
    this.running = false;
    this.busy = false;
    this.emit();
  }

  /** 셸과 그 안에서 돌고 있는 프로그램을 끝낸다 */
  terminate() {
    if (this.ptyId && this.running) void ipc.ptyKill(this.ptyId).catch(() => {});
    this.running = false;
    this.busy = false;
    this.emit();
  }

  dispose() {
    this.terminate();
    this.unsubscribeTheme();
    this.detach();
    this.term.dispose();
  }
}
