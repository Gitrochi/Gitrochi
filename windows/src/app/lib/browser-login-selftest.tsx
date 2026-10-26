import { createElement } from "react";
import { createRoot } from "react-dom/client";
import { gitch, type GitHubLoginCapability, type GitchBrowserLogin } from "@/entities/gitch";
import { AccountConnectionFailure, accounts } from "@/entities/hosting";
import { ipc } from "@/shared/api";
import { t } from "@/shared/i18n";
import { GitchBrowserLogin as Login } from "@/features/account-connection";

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
const until = async (check: () => boolean, ms = 3000) => {
  const end = Date.now() + ms;
  while (Date.now() < end) { if (check()) return true; await sleep(25); }
  return false;
};

/** 코드 준비·클립보드 코드·상태 조회 실패와 재시작을 실제 화면으로 검증하며 모든 인증 호출은 가짜다. */
export async function browserLoginGuidanceSelfTest(): Promise<[boolean, string]> {
  const original = { start: gitch.startBrowserLogin, status: gitch.browserLoginStatus, cancel: gitch.cancelBrowserLogin, connect: accounts.importGitHubCLI, open: ipc.openUrl };
  const host = document.createElement("div"); host.hidden = true; document.body.append(host);
  const root = createRoot(host);
  const pending: GitchBrowserLogin = { schemaVersion: 1, session: "github-selftest03", state: "pending", phase: "queued", deviceCode: null, verificationURL: "https://github.com/login/device", login: null, email: null, message: "Self-test only" };
  let next = pending;
  let rejectStatus = false;
  let rejectConnection = false;
  const calls = { start: 0, status: 0, open: 0, cancel: 0, connect: 0, notify: 0 };
  const button = (label: string) => Array.from(host.querySelectorAll<HTMLButtonElement>("button")).find((item) => item.textContent?.trim() === t(label));
  const shows = (label: string) => host.textContent?.includes(t(label)) === true;
  try {
    gitch.startBrowserLogin = async () => { calls.start++; return calls.start === 3 ? { ...pending, deviceCode: "TEST-5678", phase: "approval" } : pending; };
    gitch.browserLoginStatus = async () => { calls.status++; if (rejectStatus) throw new Error("Fixture transport unavailable"); return next; };
    gitch.cancelBrowserLogin = async () => { calls.cancel++; return { ...pending, state: "cancelled" }; };
    accounts.importGitHubCLI = async () => { calls.connect++; if (rejectConnection) throw new AccountConnectionFailure("credential-save"); return { id: "selftest-only", provider: "github", server: "https://github.com", username: "fixture-user", name: null, avatarURL: null }; };
    ipc.openUrl = async () => { calls.open++; };
    root.render(createElement(Login, { onConnected: () => { calls.notify++; } }));
    if (!await until(() => !!button("Sign in to GitHub in browser"))) return [false, "Login did not mount"];
    button("Sign in to GitHub in browser")!.click();
    if (!await until(() => shows("Waiting for another sign-in to finish…"))) return [false, "Queued login was shown as browser approval"];
    next = { ...pending, phase: "preparing" };
    if (!await until(() => shows("Preparing your GitHub sign-in code…"))) return [false, "Code preparation guidance missing"];
    if (shows("Waiting for browser approval…") || calls.open !== 0) return [false, "Browser opened before a code was ready"];
    button("Open GitHub sign-in page")!.click();
    if (!await until(() => calls.open === 1)) return [false, "Manual sign-in page fallback did not open"];
    next = { ...pending, phase: "approval", deviceCode: "TEST-1234" };
    if (!await until(() => shows("Waiting for browser approval…") && shows("TEST-1234") && calls.open === 2)) return [false, "Clipboard-format code did not reach approval UI"];
    button("Cancel sign-in")!.click();
    if (!await until(() => calls.cancel === 1 && !!button("Sign in to GitHub in browser"))) return [false, "Cancel did not leave the pending screen"];

    rejectStatus = true;
    const before = calls.status;
    button("Sign in to GitHub in browser")!.click();
    if (!await until(() => !!button("Try sign-in again"), 6000)) return [false, "Repeated status failures kept the spinner running"];
    const failedCalls = calls.status - before;
    await sleep(1700);
    if (failedCalls !== 3 || calls.status - before !== 3 || calls.cancel !== 2 || calls.connect !== 0) return [false, JSON.stringify({ failedCalls, ...calls })];

    rejectStatus = false;
    rejectConnection = true;
    next = { ...pending, state: "complete", login: "fixture-user", email: "fixture@example.invalid" };
    button("Try sign-in again")!.click();
    if (!await until(() => shows("TEST-5678") && calls.open === 3)) return [false, "A code in the initial start response did not open the browser"];
    if (!await until(() => shows("Couldn't save the login in Windows Credential Manager. Unlock your credentials, then retry connecting.") && !!button("Connect authorized account"))) return [false, "Approved-account import failure was hidden"];
    if (calls.notify !== 0 || shows("Connecting the approved account…") || Number(calls.connect) !== 1) return [false, "Failed import was treated as connected or kept spinning"];
    rejectConnection = false;
    button("Connect authorized account")!.click();
    if (!await until(() => calls.notify === 1 && Number(calls.connect) === 2 && host.textContent?.includes(t("Connected as {0}", "fixture-user")) === true)) return [false, "Retry did not connect the approved fixture account"];
    return [calls.start === 3 && Number(calls.connect) === 2 && Number(calls.notify) === 1, JSON.stringify(calls)];
  } finally {
    root.unmount(); await sleep(25); host.remove();
    gitch.startBrowserLogin = original.start; gitch.browserLoginStatus = original.status; gitch.cancelBrowserLogin = original.cancel;
    accounts.importGitHubCLI = original.connect; ipc.openUrl = original.open;
  }
}

/** 프로젝트 추가 권한은 클릭·선택 계정에 묶고 승인 계정 불일치와 화면 이탈을 실제 DOM에서 검사한다. */
export async function browserProjectAccessSelfTest(): Promise<[boolean, string]> {
  const original = { start: gitch.startBrowserLogin, status: gitch.browserLoginStatus, cancel: gitch.cancelBrowserLogin, connect: accounts.importGitHubCLI, open: ipc.openUrl };
  const host = document.createElement("div"); host.hidden = true; document.body.append(host);
  const root = createRoot(host);
  const pending: GitchBrowserLogin = { schemaVersion: 1, session: "github-projectQA1", state: "pending", phase: "approval", deviceCode: "TEST-1234", verificationURL: "https://github.com/login/device", login: null, email: null, message: "Self-test only" };
  let next = pending;
  const requests: { capability?: GitHubLoginCapability; expectedLogin?: string }[] = [];
  const imports: (string | undefined)[] = [];
  let notifications = 0, cancelled = 0;
  const button = () => Array.from(host.querySelectorAll<HTMLButtonElement>("button")).find((item) => item.textContent?.trim() === t("Continue to approve project access"));
  try {
    gitch.startBrowserLogin = async (capability, expectedLogin) => { requests.push({ capability, expectedLogin }); return pending; };
    gitch.browserLoginStatus = async () => next;
    gitch.cancelBrowserLogin = async () => { cancelled++; return { ...pending, state: "cancelled" }; };
    accounts.importGitHubCLI = async (expectedLogin) => { imports.push(expectedLogin); return { id: "selftest-existing", provider: "github", server: "https://github.com", username: "fixture-user", name: null, avatarURL: null }; };
    ipc.openUrl = async () => {};
    root.render(createElement(Login, { capability: "projects", expectedLogin: "fixture-user", onConnected: () => { notifications++; } }));
    if (!await until(() => !!button())) return [false, "Project approval button missing"];
    if (requests.length || !host.textContent?.includes(t("Approve access with the selected account: @{0}", "fixture-user"))) return [false, "Project access started before a user click or selected identity was hidden"];
    next = { ...pending, state: "complete", login: "fixture-user", email: "fixture@example.invalid" };
    button()!.click();
    if (!await until(() => notifications === 1)) return [false, "Selected project account was not connected"];
    if (requests[0]?.capability !== "projects" || requests[0]?.expectedLogin !== "fixture-user" || imports[0] !== "fixture-user") return [false, "Additional project permission or selected identity was not passed through"];

    root.render(createElement(Login, { capability: "projects", expectedLogin: "different-user", onConnected: () => { notifications++; } }));
    if (!await until(() => !!button() && host.textContent?.includes(t("Approve access with the selected account: @{0}", "different-user")) === true)) return [false, "Account change did not reset project approval UI"];
    button()!.click();
    if (!await until(() => !!host.querySelector('[role="alert"]'))) return [false, "Wrong project approval identity did not show an error"];
    if (imports.length !== 1 || notifications !== 1) return [false, "Wrong browser account was imported"];

    next = pending;
    root.render(createElement(Login, { capability: "projects", expectedLogin: "cancel-user", onConnected: () => { notifications++; } }));
    if (!await until(() => !!button() && host.textContent?.includes(t("Approve access with the selected account: @{0}", "cancel-user")) === true)) return [false, "Cancellation fixture failed to mount"];
    button()!.click();
    if (!await until(() => requests.length === 3 && host.textContent?.includes("TEST-1234") === true)) return [false, "Cancellation fixture did not start"];
    root.unmount();
    next = { ...pending, state: "complete", login: "cancel-user", email: "cancel@example.invalid" };
    await sleep(650);
    if (cancelled < 1 || imports.length !== 1 || notifications !== 1) return [false, "Closing project approval did not cancel the owned session"];
    return [true, JSON.stringify({ requests, imports: imports.length, notifications, cancelled })];
  } finally {
    root.unmount(); await sleep(25); host.remove();
    gitch.startBrowserLogin = original.start; gitch.browserLoginStatus = original.status; gitch.cancelBrowserLogin = original.cancel;
    accounts.importGitHubCLI = original.connect; ipc.openUrl = original.open;
  }
}
