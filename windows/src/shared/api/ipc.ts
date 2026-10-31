import { Channel, invoke as tauriInvoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { nativeError, nativeText } from "@/shared/i18n";

/** 백엔드(Rust) 명령 모음 */

/** 백엔드 오류·출력의 영어 메시지는 화면 언어로 바꿔서 넘긴다 */
const invoke = <T>(cmd: string, args?: Record<string, unknown>) =>
  tauriInvoke<T>(cmd, args).then(
    (r) => (r && typeof r === "object" && "stderr" in r ? ({ ...r, stderr: nativeText(String((r as { stderr: unknown }).stderr)) } as T) : r),
    (e) => {
      throw nativeError(e);
    },
  );

export interface ProcOutput {
  status: number;
  stdout: string;
  stderr: string;
}

/** Native-validated gitrochi://open route. File paths stay relative to repo. */
export interface AppLaunch {
  repo: string;
  file: string | null;
  line: number | null;
  view: "graph" | "files" | "modules" | "changes" | "tree" | "diff" | "affected" | "precise" | "finder" | null;
  commit: string | null;
}

export interface RunOptions {
  cwd?: string;
  env?: Record<string, string>;
  stdin?: string;
  timeoutMs?: number;
}

export interface EnvInfo {
  os: string;
  home: string;
  dataDir: string;
  exe: string;
  temp: string;
  shell: string;
  version: string;
  /** 자동 점검(CI): 열어 볼 테스트 저장소 경로 */
  selftest: string | null;
  selftestOpen: string | null;
  appData: string;
  localAppData: string;
  /** 앱과 함께 설치되는 파일(gitch)이 있는 폴더 */
  resourceDir: string;
  /** GITROCHI_LEDGER_PREVIEW: shows the Ledger page until it is turned on for everyone */
  ledgerPreview?: string | null;
  /** GITROCHI_LEDGER_DEMO: the Ledger on demo data instead of the ledger database ("large" or "empty" for those demos) */
  ledgerDemo?: string | null;
}

export type PtyEvent = { kind: "data"; data: string } | { kind: "exit"; code: number | null };

/** A repository index command; `git` picks the git executable the app found. */
export interface IndexRequest {
  repo: string;
  git?: string;
  command: string;
  args?: Record<string, unknown>;
}

export type IndexResponse = { result: Record<string, unknown> } | { error: { code: string; message: string } };

export interface HttpResponse {
  status: number;
  body: string;
}

export interface FileHead {
  text: string;
  binary: boolean;
  truncated: boolean;
  size: number;
}

export type ExternalEditorID = "system" | "vscode" | "vscode-insiders" | "xcode" | "intellij" | "textedit" | "notepad" | "notepad-plus-plus" | "sublime";

/** Known applications on this OS; executable paths remain in the native backend. */
export interface ExternalEditor {
  id: ExternalEditorID;
  name: string;
  available: boolean;
  supportsFolders: boolean;
}

/** A process on the way from an agent up to the system (src-tauri/src/agents.rs) */
export interface ProcessLink {
  pid: number;
  name: string;
  /** Owns a visible app window */
  window: boolean;
}

/** A process that may be an agent started outside Gitrochi */
export interface AgentProcess {
  pid: number;
  name: string;
  /** The first arguments of a script runtime (node, bun); empty otherwise */
  args: string[];
  cwd: string;
  /** Seconds since 1970 */
  started: number;
  /** Parent first */
  ancestors: ProcessLink[];
}

export interface AgentScan {
  /** Gitrochi's own process id */
  own: number;
  processes: AgentProcess[];
}

export const ipc = {
  takeAppLaunches: () => invoke<({ Ok: AppLaunch } | { Err: string })[]>("take_app_launches"),
  onAppLaunch: (fn: () => void): Promise<UnlistenFn> => listen("app-launch", fn),
  run: (program: string, args: string[], o: RunOptions = {}) =>
    invoke<ProcOutput>("run_process", {
      program,
      args,
      cwd: o.cwd ?? null,
      env: o.env ?? null,
      stdin: o.stdin ?? null,
      timeoutMs: o.timeoutMs ?? null,
    }),
  /** run 과 같되 stdout 을 바이트 그대로 base64 로(이미지 등) */
  runBytes: (program: string, args: string[], o: { cwd?: string; env?: Record<string, string> } = {}) =>
    invoke<ProcOutput>("run_process_bytes", { program, args, cwd: o.cwd ?? null, env: o.env ?? null }),
  /** 파일 전체를 base64 로(max 바이트보다 크면 null) */
  readBase64: (path: string, max = 20_000_000) => invoke<string | null>("fs_read_base64", { path, max }),
  which: (program: string) => invoke<string | null>("which", { program }),
  /** Agent processes anywhere on the machine, with their folders and parent processes */
  externalAgents: () => invoke<AgentScan>("external_agents"),
  /** Brings a process's app window to the front (Windows) */
  bringAppForward: (pid: number) => invoke<void>("bring_app_forward", { pid }),
  externalEditors: () => invoke<ExternalEditor[]>("external_editors"),
  openExternalEditor: (repo: string, editorID: ExternalEditorID, file?: string) =>
    invoke<void>("open_external_editor", { repo, editorId: editorID, file: file ?? null }),

  ptySpawn: (
    id: string,
    program: string,
    args: string[],
    cwd: string,
    env: Record<string, string>,
    cols: number,
    rows: number,
    onEvent: (e: PtyEvent) => void,
  ) => {
    const ch = new Channel<PtyEvent>();
    ch.onmessage = onEvent;
    return invoke<number | null>("pty_spawn", { id, program, args, cwd, env, cols, rows, onEvent: ch });
  },
  ptyWrite: (id: string, data: string) => invoke<void>("pty_write", { id, data }),
  ptyResize: (id: string, cols: number, rows: number) => invoke<void>("pty_resize", { id, cols, rows }),
  ptyKill: (id: string) => invoke<void>("pty_kill", { id }),

  watchStart: (id: string, path: string) => invoke<void>("watch_start", { id, path }),
  watchStop: (id: string) => invoke<void>("watch_stop", { id }),
  onWatch: (id: string, fn: (paths: string[]) => void): Promise<UnlistenFn> =>
    listen<string[]>(`watch-${id}`, (e) => fn(e.payload)),

  http: (method: string, url: string, headers: Record<string, string>, body?: string, timeoutMs?: number) =>
    invoke<HttpResponse>("http_request", { method, url, headers, body: body ?? null, timeoutMs: timeoutMs ?? null }),
  hubRead: (url: string, token: string) => invoke<HttpResponse>("team_hub_read", { url, token }),
  ciLog: (provider: string, apiBase: string, repoPath: string, jobId: number, token: string) =>
    invoke<{ body: string; truncated: boolean }>("ci_job_log", { provider, apiBase, repoPath, jobId, token }),
  /** 이미지를 받아 data: 주소로(실패하면 null) */
  httpImage: (url: string, headers: Record<string, string>) => invoke<string | null>("http_image", { url, headers }),
  resolveHost: (host: string) => invoke<string[]>("resolve_host", { host }),

  secretGet: (name: string) => invoke<string | null>("secret_get", { name }),
  secretSet: (name: string, value: string | null) => invoke<void>("secret_set", { name, value }),

  exists: (path: string) => invoke<boolean>("fs_exists", { path }),
  readText: (path: string) => invoke<string | null>("fs_read_text", { path }),
  readHead: (path: string, max: number) => invoke<FileHead>("fs_read_head", { path, max }),
  writeText: (path: string, content: string) => invoke<void>("fs_write_text", { path, content }),
  localProjectsRead: () => invoke<string | null>("local_projects_read"),
  localProjectsWrite: (expected: string | null, content: string) => invoke<void>("local_projects_write", { expected, content }),
  /** Repository index (crates/gitrochi-index): one JSON command, answered with {result} or {error} */
  indexCall: (request: IndexRequest) => invoke<IndexResponse>("index_call", { request }),
  /** Ledger (crates/gitrochi-ledger): one method with JSON arguments, answered with JSON or {error} */
  ledgerCall: (method: string, args: Record<string, unknown>) => invoke<unknown>("ledger_call", { method, args }),
  /** A claude-ledger database to import; null when cancelled */
  ledgerPickDatabase: (title: string) => invoke<string | null>("ledger_pick_database", { title }),
  /** Saves bytes as <temp>/Gitrochi/<name> and returns the path (pasted images, dropped files); raw body, name hex-encoded in a header */
  writeTemp: (name: string, bytes: Uint8Array) =>
    tauriInvoke<string>("fs_write_temp", bytes, { headers: { "x-name-hex": Array.from(new TextEncoder().encode(name), (b) => b.toString(16).padStart(2, "0")).join("") } }).catch((e) => {
      throw nativeError(e);
    }),
  list: (path: string) => invoke<string[]>("fs_list", { path }),
  remove: (path: string) => invoke<void>("fs_remove", { path }),
  mkdirs: (path: string) => invoke<void>("fs_mkdirs", { path }),

  envInfo: () => invoke<EnvInfo>("env_info"),
  pickFolder: (title: string, start?: string) => invoke<string | null>("pick_folder", { title, start: start ?? null }),
  pickFile: (title: string, start?: string) => invoke<string | null>("pick_file", { title, start: start ?? null }),
  openUrl: (url: string) => invoke<void>("open_url", { url }),
  reveal: (path: string) => invoke<void>("reveal_path", { path }),
  openTerminal: (path: string) => invoke<void>("open_terminal", { path }),
  /** 새 콘솔 창에서 프로그램 하나(Windows) */
  openConsole: (program: string, args: string[], cwd: string) => invoke<void>("open_console", { program, args, cwd }),
  /** 앱이 만든 html 페이지(구조 그래프)를 기본 브라우저로 */
  openHtml: (path: string) => invoke<void>("open_html", { path }),
  /** 의존 규칙 파일(.gitch/graph.rules)을 메모장으로(.rules 에 묶인 앱이 없어도) */
  openRules: (path: string) => invoke<void>("open_rules", { path }),
  appReady: () => invoke<void>("app_ready"),
};
