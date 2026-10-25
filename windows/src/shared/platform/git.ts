import { ipc, type ProcOutput } from "@/shared/api";
import { isWindows } from "@/shared/config";
import { NativeError, t } from "@/shared/i18n";
import { tools } from "./tools";

export class GitError extends Error {
  constructor(
    readonly command: string,
    message: string,
  ) {
    super(message || t("git {0} failed", command));
  }
}

/** 오류를 사람이 읽을 문장으로(인증 문제면 해결 방법을 덧붙임) */
export function describe(e: unknown): string {
  const msg = e instanceof Error ? e.message : typeof e === "string" ? e : String(e);
  const lower = msg.toLowerCase();
  if (
    lower.includes("terminal prompts disabled") ||
    lower.includes("authentication failed") ||
    lower.includes("permission denied (publickey)") ||
    lower.includes("could not read username")
  ) {
    return (
      msg +
      t("\n\nAuthentication is required. Connect a GitHub or GitLab account in Settings (Ctrl+,), or push/pull once in a terminal to save your credentials (") +
      (isWindows() ? t("Windows Credential Manager") : t("Keychain")) +
      t(" or SSH key), then try again.")
    );
  }
  return msg;
}

/** 사용자 설정이 출력 형식을 바꿔 파싱이 깨지지 않도록 고정하는 옵션 */
const baseArgs = [
  "-c", "core.quotepath=off",
  "-c", "color.ui=false",
  "-c", "diff.noprefix=false",
  "-c", "diff.mnemonicprefix=false",
  "-c", "log.showsignature=false",
  "-c", "core.pager=cat",
];

function baseEnv(): Record<string, string> {
  return {
    GIT_TERMINAL_PROMPT: "0", // 자격 증명 프롬프트에서 멈추지 않고 실패하게
    GIT_OPTIONAL_LOCKS: "0", // status 가 index 를 다시 써서 파일 감시가 되먹임되지 않게
    GIT_LITERAL_PATHSPECS: "1", // 고른 파일의 [, *, : 등을 패턴으로 해석해 다른 파일까지 바꾸지 않게
    GIT_EDITOR: "true", // merge/revert 기본 메시지를 편집기 없이 수락
    GIT_PAGER: "cat",
    GCM_INTERACTIVE: "never", // Git Credential Manager 가 창을 띄워 멈추지 않게
    LANGUAGE: "en",
    LC_ALL: isWindows() ? "C" : "en_US.UTF-8",
  };
}

export interface GitOptions {
  input?: string;
  timeoutMs?: number;
  ok?: number[];
  env?: Record<string, string>;
}

export interface GitResult extends ProcOutput {}

/** 시스템 git 을 실행한다. 종료 코드가 ok 에 없으면 GitError. */
export async function git(args: string[], cwd: string, o: GitOptions = {}): Promise<GitResult> {
  const r = await gitRaw(args, cwd, o);
  if (!(o.ok ?? [0]).includes(r.status)) {
    const msg = r.stderr.trim() || r.stdout.trim();
    throw new GitError(args[0] ?? "", msg);
  }
  return r;
}

/** git 출력을 바이트 그대로 base64 로(git show 로 이미지 읽기). 실패하면 null */
export async function gitBytes(args: string[], cwd: string): Promise<string | null> {
  try {
    const r = await ipc.runBytes(tools.path("git") ?? "git", [...baseArgs, ...args], { cwd, env: baseEnv() });
    return r.status === 0 ? r.stdout : null;
  } catch {
    return null;
  }
}

/** 종료 코드와 상관없이 결과를 돌려준다(git 을 띄우지 못했을 때만 던짐) */
export async function gitRaw(args: string[], cwd: string, o: GitOptions = {}): Promise<GitResult> {
  try {
    return await ipc.run(tools.path("git") ?? "git", [...baseArgs, ...args], {
      cwd,
      env: { ...baseEnv(), ...(o.env ?? {}) },
      stdin: o.input,
      timeoutMs: o.timeoutMs ?? 120_000,
    });
  } catch (e) {
    const m = String(e instanceof Error ? e.message : e);
    if (/^Couldn't run /.test(e instanceof NativeError ? e.native : m) && isWindows()) {
      throw new GitError("git", t("Couldn't find git. Install Git for Windows (https://git-scm.com/download/win) or locate git.exe in Settings > Tools."));
    }
    throw new GitError("git", m);
  }
}

/** git 을 찾았는지(없으면 시작 화면에서 안내) */
export function gitAvailable(): boolean {
  return !!tools.path("git");
}

/** git 의 "detected dubious ownership" 오류에서 등록할 경로를 꺼낸다(git 이 알려 주는 명령 그대로) */
export function unsafeRepository(stderr: string): string | null {
  if (!/dubious ownership/i.test(stderr)) return null;
  const m = stderr.match(/safe\.directory\s+'([^']+)'/) ?? stderr.match(/safe\.directory\s+"([^"]+)"/) ?? stderr.match(/safe\.directory\s+(\S+)/);
  return m ? m[1] : null;
}
