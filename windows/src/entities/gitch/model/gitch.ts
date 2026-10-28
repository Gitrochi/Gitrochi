import { ipc } from "@/shared/api";
import { dirname, env, isWindows, joinPath, slash } from "@/shared/config";
import { language, t } from "@/shared/i18n";
import { git, tools } from "@/shared/platform";
import { accountAddArguments, browserLoginArguments, type GitHubLoginCapability, type GitchAccountInput, machineError, parseAccountSetup, parseBrowserLogin, parseDoctor } from "./onboarding";
import { type GraphReview, parseGraphReview, parseGraphReviewStamp } from "./review";

/**
 * gitch — 여러 Git 계정을 섞이지 않게 쓰는 셸 도구(tools/gitch, 예전 이름 gitsw). (맥 버전 Gitch.swift)
 * 앱 설치 폴더(Gitrochi.exe 옆)에 함께 들어 있고 설정 > CLI 에서 셸 명령으로 설치한다.
 * gitch 는 bash 스크립트라 Windows 에서는 Git for Windows 의 bash 로 돌린다.
 * 저장소 화면은 gitch 가 보는 이 저장소의 계정(잠금)과 커밋·push 전 점검을 보여 주고, 계정을 바꿀 수 있다.
 */

/** gitch status --json (값이 없으면 gitch 는 빈 글자를 내므로 null 로 바꿔 읽는다) */
export interface GitchStatus {
  inRepo: boolean;
  lockedAccount: string | null;
  account: string | null;
  /** lock · owner · org · folder · alias · host */
  accountSource: string | null;
  pushAccount: string | null;
  ignored: boolean;
}

export type GitchLevel = "OK" | "WARN" | "STOP";

/** gitch preflight --json */
export interface GitchPreflight {
  result: GitchLevel;
  checks: { level: GitchLevel; code: string; message: string }[];
}

/** gitch list --json 의 계정(rules 는 gitch 가 낸 문구 그대로) */
export interface GitchAccount {
  id: string;
  email: string;
  hosts: string;
  rules: string | null;
  sshKey: boolean | null;
}

/** gitch 가 pl · up · sync · fix · undo · amend · rescue 전에 남긴 자동 백업(refs/gitsw/backup/<날짜-시각>-<이유>, 최근 30개) */
export interface GitchBackup {
  ref: string;
  /** "2026-10-23 16:36:54" */
  date: string;
  /** pl · up · sync · fix … */
  reason: string;
  sha: string;
  subject: string;
  /** 그때 수정 중이던 파일도 함께 남겼는지 */
  hasChanges: boolean;
}

export class GitchError extends Error {}

const text = (v: unknown) => (typeof v === "string" && v ? v : null);

/** 터미널 색 코드를 빼고 앞뒤 공백 정리 */
export function plain(s: string) {
  // eslint-disable-next-line no-control-regex
  return s.replace(/\u001b\[[0-9;]*m/g, "").trim();
}

export function parseStatus(json: string): GitchStatus | null {
  try {
    const o = JSON.parse(json) as Record<string, unknown>;
    if (typeof o.inRepo !== "boolean") return null;
    return {
      inRepo: o.inRepo,
      lockedAccount: text(o.lockedAccount),
      account: text(o.account),
      accountSource: text(o.accountSource),
      pushAccount: text(o.pushAccount),
      ignored: o.ignored === true,
    };
  } catch {
    return null;
  }
}

export function parsePreflight(json: string): GitchPreflight | null {
  try {
    const o = JSON.parse(json) as GitchPreflight;
    return typeof o.result === "string" && Array.isArray(o.checks) ? o : null;
  } catch {
    return null;
  }
}

export function parseAccounts(json: string): GitchAccount[] {
  try {
    const o = JSON.parse(json) as { accounts?: Partial<GitchAccount>[] };
    return (o.accounts ?? []).map((a) => ({
      id: String(a.id ?? ""),
      email: String(a.email ?? ""),
      hosts: String(a.hosts ?? ""),
      rules: text(a.rules),
      sshKey: typeof a.sshKey === "boolean" ? a.sshKey : null,
    }));
  } catch {
    return [];
  }
}

/** for-each-ref 출력(ref \t 짧은 sha \t 제목) → 백업 목록(gitch rescue 와 같은 순서 — 최근 것이 1번) */
export function parseBackups(out: string): GitchBackup[] {
  const prefix = "refs/gitsw/backup/";
  const rows = out.split("\n").filter(Boolean).map((l) => l.split("\t"));
  const refs = new Set(rows.map((r) => r[0]));
  return rows.flatMap((r) => {
    if (r.length < 3 || r[0].endsWith("-wip")) return [];
    const name = r[0].slice(prefix.length);
    if (name.length <= 16) return [];
    const date = `${name.slice(0, 4)}-${name.slice(4, 6)}-${name.slice(6, 8)} ${name.slice(9, 11)}:${name.slice(11, 13)}:${name.slice(13, 15)}`;
    return [{ ref: r[0], date, reason: name.slice(16), sha: r[1], subject: r.slice(2).join("\t"), hasChanges: refs.has(r[0] + "-wip") }];
  });
}

/** 파일 머리의 GITSW_VERSION="x.y.z"(변수 이름은 예전 그대로) */
export function versionOf(head: string): string | null {
  return head.match(/^GITSW_VERSION="([^"]+)"/m)?.[1] ?? null;
}

/** Windows 의 ~/bin/gitch 연결 스크립트(gitch install 이 만듦)가 가리키는 파일. 아니면 null */
export function linkTarget(script: string): string | null {
  const [l1, l2] = script.split("\n");
  if (l1?.trim() !== "#!/bin/sh") return null;
  return l2?.match(/^# gitch-link: (.+?)\r?$/)?.[1] ?? null;
}

/** Git Bash 경로(/c/Users/…)를 Windows 경로(C:/Users/…)로 */
export function fromPosix(p: string): string {
  const m = p.match(/^\/([a-zA-Z])(\/.*)?$/);
  return m ? `${m[1].toUpperCase()}:${m[2] ?? "/"}` : p;
}

/** gitch graph 가 그리는 관계(tools/gitch/README.md 「구조 그래프」) */
export type GraphRelation = "files" | "modules" | "changes" | "tree";

/** 메뉴에 보일 관계: 이름과 설명(터미널에서 같은 그림을 그리는 명령과 무엇을 읽는지) */
export function graphRelations(): { id: GraphRelation; title: string; detail: string }[] {
  return [
    { id: "files", title: t("File imports"), detail: t("gitch graph files: source files across many languages, with imports, includes and inferred type references.") },
    { id: "modules", title: t("Module dependencies"), detail: t("gitch graph modules: targets, packages and dependencies from SwiftPM, Tuist, npm, Cargo, Go, Gradle, Maven, Python, .NET, Composer, Bundler, Pub and CMake.") },
    { id: "changes", title: t("Files that change together"), detail: t("gitch graph changes: files that are often committed together, and how often each one changes.") },
    { id: "tree", title: t("Folder tree"), detail: t("gitch graph tree: folders with their size and number of files.") },
  ];
}

/** 앱과 버전을 맞추기 전의 gitch graph 최소 버전(옛 CLI 호환용) */
export const graphMinimumVersion = "3.2.0";

/** 새 CLI 는 기능 표시로 확인한다. 앱 버전과 숫자가 다른 옛 CLI 만 버전으로 판단한다. */
export function supportsGraph(head: string): boolean {
  const lines = head.split(/\r?\n/);
  const scheme = lines.filter((line) => /^\s*(?:export\s+)?GITCH_VERSION_SCHEME\b/.test(line));
  const api = lines.filter((line) => /^\s*(?:export\s+)?GITCH_GRAPH_API\b/.test(line));
  if (scheme.length || api.length) {
    return scheme.length === 1 && scheme[0] === 'GITCH_VERSION_SCHEME="gitrochi"'
      && api.length === 1 && /^GITCH_GRAPH_API="[1-9][0-9]*"$/.test(api[0]);
  }
  const version = versionOf(head);
  return !!version && /^\d+(?:\.\d+){0,3}$/.test(version) && versionAtLeast(version, graphMinimumVersion);
}

/** gitch graph 가 만든 html */
export interface GraphPage {
  file: string;
  /** Loopback live view, or absent when the optional watcher runtime isn't available. */
  liveUrl?: string;
  /** 끝 줄(GRAPH_FILE=… NODES=… EDGES=…)의 노드 수. 그 줄이 없으면 null */
  nodes: number | null;
  /** 그릴 것이 없을 때 gitch 가 낸 안내(⚠ 줄, 문구 그대로) */
  hint: string | null;
}

export function parseGraphWatchURL(raw: string): string | null {
  try {
    const result = JSON.parse(raw) as { url?: unknown };
    if (typeof result.url !== "string") return null;
    const url = new URL(result.url);
    return url.protocol === "http:" && url.hostname === "127.0.0.1" && !!url.port && !url.username && !url.password ? url.href : null;
  } catch { return null; }
}

/** "3.10.0" >= "3.2.0" 처럼 숫자로 비교 */
export function versionAtLeast(v: string, min: string): boolean {
  const a = v.split(".").map((x) => parseInt(x, 10) || 0);
  const b = min.split(".").map((x) => parseInt(x, 10) || 0);
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    if ((a[i] ?? 0) !== (b[i] ?? 0)) return (a[i] ?? 0) > (b[i] ?? 0);
  }
  return true;
}

/** gitch graph 의 표준출력 → 노드 수와 안내. 경로에 빈칸이 있을 수 있어 NODES= 는 끝 줄의 뒤에서 찾는다 */
export function parseGraphSummary(out: string): { nodes: number | null; hint: string | null } {
  const lines = out.split(/\r?\n/);
  const summary = [...lines].reverse().find((l) => l.startsWith("GRAPH_FILE="));
  const m = summary?.match(/ NODES=(\d+)(?!.* NODES=)/);
  const hint = lines.find((l) => l.startsWith("⚠"));
  return { nodes: m ? Number(m[1]) : null, hint: hint ? hint.slice(1).trim() : null };
}

/** 「이 브랜치에서 바뀐 의존」 메뉴에 보일 관계 — gitch graph diff 는 같이 바뀌는 파일을 비교하지 않는다 */
export function graphDiffRelations(): { id: GraphRelation; title: string; detail: string }[] {
  const title = (id: GraphRelation) => graphRelations().find((r) => r.id === id)?.title ?? id;
  return [
    { id: "files", title: title("files"), detail: t("gitch graph diff files: imports added and removed on this branch, and cycles that appeared, grew, shrank or went away.") },
    { id: "modules", title: title("modules"), detail: t("gitch graph diff modules: module dependencies added and removed on this branch.") },
    { id: "tree", title: title("tree"), detail: t("gitch graph diff tree: folders whose number of files or size changed on this branch.") },
  ];
}

/** gitch graph check 가 읽는 규칙 파일(저장소 안) */
export const graphRulesFile = ".gitch/graph.rules";

/** gitch graph check --format json 의 위반 하나(tools/gitch/README.md 「규칙 검사」) */
export interface GraphViolation {
  /** files · modules */
  relation: string;
  /** error(위반) · warning(이름만으로 추정한 연결이라 실패로 세지 않는다) */
  severity: string;
  /** 어긴 규칙의 줄 번호와 그 줄 */
  line: number;
  rule: string;
  /** forbid · layers · no-cycles */
  kind: string;
  source: string | null;
  target: string | null;
  /** no-cycles: 순환을 이루는 노드 */
  nodes: string[] | null;
}

/** gitch graph check --format json */
export interface GraphCheck {
  /** 규칙 파일(저장소 안이면 상대 경로) */
  file: string;
  ok: boolean;
  violations: GraphViolation[];
}

export function parseGraphCheck(out: string): GraphCheck | null {
  try {
    const j = JSON.parse(out);
    if (typeof j?.ok !== "boolean" || !Array.isArray(j.violations)) return null;
    return {
      file: text(j.file) ?? graphRulesFile,
      ok: j.ok,
      violations: j.violations.map((v: Record<string, unknown>) => ({
        relation: String(v.relation ?? ""),
        severity: String(v.severity ?? "error"),
        line: Number(v.line) || 0,
        rule: String(v.rule ?? ""),
        kind: String(v.kind ?? ""),
        source: text(v.source),
        target: text(v.target),
        nodes: Array.isArray(v.nodes) ? v.nodes.map(String) : null,
      })),
    };
  } catch {
    return null;
  }
}

/** 규칙 파일의 규칙 줄 수(# 뒤 주석 · 빈 줄 · [files] 같은 절 머리는 빼고). --init 이 만든 예시는 모두 주석이라 0 */
export function countGraphRules(text: string): number {
  return text.split(/\r?\n/).filter((line) => {
    const rule = line.replace(/#.*/, "").trim();
    return rule !== "" && !/^\[.*\]$/.test(rule);
  }).length;
}

/** 왜 못 했는지는 gitch 가 표준오류에 낸다 */
function graphFailure(r: { status: number; stdout: string; stderr: string }) {
  return new GitchError(plain(r.stderr) || plain(r.stdout) || `exit ${r.status}`);
}

/** macOS: AppLanguage.graphCode(for:). Unsupported app languages use English. */
export function graphLanguage(code = language): "en" | "ko" | "ja" {
  const base = code.toLowerCase().replaceAll("_", "-").split("-")[0];
  return base === "ko" || base === "ja" ? base : "en";
}

/**
 * 임시 폴더의 gitch-graph/(터미널의 gitch graph 가 쓰는 곳)에 <저장소 폴더>-<이름>-<경로 해시>.html(이름: 관계 · <관계>-diff · check).
 * 다시 그리면 덮어쓰고, 폴더 이름이 같은 다른 저장소 · 워크트리와는 해시로 갈린다.
 */
async function graphFile(kind: string, repo: string): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(slash(repo))));
  const hash = [...digest.slice(0, 4)].map((b) => b.toString(16).padStart(2, "0")).join("");
  const name = slash(repo).replace(/\/+$/, "").split("/").pop() || "repo";
  // Separate watcher identities so an earlier language cannot overwrite this page.
  return joinPath(env.temp, "gitch-graph", `${name}-${kind}-${graphLanguage()}-${hash}.html`);
}

class GitchService {
  /** 앱에 든 gitch(설치 폴더의 gitch) */
  get bundled(): string | null {
    const dir = env.resourceDir.replace(/^\\\\\?\\/, "");
    return dir ? slash(joinPath(dir, "gitch")) : null;
  }
  get link() {
    return joinPath(env.home, "bin/gitch");
  }
  /** 예전 이름 — gitch install 이 같은 파일로 이어 두고, 그 전에 gitsw 로 깔았으면 그것만 있다 */
  get legacyLink() {
    return joinPath(env.home, "bin/gitsw");
  }
  /** 설정 파일은 예전 이름의 폴더 그대로(기존 설치와 같은 설정을 쓰게) */
  get configFile() {
    return joinPath(env.home, ".config/gitsw/config");
  }

  /** gitch 를 돌릴 bash: Windows 는 Git for Windows 의 bin\bash.exe(System32 의 bash.exe 는 WSL 이라 쓰지 않는다) */
  async bash(): Promise<string | null> {
    if (!isWindows()) return "/bin/bash";
    const gitPath = tools.path("git");
    const tried = new Set<string>();
    const candidates: string[] = [];
    if (gitPath) {
      // …/Git/cmd/git.exe · …/Git/bin/git.exe · …/Git/mingw64/bin/git.exe → …/Git/bin/bash.exe
      let d = dirname(slash(gitPath));
      for (let i = 0; i < 3; i++) {
        candidates.push(joinPath(d, "bin/bash.exe"));
        d = dirname(d);
      }
    }
    candidates.push("C:/Program Files/Git/bin/bash.exe", joinPath(env.localAppData, "Programs/Git/bin/bash.exe"), joinPath(env.home, "scoop/apps/git/current/bin/bash.exe"));
    for (const c of candidates) {
      if (tried.has(c)) continue;
      tried.add(c);
      if (await ipc.exists(c)) return c;
    }
    return null;
  }

  /** 계정을 하나라도 더했는지(gitch add) — 없으면 install 도 저장소 점검도 할 수 없다 */
  hasConfig() {
    return ipc.exists(this.configFile);
  }

  /** 셸 명령(~/bin/gitch, 없으면 예전 ~/bin/gitsw)이 가리키는 실제 파일. 설치하지 않았으면 null */
  async installed(): Promise<{ name: string; path: string } | null> {
    for (const [name, link] of [["~/bin/gitch", this.link], ["~/bin/gitsw", this.legacyLink]] as const) {
      const body = await ipc.readHead(link, 400).catch(() => null);
      if (!body || body.binary) continue;
      const target = linkTarget(body.text);
      // 맥 · 리눅스는 심볼릭 링크라 파일 내용이 gitch 그대로다
      return { name, path: target ? fromPosix(target) : link };
    }
    return null;
  }

  /** 설치된 셸 명령이 이 앱에 든 gitch 인지(아니면 따로 받은 gitch 나 예전 gitsw) */
  async installedIsBundled(): Promise<boolean> {
    const i = await this.installed();
    const b = this.bundled;
    return !!i && !!b && slash(i.path).toLowerCase() === b.toLowerCase();
  }

  /** 저장소 점검에 쓸 gitch: 설치된 것(따로 받은 것일 수도), 없으면 앱에 든 것 */
  async executable(): Promise<string | null> {
    const i = await this.installed();
    if (i && (await ipc.exists(i.path))) return i.path;
    const b = this.bundled;
    return b && (await ipc.exists(b)) ? b : null;
  }

  async version(path: string): Promise<string | null> {
    const h = await ipc.readHead(path, 4096).catch(() => null);
    return h ? versionOf(h.text) : null;
  }

  private async spawn(args: string[], cwd: string, timeoutMs: number, exe?: string | null, extraEnv: Record<string, string> = {}) {
    const path = exe ?? (await this.executable());
    if (!path) throw new GitchError(t("Couldn't find gitch inside Gitrochi."));
    const bash = await this.bash();
    if (!bash) throw new GitchError(t("gitch needs Git for Windows (Git Bash). Install it from https://git-scm.com/download/win."));
    // 앱에서 부를 때는 사람이 보는 터미널이 아니다: 색·로고 없이, 묻지 않고(확인이 필요하면 종료 코드 2)
    return ipc.run(bash, [path, ...args], { cwd, timeoutMs, env: { GITSW_COLOR: "never", GITSW_BANNER: "never", ...extraEnv } });
  }

  private async json(args: string[], cwd: string): Promise<string | null> {
    if (!(await this.hasConfig())) return null;
    try {
      // preflight 는 STOP 이면 종료 코드가 1 이어도 JSON 을 낸다
      return (await this.spawn(args, cwd, 60_000)).stdout;
    } catch {
      return null;
    }
  }

  async status(repo: string) {
    const out = await this.json(["status", "--json"], repo);
    return out == null ? null : parseStatus(out);
  }

  /** fetch 면 원격을 받아 받을 커밋까지 본다(몇 초). 아니면 지금 있는 원격 정보로만. */
  async preflight(repo: string, fetch: boolean) {
    const out = await this.json(["preflight", "--json", ...(fetch ? [] : ["--no-fetch"])], repo);
    return out == null ? null : parsePreflight(out);
  }

  async accounts(): Promise<GitchAccount[]> {
    const out = await this.json(["list", "--json"], env.home);
    return out == null ? [] : parseAccounts(out);
  }

  /** 로고 설정은 계정이나 터미널 명령 설치 없이 내장 CLI의 공용 설정을 읽고 쓴다. */
  private async logoPreference(enabled?: boolean): Promise<boolean> {
    const exe = this.bundled;
    if (!exe || !(await ipc.exists(exe))) throw new GitchError(t("Couldn't find gitch inside Gitrochi."));
    const r = await this.spawn(["logo", ...(enabled === undefined ? [] : [enabled ? "on" : "off"]), "--json"], env.home, 20_000, exe);
    if (r.status !== 0) throw new GitchError(machineError(r.stderr.trim()) || machineError(r.stdout.trim()) || t("Couldn't read the CLI logo setting."));
    try {
      const result = JSON.parse(r.stdout) as { schemaVersion?: unknown; enabled?: unknown };
      if (result.schemaVersion === 1 && typeof result.enabled === "boolean") return result.enabled;
    } catch { /* 잘못된 응답을 꺼진 상태로 보이지 않는다. */ }
    throw new GitchError(t("Couldn't read the CLI logo setting."));
  }

  logo() { return this.logoPreference(); }
  setLogo(enabled: boolean) { return this.logoPreference(enabled); }

  /** gitch 명령을 실행하고, 실패하면 gitch 가 낸 문구로 던진다. 성공하면 출력 */
  async run(args: string[], repo: string, timeoutMs = 120_000): Promise<string> {
    const r = await this.runRaw(args, repo, timeoutMs);
    if (r.status !== 0) throw new GitchError(r.output || `exit ${r.status}`);
    return r.output;
  }

  /** 종료 코드와 출력을 그대로(확인이 필요하면 gitch 는 2 로 끝나며 무엇을 할지 목록을 낸다) */
  async runRaw(args: string[], repo: string, timeoutMs = 120_000): Promise<{ status: number; output: string }> {
    const r = await this.spawn(args, repo, timeoutMs);
    return { status: r.status, output: plain(r.stdout + (r.stderr ? "\n" + r.stderr : "")) };
  }

  /** 메뉴에 쓸 graphUnavailable() 결과(앱에 든 gitch 는 앱이 켜진 동안 바뀌지 않아 한 번만 본다). 아직 안 봤으면 undefined */
  graphReason: string | null | undefined = undefined;
  private graphCheck: Promise<string | null> | null = null;

  checkGraph(): Promise<string | null> {
    this.graphCheck ??= this.graphUnavailable().then((r) => (this.graphReason = r));
    return this.graphCheck;
  }

  /**
   * 구조 그래프를 그릴 수 없는 이유 — 앱에 든 gitch 가 없거나 그래프 기능이 없다. 그릴 수 있으면 null.
   * 설치한 셸 명령은 따로 받은 예전 gitch 일 수 있어서 앱에 든 것만 본다(그래프는 계정 설정이 필요 없다).
   */
  async graphUnavailable(): Promise<string | null> {
    const exe = this.bundled;
    if (!exe || !(await ipc.exists(exe))) return t("Couldn't find gitch inside Gitrochi.");
    if (!(await this.bash())) return t("gitch needs Git for Windows (Git Bash). Install it from https://git-scm.com/download/win.");
    const header = await ipc.readHead(exe, 4096).catch(() => null);
    if (!header || !supportsGraph(header.text)) return t("The gitch inside Gitrochi doesn't support structure graphs. Update Gitrochi and try again.");
    return null;
  }

  /**
   * 앱에 든 gitch 로 `gitch graph <관계> --format html --out <임시 파일> --no-open` — CDN 없는 한 페이지를 만든다.
   * modules 는 매니페스트를 읽느라, 큰 저장소의 files 도 몇 초 걸린다.
   */
  async graph(relation: GraphRelation, repo: string, precise = false): Promise<GraphPage> {
    const file = await graphFile(precise ? "files-precise" : relation, repo);
    const r = await this.runGraph([relation, ...(precise ? ["--precise"] : []), "--format", "html", "--out", file, "--no-open"], repo);
    const liveUrl = await this.graphWatchURL(precise ? "precise" : relation, file, repo);
    return { file, ...parseGraphSummary(plain(r.stdout)), ...(liveUrl ? { liveUrl } : {}) };
  }

  /** Select only paths proven to exist in the current file dependency snapshot. */
  async graphPathSelection(repo: string, paths: string[]): Promise<string> {
    const result = await this.runGraph(["files", "--json"], repo);
    const value: unknown = JSON.parse(result.stdout);
    if (!value || typeof value !== "object" || !("schemaVersion" in value) || value.schemaVersion !== 1 || !("snapshotID" in value) || typeof value.snapshotID !== "string" || !/^(?:[a-f0-9]{40}|[a-f0-9]{64})$/.test(value.snapshotID) || !("nodes" in value) || !Array.isArray(value.nodes)) throw new GitchError(t("The graph snapshot could not be read. Analyze again."));
    const known = new Set(value.nodes.filter((node): node is { id: string; kind: string } => !!node && typeof node === "object" && "id" in node && typeof node.id === "string" && "kind" in node && node.kind === "file").map(node => node.id));
    if (!paths.length || paths.length > 100 || new Set(paths).size !== paths.length || paths.some(path => !known.has(path))) throw new GitchError(t("Some selected files are not present in this dependency graph. Analyze the current files again."));
    return JSON.stringify({ schemaVersion: 1, snapshotID: value.snapshotID, actions: [{ kind: "nodes", nodeIDs: paths }] });
  }

  async affectedGraph(repo: string, base: string | null = null): Promise<GraphPage> {
    const file = await graphFile("affected", repo);
    const r = await this.runGraph(["affected", ...(base ? ["--base", base] : []), "--format", "html", "--out", file, "--no-open"], repo);
    const liveUrl = base === null ? await this.graphWatchURL("affected", file, repo) : null;
    return { file, ...parseGraphSummary(plain(r.stdout)), ...(liveUrl ? { liveUrl } : {}) };
  }

  /** 이번 커밋의 영향은 스테이지 내용과 HEAD만 비교한다. 작업 트리나 브랜치 분기점은 쓰지 않는다. */
  async commitReview(repo: string): Promise<GraphReview> {
    const r = await this.runGraph(["review", "--json"], repo);
    const result = parseGraphReview(r.stdout);
    if (!result) throw new GitchError(t("The staged analysis returned an unreadable result. Update Gitrochi and try again."));
    return result;
  }

  /** 소스 분석을 반복하지 않고 스테이지와 HEAD의 변경 여부만 확인한다. */
  async commitReviewStamp(repo: string): Promise<string> {
    const r = await this.runGraph(["review", "--stamp", "--json"], repo);
    const result = parseGraphReviewStamp(r.stdout);
    if (!result) throw new GitchError(t("Couldn't verify that the staged analysis is current. Analyze again."));
    return result.stamp;
  }

  /** 요약과 같은 스테이지 범위의 HTML을 만든다. 작업 트리 감시 서버는 켜지 않는다. */
  async commitReviewGraph(repo: string): Promise<GraphPage> {
    const file = await graphFile("staged-review", repo);
    const r = await this.runGraph(["review", "--format", "html", "--out", file, "--no-open"], repo);
    return { file, ...parseGraphSummary(plain(r.stdout)) };
  }

  private async graphWatchURL(relation: string, file: string, repo: string): Promise<string | null> {
    try {
      const r = await this.runGraph(["watch", relation, "--out", file, "--no-open", "--detach", "--json"], repo);
      return parseGraphWatchURL(r.stdout);
    } catch { return null; }
  }

  /**
   * `gitch graph diff [--base 기준...] <관계> --format html --out <임시 파일> --no-open` — 기준과 이 브랜치가 갈라진 곳과 지금 작업 트리(커밋하지 않은 바꿈 포함)의
   * 의존을 비교해 더한 것은 초록, 뺀 것은 빨간 점선으로 그린 페이지. 기준이 null 이면 gitch 가 고른다(기본 브랜치와 갈라진 곳).
   * 기준... 은 gitch 가 갈라진 곳(merge-base)을 찾고 페이지에는 기준 이름을 적는다 — 기준 브랜치가 그 뒤로 앞서 나가도 그 커밋이 뺀 것으로 보이지 않게.
   * 기준 커밋을 임시 폴더에 풀어 같은 방법으로 한 번 더 읽으므로 큰 저장소는 몇 초 걸린다.
   */
  async graphDiff(relation: GraphRelation, base: string | null, repo: string): Promise<string> {
    const file = await graphFile(`${relation}-diff`, repo);
    await this.runGraph(["diff", ...(base ? ["--base", `${base}...`] : []), relation, "--format", "html", "--out", file, "--no-open"], repo);
    return file;
  }

  /**
   * `gitch graph check --format json`. 위반이 있으면 gitch 는 1 로 끝나지만 실패가 아니다(결과 JSON 을 낸다).
   * 규칙 파일에 틀린 줄이 있으면 JSON 없이 1 로 끝나고, 틀린 줄을 표준오류에 낸다.
   */
  async graphRulesCheck(repo: string): Promise<GraphCheck> {
    const r = await this.runGraph(["check", "--format", "json"], repo, [0, 1]);
    const result = parseGraphCheck(r.stdout);
    if (!result) throw graphFailure(r);
    return result;
  }

  /** `gitch graph check --format html --out <임시 파일> --no-open` — 규칙을 어긴 연결을 빨갛게 그린 페이지(위반이 있어 1 로 끝나도 만든다) */
  async graphCheckPage(repo: string): Promise<string> {
    const file = await graphFile("check", repo);
    const r = await this.runGraph(["check", "--format", "html", "--out", file, "--no-open"], repo, [0, 1]);
    if (!plain(r.stdout).includes("GRAPH_FILE=")) throw graphFailure(r);
    return file;
  }

  /** `gitch graph check --init` — 예시(모두 # 주석)가 든 규칙 파일을 만든다 */
  async graphRulesInit(repo: string): Promise<void> {
    await this.runGraph(["check", "--init"], repo);
  }

  /** 앱에 든 gitch 로 `gitch graph …`. 종료 코드가 ok 에 없으면 gitch 가 낸 까닭으로 던진다 */
  private async runGraph(args: string[], repo: string, ok = [0]) {
    const reason = await this.graphUnavailable();
    if (reason) throw new GitchError(reason);
    const r = await this.spawn(["graph", ...args], repo, 600_000, this.bundled, { GITCH_GRAPH_LANG: graphLanguage(), GITSW_SWIFT_DESCRIBE: "0" });
    if (!ok.includes(r.status)) throw graphFailure(r);
    return r;
  }

  /** 처음 설정도 앱에 포함된 최신 CLI로 실행한다. 설치된 구버전/전역 셸 연동은 필요하지 않다. */
  private async setupAccount(args: string[]) {
    const exe = this.bundled;
    if (!exe || !(await ipc.exists(exe))) throw new GitchError(t("Couldn't find gitch inside Gitrochi."));
    const r = await this.spawn(args, env.home, 60_000, exe);
    const result = parseAccountSetup(r.stdout);
    if (!result) throw new GitchError(machineError(r.stderr.trim()) || t("Couldn't read the account setup result."));
    return result;
  }

  addAccount(input: GitchAccountInput) { return this.setupAccount(accountAddArguments(input)); }
  inspectAccount(id: string) { return this.setupAccount(["setup", id, "--inspect", "--json"]); }
  generateAccountKey(id: string) { return this.setupAccount(["setup", id, "--generate", "--json", "--yes"]); }
  checkAccountConnection(id: string) { return this.setupAccount(["setup", id, "--check", "--json"]); }

  private async browserLogin(args: string[]) {
    const exe = this.bundled;
    if (!exe || !(await ipc.exists(exe))) throw new GitchError(t("Couldn't find gitch inside Gitrochi."));
    const r = await this.spawn(["login", "github", ...args, "--json"], env.home, 30_000, exe, { GITCH_GH: tools.path("gh") ?? "gh" });
    const result = parseBrowserLogin(r.stdout);
    if (!result) throw new GitchError(machineError(r.stderr.trim()) || t("Couldn't read the browser login result."));
    return result;
  }
  startBrowserLogin(capability: GitHubLoginCapability = "standard", expectedLogin?: string) { return this.browserLogin(browserLoginArguments(capability, expectedLogin)); }
  browserLoginStatus(session: string) { return this.browserLogin(["--status", session]); }
  cancelBrowserLogin(session: string) { return this.browserLogin(["--cancel", session]); }

  async doctor() {
    const r = await this.spawn(["doctor", "--json", "--no-net"], env.home, 60_000, this.bundled);
    const result = parseDoctor(r.stdout);
    if (!result) throw new GitchError(machineError(r.stderr.trim()) || t("Couldn't read the diagnosis result."));
    return result;
  }

  async commandHelp() {
    const r = await this.spawn(["help"], env.home, 20_000, this.bundled);
    if (r.status !== 0) throw new GitchError(machineError(r.stderr.trim()));
    return plain(r.stdout);
  }

  /** 자동 백업 목록 */
  async backups(repo: string): Promise<GitchBackup[]> {
    try {
      const r = await git(["for-each-ref", "--sort=-refname", "--format=%(refname)%09%(objectname:short)%09%(subject)", "refs/gitsw/backup/"], repo);
      return parseBackups(r.stdout);
    } catch {
      return [];
    }
  }

  /** 앱에 든 gitch 로 `gitch install`: ~/bin/gitch 연결(+ PowerShell 용 .cmd · 사용자 PATH), ~/.bashrc, git 전역 훅·규칙, AI 도구 규칙 */
  async install(): Promise<string> {
    const exe = this.bundled;
    if (!exe || !(await ipc.exists(exe))) throw new GitchError(t("Couldn't find gitch inside Gitrochi."));
    // 설치하지 않은(포터블 · 빌드) Gitrochi 에 연결하면 폴더를 옮기거나 지울 때 끊긴다(gitch install 도 거부하지만 번역된 안내를 보이려고 먼저 확인)
    if (isWindows() && !(await ipc.exists(joinPath(dirname(exe), "uninstall.exe")))) {
      throw new GitchError(t("This Gitrochi isn't installed (portable or a build). Install Gitrochi with the setup program, open it, then install gitch."));
    }
    const r = await this.spawn(["install"], env.home, 180_000, exe);
    const out = plain(r.stdout + (r.stderr ? "\n" + r.stderr : ""));
    if (r.status !== 0) throw new GitchError(out || `exit ${r.status}`);
    return out;
  }

  /** 새 콘솔 창에서 gitch 명령(add · setup · doctor 처럼 묻거나 길게 보여 주는 것). 끝나면 Enter 로 닫는다. */
  async openInConsole(args: string[], cwd = env.home) {
    const exe = await this.executable();
    if (!exe) throw new GitchError(t("Couldn't find gitch inside Gitrochi."));
    const bash = await this.bash();
    if (!bash) throw new GitchError(t("gitch needs Git for Windows (Git Bash). Install it from https://git-scm.com/download/win."));
    const close = t("Press Enter to close this window");
    await ipc.openConsole(bash, ["-c", `"$0" "$@"; echo; read -r -p "${close.replace(/["$`\\]/g, "")}" _`, exe, ...args], cwd);
  }

  /** 내장 터미널 탭에서 돌릴 명령(저장소 화면에서 doctor 등) */
  async terminalCommand(args: string[]): Promise<{ program: string; args: string[] } | null> {
    const [exe, bash] = [await this.executable(), await this.bash()];
    return exe && bash ? { program: bash, args: [exe, ...args] } : null;
  }
}

export const gitch = new GitchService();
