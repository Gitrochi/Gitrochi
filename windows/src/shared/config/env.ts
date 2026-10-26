import { type EnvInfo, ipc } from "@/shared/api";

/** 앱 시작 때 한 번 읽어 두는 실행 환경 */
export let env: EnvInfo = {
  os: "windows",
  home: "",
  dataDir: "",
  exe: "",
  temp: "",
  shell: "powershell.exe",
  version: "0.3.4",
  selftest: null,
  selftestOpen: null,
  appData: "",
  localAppData: "",
  resourceDir: "",
};

export async function initEnv(info?: EnvInfo) {
  env = info ?? await ipc.envInfo();
}

export const isWindows = () => env.os === "windows";
export const isMac = () => env.os === "macos";

/** 단축키 표기: Windows 는 Ctrl, 맥은 ⌘ */
export function keyLabel(s: string) {
  if (isMac()) return s.replace(/Ctrl\+/g, "⌘").replace(/Shift\+/g, "⇧").replace(/Alt\+/g, "⌥");
  return s;
}

// MARK: 경로 — git 은 Windows 에서도 C:/a/b 처럼 / 로 준다

export function slash(p: string) {
  return p.replace(/\\/g, "/");
}

/** 비교용: / 로 통일하고 끝 / 제거, Windows 는 대소문자 무시 */
export function samePathKey(p: string) {
  let s = slash(p).replace(/\/+$/, "");
  if (isWindows()) s = s.toLowerCase();
  return s;
}

export function samePath(a: string | null | undefined, b: string | null | undefined) {
  if (!a || !b) return false;
  return samePathKey(a) === samePathKey(b);
}

export function basename(p: string) {
  const s = slash(p).replace(/\/+$/, "");
  return s.slice(s.lastIndexOf("/") + 1) || s;
}

export function dirname(p: string) {
  const s = slash(p).replace(/\/+$/, "");
  const i = s.lastIndexOf("/");
  if (i <= 0) return s.slice(0, i + 1);
  // "C:/x" → "C:/"
  return /^[A-Za-z]:$/.test(s.slice(0, i)) ? s.slice(0, i + 1) : s.slice(0, i);
}

export function joinPath(a: string, ...parts: string[]) {
  let s = slash(a).replace(/\/+$/, "");
  for (const p of parts) s += "/" + slash(p).replace(/^\/+/, "");
  return s;
}

/** 화면에 보여 줄 경로: Windows 는 \, 맥은 홈을 ~ 로 */
export function displayPath(p: string) {
  if (isWindows()) return slash(p).replace(/\//g, "\\");
  const home = slash(env.home);
  const s = slash(p);
  return home && s.startsWith(home) ? "~" + s.slice(home.length) : s;
}

/** 운영체제 기본 형식(Windows 는 \)으로 */
export function nativePath(p: string) {
  return isWindows() ? slash(p).replace(/\//g, "\\") : p;
}

/** WSL 배포판 안의 경로인지(\\wsl.localhost\Ubuntu\home\…, \\wsl$\…) — 그렇다면 배포판 이름 */
export function wslDistroOf(p: string): string | null {
  const m = slash(p).match(/^\/\/(?:wsl\.localhost|wsl\$)\/([^/]+)/i);
  return m ? m[1] : null;
}

/** Windows 경로를 WSL 안에서 보이는 경로로: C:\a\b → /mnt/c/a/b, \\wsl.localhost\Ubuntu\home\x → /home/x */
export function toWslPath(p: string): string {
  const s = slash(p);
  const unc = s.match(/^\/\/(?:wsl\.localhost|wsl\$)\/[^/]+(\/.*)?$/i);
  if (unc) return unc[1] || "/";
  const drive = s.match(/^([A-Za-z]):(\/.*)?$/);
  if (drive) return `/mnt/${drive[1].toLowerCase()}${drive[2] ?? "/"}`;
  return s;
}

/** 임시 폴더 안의 워크트리인지(재부팅하면 지워질 수 있음) */
export function isTemporaryPath(p: string) {
  const s = samePathKey(p);
  const tmp = samePathKey(env.temp);
  return (tmp && s.startsWith(tmp)) || ["/private/tmp/", "/tmp/", "/private/var/folders/", "/var/folders/"].some((x) => s.startsWith(x));
}
