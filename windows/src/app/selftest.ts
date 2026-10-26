import { invoke } from "@tauri-apps/api/core";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { createElement } from "react";
import { createRoot } from "react-dom/client";
import { agents } from "@/entities/agent";
import { ai } from "@/entities/ai";
import { canPlay, CIAPI } from "@/entities/ci";
import { type DropRequest, emptyStatus, isWIP, markdownRefs, statusFiles, statusIsEmpty, wipWorktree } from "@/entities/git";
import { gitch, graphRulesFile, type GitchAccountSetup as AccountSetup, type GitchBrowserLogin as BrowserLogin } from "@/entities/gitch";
import { accounts, ReviewAPI, reviewFileChange } from "@/entities/hosting";
import { branchPayload } from "@/entities/repo";
import { panes } from "@/entities/terminal";
import { workspace } from "@/entities/workspace";
import { structureGraphMenus } from "@/features/git-menus";
import { ipc } from "@/shared/api";
import { dirname, env, isWindows, joinPath, samePath, settings, toWslPath } from "@/shared/config";
import { t } from "@/shared/i18n";
import { gitRaw, listDistros, tools } from "@/shared/platform";
import { Markdown, theme } from "@/shared/ui";
import { GitchAccountSetup, GitchBrowserLogin } from "@/widgets/settings";
import { applyAppLaunch } from "./lib/app-launch";

/**
 * 자동 점검(CI 의 Windows 서버에서): GITROCHI_SELFTEST=<테스트 저장소> 로 켜면
 * 실제 화면·백엔드로 주요 기능을 차례로 해 보고 결과를 <저장소 옆>/selftest-result.json 에 남긴다.
 */
interface Check {
  name: string;
  ok: boolean;
  detail?: string;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function until(f: () => boolean | Promise<boolean>, timeoutMs = 15000) {
  const end = Date.now() + timeoutMs;
  while (Date.now() < end) {
    if (await f()) return true;
    await sleep(150);
  }
  return false;
}

/** 실제 React 효과와 버튼으로 취소 경계를 확인한다. 모든 인증·브라우저 호출은 가짜다. */
async function browserLoginLifecycle(boundary: "start" | "status" | "browser"): Promise<[boolean, string]> {
  const defer = <T,>() => {
    let resolve!: (value: T) => void;
    const promise = new Promise<T>((done) => { resolve = done; });
    return { promise, resolve };
  };
  const pending: BrowserLogin = { schemaVersion: 1, session: "github-selftest01", state: "pending", deviceCode: null, verificationURL: "https://github.com/login/device", login: null, email: null, message: "Self-test only" };
  const complete: BrowserLogin = { ...pending, state: "complete", login: "selftest-user", email: "selftest@example.invalid" };
  const start = defer<BrowserLogin>(), status = defer<BrowserLogin>(), browser = defer<void>();
  const original = { start: gitch.startBrowserLogin, status: gitch.browserLoginStatus, cancel: gitch.cancelBrowserLogin, connect: accounts.importGitHubCLI, open: ipc.openUrl };
  const calls = { start: 0, status: 0, cancel: [] as string[], connect: 0, notify: 0, open: 0 };
  const host = document.createElement("div");
  host.hidden = true;
  host.dataset.selftest = "browser-login-lifecycle";
  document.body.append(host);
  const root = createRoot(host);
  let mounted = true;
  const unmount = () => { if (mounted) { root.unmount(); mounted = false; } };
  const button = (label: string) => Array.from(host.querySelectorAll<HTMLButtonElement>("button")).find((b) => b.textContent?.trim() === t(label));
  try {
    gitch.startBrowserLogin = async () => { calls.start++; return boundary === "start" ? start.promise : pending; };
    gitch.browserLoginStatus = async () => {
      calls.status++;
      if (boundary === "status") return status.promise;
      // 버그로 추가 poll이 생겨도 가짜 완료로 끝내어 실제 인증 호출이 남지 않게 한다.
      return calls.status === 1 ? { ...pending, deviceCode: "TEST-1234" } : complete;
    };
    gitch.cancelBrowserLogin = async (session) => { calls.cancel.push(session); return { ...pending, state: "cancelled" }; };
    accounts.importGitHubCLI = async () => { calls.connect++; return { id: "selftest-only", provider: "github", server: "https://github.com", username: "selftest-user", name: null, avatarURL: null }; };
    ipc.openUrl = async () => { calls.open++; if (boundary === "browser") await browser.promise; };
    root.render(createElement(GitchBrowserLogin, { onConnected: () => { calls.notify++; } }));
    if (!await until(() => !!button("Sign in to GitHub in browser"), 2000)) return [false, "Hidden login component did not mount"];
    button("Sign in to GitHub in browser")!.click();
    if (boundary === "start") {
      if (!await until(() => calls.start === 1, 1000)) return [false, "Start button did not call the fake API"];
      unmount();
      start.resolve(pending);
      await until(() => calls.cancel.length > 0, 1000);
    } else {
      if (!await until(() => calls.status === 1 && !!button("Cancel sign-in"), 2000)) return [false, "Pending login did not poll"];
      if (boundary === "status") {
        button("Cancel sign-in")!.click();
        status.resolve(complete);
        await sleep(50);
        unmount();
      } else {
        if (!await until(() => calls.open === 1, 1000)) return [false, "The fake browser did not open"];
        unmount();
        browser.resolve();
        // 다음 poll(1500ms)보다 길게 기다려 정리되지 않은 타이머도 검출한다.
        await sleep(1700);
      }
    }
    const expectedPolls = boundary === "start" ? 0 : 1;
    return [calls.start === 1 && calls.status === expectedPolls && calls.cancel.length === 1 && calls.cancel[0] === pending.session && calls.connect === 0 && calls.notify === 0 && calls.open === (boundary === "browser" ? 1 : 0), JSON.stringify({ boundary, ...calls })];
  } finally {
    unmount();
    start.resolve(pending); status.resolve({ ...pending, state: "cancelled" }); browser.resolve();
    await sleep(25);
    gitch.startBrowserLogin = original.start; gitch.browserLoginStatus = original.status; gitch.cancelBrowserLogin = original.cancel;
    accounts.importGitHubCLI = original.connect; ipc.openUrl = original.open;
    host.remove();
  }
}

async function browserLoginResumesExistingIdentity(): Promise<[boolean, string]> {
  const original = { start: gitch.startBrowserLogin, status: gitch.browserLoginStatus, cancel: gitch.cancelBrowserLogin, connect: accounts.importGitHubCLI, inspect: gitch.inspectAccount, add: gitch.addAccount, open: ipc.openUrl };
  const pending: BrowserLogin = { schemaVersion: 1, session: "github-selftest02", state: "pending", deviceCode: null, verificationURL: "https://github.com/login/device", login: null, email: null, message: "Self-test only" };
  const inspected: AccountSetup = { schemaVersion: 1, created: false, account: { id: "OctoCat", email: "existing@example.invalid", host: "github.com", port: 22, folder: null, via: null }, ssh: { alias: "github-OctoCat", keyExists: false, publicKey: null, registrationURL: "https://github.com/settings/ssh/new", authenticated: null, keyProtection: "missing", message: "Self-test only" } };
  const calls = { inspect: [] as string[], connect: [] as (string | undefined)[], add: 0, saved: 0, open: 0 };
  const host = document.createElement("div");
  host.hidden = true;
  document.body.append(host);
  const root = createRoot(host);
  const button = (label: string) => Array.from(host.querySelectorAll<HTMLButtonElement>("button")).find((b) => b.textContent?.trim() === t(label));
  try {
    gitch.startBrowserLogin = async () => pending;
    gitch.browserLoginStatus = async () => ({ ...pending, state: "complete", login: "OCTOCAT", email: "browser@example.invalid" });
    gitch.cancelBrowserLogin = async () => ({ ...pending, state: "cancelled" });
    accounts.importGitHubCLI = async (login) => { calls.connect.push(login); return { id: "selftest-only", provider: "github", server: "https://github.com", username: "OCTOCAT", name: null, avatarURL: null }; };
    gitch.inspectAccount = async (id) => { calls.inspect.push(id); return inspected; };
    gitch.addAccount = async () => { calls.add++; return inspected; };
    ipc.openUrl = async () => { calls.open++; };
    const identities = [
      { id: "OCTOCAT", email: "other@example.invalid", hosts: "notgithub.com", rules: null, sshKey: false },
      { id: "OctoCat", email: "existing@example.invalid", hosts: "GitHub.COM(로그인 OctoCat), gitlab.example.com", rules: null, sshKey: false },
    ];
    root.render(createElement(GitchAccountSetup, { account: null, accounts: identities, onSaved: () => { calls.saved++; }, onClose: () => {} }));
    if (!await until(() => !!button("Sign in to GitHub in browser"), 2000)) return [false, "Hidden account setup did not mount"];
    button("Sign in to GitHub in browser")!.click();
    const resumed = await until(() => calls.inspect.length === 1 && host.textContent?.includes("existing@example.invalid") === true && !button("Save account and continue"), 3000);
    return [resumed && calls.inspect[0] === "OctoCat" && calls.connect.length === 1 && calls.connect[0] === "OCTOCAT" && calls.add === 0 && calls.saved === 0 && calls.open === 0, JSON.stringify({ resumed, ...calls })];
  } finally {
    root.unmount();
    await sleep(25);
    gitch.startBrowserLogin = original.start; gitch.browserLoginStatus = original.status; gitch.cancelBrowserLogin = original.cancel;
    accounts.importGitHubCLI = original.connect; gitch.inspectAccount = original.inspect; gitch.addAccount = original.add; ipc.openUrl = original.open;
    host.remove();
  }
}

export async function runSelfTest(): Promise<boolean> {
  const repo = env.selftest;
  if (!repo) return false;
  const checks: Check[] = [];
  const out = joinPath(dirname(repo), "selftest-result.json");
  // a render error unmounts the whole React tree (blank window) — record it so the result says what broke
  const uncaught: string[] = [];
  window.addEventListener("error", (e) => uncaught.push(`${e.message} @ ${e.filename?.split("/").pop()}:${e.lineno}`));
  window.addEventListener("unhandledrejection", (e) => uncaught.push(`unhandled: ${String(e.reason).slice(0, 200)}`));
  const check = (name: string, ok: boolean, detail?: unknown) => {
    checks.push({ name, ok, detail: detail === undefined ? undefined : String(detail).slice(0, 500) });
  };
  const step = async (name: string, f: () => Promise<boolean | [boolean, unknown]>) => {
    try {
      const r = await f();
      if (Array.isArray(r)) check(name, r[0], r[1]);
      else check(name, r);
    } catch (e) {
      check(name, false, e instanceof Error ? e.stack ?? e.message : e);
    }
  };

  workspace.restoring = false;
  const s = workspace.newTab();
  await step("저장소 열기", async () => {
    await s.openInPlace(repo);
    return [!!s.path && s.entries.length > 0, `path=${s.path} commits=${s.entries.length} error=${s.errorMessage}`];
  });
  await step("화면에 커밋 행 표시", async () => [await until(() => document.querySelectorAll(".commit-row").length > 0, 5000), document.querySelectorAll(".commit-row").length]);
  await step("브랜치·태그 읽기", async () => [s.localBranches.length >= 2 && s.tags.length >= 1, `branches=${s.localBranches.map((b) => b.name)} tags=${s.tags.map((t) => t.name)}`]);
  await step("그래프 레인(머지)", async () => [s.maxLanes >= 2 && s.entries.some((e) => e.commit.parents.length > 1), `lanes=${s.maxLanes}`]);

  await step("앱에서 Git 계정 추가 폼과 SSH 포트 도움말", async () => {
    window.dispatchEvent(new CustomEvent("gitrochi-open-settings", { detail: "cli" }));
    const find = (label: string) => Array.from(document.querySelectorAll<HTMLButtonElement>(".modal button")).find((b) => b.textContent?.trim() === label);
    if (!await until(() => !!find("계정 추가"), 15000)) return [false, "CLI settings did not load"];
    find("계정 추가")!.click();
    const ready = await until(() => !!document.querySelector('[aria-label="Git 계정 설정"]'), 5000);
    const question = document.querySelector<HTMLButtonElement>('[aria-label="SSH 포트가 뭔가요?"]');
    const fields = document.querySelectorAll('[aria-label="Git 계정 설정"] input');
    return [ready && fields.length >= 4 && !!question?.title.includes("22") && !!find("브라우저로 GitHub 로그인"), `fields=${fields.length} tooltip=${question?.title}`];
  });
  await step("앱의 gitch 명령 안내와 읽기 전용 진단", async () => {
    const find = (label: string) => Array.from(document.querySelectorAll<HTMLButtonElement>(".modal button")).find((b) => b.textContent?.trim() === label);
    find("시작 안내 · 명령 설명")?.click();
    const guide = await until(() => !!find("전체 명령과 옵션 보기"), 5000);
    find("전체 명령과 옵션 보기")?.click();
    const help = await until(() => Array.from(document.querySelectorAll(".modal pre")).some((p) => p.textContent?.includes("gitch preflight")), 10000);
    find("설정 확인")?.click();
    const doctor = await until(() => document.querySelector(".modal")?.textContent?.includes("설정 확인 결과") ?? false, 15000);
    document.querySelector<HTMLButtonElement>(".modal-footer button")?.click();
    return [guide && help && doctor, `guide=${guide} help=${help} diagnosis=${doctor}`];
  });
  await step("브라우저 로그인 시작 응답 전 화면 이탈 → 늦은 세션 취소", () => browserLoginLifecycle("start"));
  await step("브라우저 로그인 취소 → 늦은 완료 응답 연결 차단", () => browserLoginLifecycle("status"));
  await step("브라우저 열기 중 화면 이탈 → 후속 poll과 연결 중단", () => browserLoginLifecycle("browser"));
  await step("GitHub 로그인 대소문자 차이 → 같은 서버의 기존 계정 설정 재개", browserLoginResumesExistingIdentity);

  const file = joinPath(repo, "selftest-새파일.txt");
  await step("파일 감시 → 새 파일 표시", async () => {
    await ipc.writeText(file, "안녕하세요 Gitrochi\nline 2\n");
    return [await until(() => s.status.unstaged.some((c) => c.path.startsWith("selftest-")), 10000), JSON.stringify(s.status.unstaged.map((c) => c.path))];
  });
  await step("새 파일 diff", async () => {
    const c = s.status.unstaged.find((x) => x.path.startsWith("selftest-"));
    if (!c) return [false, "파일 없음"];
    s.openDiff({ kind: "working", change: c });
    const ok = await until(() => !!s.diff && s.diff.lines.some((l) => l.text.includes("안녕하세요")), 5000);
    s.closeDiff();
    return [ok, s.diff?.error];
  });
  // 이미 바뀐 파일이 있는 상태에서 다른 파일을 저장하면 상태만 다시 읽고(git 3개) 그래프는 그대로 둔다
  await step("파일 저장 → 상태만 새로 고침", async () => {
    const graph = s.entries;
    await ipc.writeText(joinPath(repo, "README.md"), "# demo\n상태만 새로 고침\n");
    const ok = await until(() => !!s.unstagedStats["README.md"], 10000);
    return [ok && s.entries === graph, `stats=${JSON.stringify(s.unstagedStats["README.md"])} sameGraph=${s.entries === graph}`];
  });
  await step("스테이지", async () => {
    await s.stageAll();
    return [s.status.staged.length > 0 && !s.status.unstaged.length, `staged=${s.status.staged.length}`];
  });
  await step("커밋(한글 메시지)", async () => {
    const before = s.entries.filter((e) => !isWIP(e.commit)).length;
    s.setSummary("자동 점검 커밋");
    s.setMessage("본문 줄");
    await s.commit();
    const top = s.entries.find((e) => !isWIP(e.commit))?.commit;
    return [top?.subject === "자동 점검 커밋" && s.entries.length > before - 1 && statusIsEmpty(s.status), `top=${top?.subject} error=${s.errorMessage}`];
  });
  await step("커밋 상세", async () => {
    s.select({ kind: "commit", sha: s.headHash! });
    return [await until(() => s.detail?.summary === "자동 점검 커밋" && s.detailFiles.length > 0, 5000), `${s.detail?.summary} files=${s.detailFiles.length}`];
  });
  await step("브랜치 만들기·체크아웃", async () => {
    await s.createBranch("selftest/branch", s.headHash!, true);
    return [s.headBranch === "selftest/branch", s.headBranch];
  });
  await step("main 으로 돌아가 머지", async () => {
    const main = s.localBranches.find((b) => b.name === "main");
    if (!main) return [false, "main 없음"];
    await s.checkout(main);
    await s.merge("feature/login");
    return [s.headBranch === "main" && !s.errorMessage, `head=${s.headBranch} error=${s.errorMessage}`];
  });
  await step("커밋 검색", async () => {
    s.setSearch("login");
    const ok = await until(() => !s.searching && s.searchMatches.length > 0, 8000);
    const n = s.searchMatches.length;
    s.clearSearch();
    return [ok, n];
  });
  await step("Stash·Pop", async () => {
    await ipc.writeText(joinPath(repo, "README.md"), "changed by selftest\n");
    await until(() => !statusIsEmpty(s.status), 8000);
    await s.stash("selftest", true);
    const stashed = s.stashes.length > 0 && statusIsEmpty(s.status);
    await s.stashPop();
    return [stashed && !statusIsEmpty(s.status) && !s.stashes.length, `stashed=${stashed} stashes=${s.stashes.length} error=${s.errorMessage}`];
  });
  await step("변경 버리기", async () => {
    const c = s.status.unstaged[0];
    if (!c) return [false, "없음"];
    await s.run("버리기", ["restore", "--worktree", "--", c.path]);
    return [statusIsEmpty(s.status), JSON.stringify(s.status)];
  });

  // 터미널: 셸 실행, 출력, 터미널에서 친 git 명령이 그래프에 반영되는지
  await step("터미널 셸 실행", async () => {
    s.toggleTerminal();
    const t = s.activeTerminal!;
    const ok = await until(() => t.running && t.term.buffer.active.length > 0, 15000);
    await sleep(1500);
    await t.send("echo SELFTEST_OK\r");
    const echoed = await until(() => bufferText(t.term).split("\n").some((l) => l.trim() === "SELFTEST_OK"), 10000);
    return [ok && echoed, bufferText(t.term).slice(-300)];
  });
  await step("터미널의 git 명령 → 그래프 갱신", async () => {
    const t = s.activeTerminal!;
    await t.send('git commit --allow-empty -m "터미널에서 만든 커밋"\r');
    const ok = await until(() => s.entries.find((e) => !isWIP(e.commit))?.commit.subject === "터미널에서 만든 커밋", 15000);
    return [ok, s.entries[0]?.commit.subject];
  });

  // 도우미 모드(같은 실행 파일): git 자격 증명 응답, Claude Code 훅
  await step("Split the terminal panel (right, then down) and close the panes", async () => {
    const first = s.activeTerminal!;
    const right = s.splitTerminal(panes(s.terminalLayout!).find((p) => p.sessions.includes(first.id))!.id, "row");
    const down = s.splitTerminal(panes(s.terminalLayout!).find((p) => p.sessions.includes(right.id))!.id, "column");
    const shown = await until(() => document.querySelectorAll(".term-pane").length === 3, 3000);
    const ok = shown && down.directory === first.directory && s.activeTerminal === down && (await until(() => down.running, 15000));
    s.closeTerminal(down);
    s.closeTerminal(right);
    const merged = await until(() => document.querySelectorAll(".term-pane").length === 1, 3000);
    return [ok && merged && s.activeTerminal === first, `panes=${document.querySelectorAll(".term-pane").length} active=${s.activeTerminal?.title}`];
  });
  await step("GIT_ASKPASS 도우미", async () => {
    const r = await ipc.run(env.exe, ["Username for 'https://example.com': "], {
      env: { GITROCHI_ASKPASS: "1", GITROCHI_ASKPASS_COUNT: "1", GITROCHI_ASKPASS_HOST_1: "example.com", GITROCHI_ASKPASS_USER_1: "x-access-token", GITROCHI_ASKPASS_PASS_1: "secret" },
      timeoutMs: 15000,
    });
    const r2 = await ipc.run(env.exe, ["Password for 'https://x-access-token@example.com': "], {
      env: { GITROCHI_ASKPASS: "1", GITROCHI_ASKPASS_COUNT: "1", GITROCHI_ASKPASS_HOST_1: "example.com", GITROCHI_ASKPASS_USER_1: "x-access-token", GITROCHI_ASKPASS_PASS_1: "secret" },
      timeoutMs: 15000,
    });
    return [r.stdout.trim() === "x-access-token" && r2.stdout.trim() === "secret", `${r.status} [${r.stdout.trim()}] [${r2.stdout.trim()}] ${r.stderr}`];
  });
  await step("Claude Code 훅 도우미", async () => {
    const id = "selftest-" + Date.now();
    await ipc.run(env.exe, ["--agent-hook", "Stop"], { stdin: '{"session_id":"x"}', env: { GITROCHI_AGENT_ID: id }, timeoutMs: 15000 });
    const text = await ipc.readText(joinPath(env.dataDir, "agents", id + ".state"));
    await ipc.remove(joinPath(env.dataDir, "agents", id + ".state"));
    return [!!text && text.includes('"event":"Stop"'), text];
  });
  await step("자격 증명 저장소", async () => {
    // Use the real OS store, with an account owned only by this run. A failed assertion
    // must not leave a test credential behind or replace an existing user's account.
    const name = `selftest-${crypto.randomUUID()}`;
    const value = `값-${crypto.randomUUID()}`;
    try {
      await ipc.secretSet(name, value);
      const read = await ipc.secretGet(name);
      await ipc.secretSet(name, null);
      const gone = await ipc.secretGet(name);
      return [read === value && gone === null, `write/read=${read === value} removed=${gone === null}`];
    } finally {
      await ipc.secretSet(name, null);
    }
  });
  await step("HTTPS 요청", async () => {
    const r = await ipc.http("GET", "https://api.github.com/zen", { "User-Agent": "Gitrochi" });
    return [r.status === 200 || r.status === 403, r.status];
  });
  await step("DNS 조회", async () => {
    const a = await ipc.resolveHost("github.com");
    return [a.length > 0, a.join(",")];
  });
  // 도구: 자동으로 찾은 git 을 '직접 지정'으로 바꿨다가 되돌리기
  await step("도구 찾기·불러오기", async () => {
    const auto = tools.state.git;
    if (!auto.path) return [false, "git 못 찾음"];
    await tools.setCustom("git", auto.path);
    const custom = tools.state.git.source === "custom" && tools.state.git.path === auto.path;
    let rejected = false;
    try {
      await tools.setCustom("git", joinPath(repo, "README.md"));
    } catch {
      rejected = true;
    }
    await tools.resetToAuto("git");
    const shell = tools.path("shell");
    return [custom && rejected && tools.state.git.source === "auto" && !!shell, `git=${auto.path} custom=${custom} rejected=${rejected} shell=${shell} version=${tools.state.git.version}`];
  });

  // AI: 가짜 OpenAI 호환 서버(tests/mock-ai-server.mjs)가 떠 있으면 실제로 커밋 메시지를 받아 본다
  await step("AI(OpenAI 호환)로 커밋 메시지", async () => {
    const base = "http://127.0.0.1:18080/v1";
    try {
      const ping = await ipc.http("GET", base + "/models", {}, undefined, 3000);
      if (ping.status !== 200) return [true, "가짜 AI 서버 없음 — 건너뜀"];
    } catch {
      return [true, "가짜 AI 서버 없음 — 건너뜀"];
    }
    const prev = { provider: ai.provider, base: ai.baseURL, model: ai.models.compatible };
    ai.setProvider("compatible");
    ai.setBaseURL(base);
    const models = await ai.listModels("compatible");
    ai.setModel("compatible", models[0] ?? "mock-model");
    await ipc.writeText(joinPath(repo, "ai-test.txt"), "hello\n");
    await until(() => s.status.unstaged.some((c) => c.path === "ai-test.txt"), 8000);
    await s.stage(s.status.unstaged.filter((c) => c.path === "ai-test.txt"));
    await s.generateCommitMessage();
    const summary = s.summary;
    s.setSummary("");
    s.setMessage("");
    await s.unstageAll();
    await ipc.remove(joinPath(repo, "ai-test.txt"));
    ai.setProvider(prev.provider);
    ai.setBaseURL(prev.base);
    if (prev.model !== undefined) ai.setModel("compatible", prev.model);
    return [summary === "가짜 AI 커밋: ai-test.txt", `models=${models} summary=${summary} error=${s.errorMessage}`];
  });

  // 규칙 + 나눠서 커밋: 확장자별로 나누는 가짜 AI 로 2개 커밋이 생기는지
  await step("규칙 적용 + 나눠서 커밋", async () => {
    let up = false;
    try {
      up = (await ipc.http("GET", "http://127.0.0.1:18080/v1/models", {}, undefined, 3000)).status === 200;
    } catch {
      up = false;
    }
    if (!up) return [true, "가짜 AI 서버 없음 — 건너뜀"];
    const prev = { provider: ai.provider, base: ai.baseURL, rules: ai.instructions.commit ?? "" };
    ai.setProvider("compatible");
    ai.setBaseURL("http://127.0.0.1:18080/v1");
    ai.setModel("compatible", "mock-model");
    ai.setInstructions("commit", "1. RULE-TEST 규칙");
    for (const f of ["split-a.md", "split-b.md", "split-c.txt"]) await ipc.writeText(joinPath(repo, f), f + "\n");
    await until(() => s.splittableChanges.length >= 3, 8000);
    const before = s.entries.filter((e) => !isWIP(e.commit)).length;
    await s.planSplit();
    const plan = s.splitPlan ?? [];
    const planText = plan.map((g) => `${g.message}=[${g.files}]`).join(" ");
    s.sheet = null;
    const ok1 = plan.length === 2 && plan.every((g) => g.message.startsWith("Rule: "));
    await s.applySplit(plan);
    const after = s.entries.filter((e) => !isWIP(e.commit));
    const subjects = after.slice(0, 2).map((e) => e.commit.subject);
    ai.setInstructions("commit", prev.rules);
    ai.setProvider(prev.provider);
    ai.setBaseURL(prev.base);
    return [ok1 && after.length === before + 2 && subjects.includes("Rule: md 파일 정리") && subjects.includes("Rule: txt 파일 정리") && statusIsEmpty(s.status), `plan=${planText} subjects=${subjects} error=${s.errorMessage}`];
  });

  // 자동 업데이트: 가짜 업데이트 서버에서 서명이 맞는 파일만 받는지(점검용 빌드는 한 단계 낮은 버전으로 만든다)
  await step("자동 업데이트(서명 확인)", async () => {
    const base = "http://127.0.0.1:18080/update";
    let up = false;
    try {
      up = (await ipc.http("GET", base + "/latest.json", {}, undefined, 3000)).status === 200;
    } catch {
      up = false;
    }
    if (!up) return [true, "가짜 업데이트 서버 없음 — 건너뜀"];
    const info = await invoke<{ version: string; current: string } | null>("update_check", { endpoint: base + "/latest.json" });
    if (!info) return [false, `업데이트를 못 찾음(현재 ${env.version})`];
    const size = await invoke<number>("update_verify");
    await invoke("update_check", { endpoint: base + "/tampered.json" });
    let rejected = "";
    try {
      await invoke("update_verify");
    } catch (e) {
      rejected = String(e);
    }
    return [size > 0 && !!rejected, `version=${info.current}→${info.version} size=${size} tampered=${rejected.slice(0, 120)}`];
  });

  // WSL: 배포판 안의 (가짜) claude 로 글 작성·에이전트 세션·WSL 셸
  await step("WSL 의 Claude Code", async () => {
    const distros = await listDistros(true);
    if (!distros.length) return [true, "WSL 없음 — 건너뜀"];
    const distro = distros[0];
    const prevProvider = ai.provider;
    try {
      await tools.useWsl("claude", distro);
    } catch (e) {
      return [true, `${distro} 에 claude 없음 — 건너뜀 (${e})`];
    }
    const w = tools.wsl("claude");
    if (!w?.path.endsWith("/.claude/local/claude")) return [false, `alias 로만 잡힌 claude 를 못 찾음: ${w?.path}`];
    // 1) 커밋 메시지(시스템 지시는 임시 파일로 넘어감)
    ai.setProvider("claudeCode");
    await ipc.writeText(joinPath(repo, "ai-wsl.txt"), "wsl\n");
    await until(() => s.status.unstaged.some((c) => c.path === "ai-wsl.txt"), 8000);
    await s.stage(s.status.unstaged.filter((c) => c.path === "ai-wsl.txt"));
    await s.generateCommitMessage();
    const summary = s.summary;
    const aiErr = s.errorMessage;
    s.setSummary("");
    await s.unstageAll();
    await ipc.remove(joinPath(repo, "ai-wsl.txt"));
    // 2) 에이전트 세션: WSL 경로로 열리고, 훅(윈도 실행 파일)이 세션 상태를 남기는지
    await s.startAgent(repo, "", "bypassPermissions", "claude");
    const t = s.activeTerminal!;
    const pathOk = await until(() => bufferText(t.term).includes(`pwd=${toWslPath(repo)}`), 30000);
    const hookOk = await until(() => agents.sessions.some((x) => x.kind === "claude" && x.status === "waiting" && x.mode === "bypassPermissions"), 15000);
    // its own short line: the long session line wraps in the CI terminal
    const modeOk = await until(() => bufferText(t.term).includes("FAKE CLAUDE MODE=bypassPermissions"), 5000);
    const agentLine = bufferText(t.term).split("\n").find((l) => l.includes("FAKE CLAUDE")) ?? bufferText(t.term).slice(-300);
    t.terminate();
    // 3) 터미널 셸을 WSL 로
    tools.setShellWsl(distro);
    await until(() => tools.path("shell") === `wsl:${distro}`, 3000);
    const sh = s.newTerminal();
    const shellOk = await until(async () => {
      if (sh.running && !bufferText(sh.term).includes("WSLSHELL")) await sh.send("echo WSLSHELL:$WSL_DISTRO_NAME:$PWD\r");
      return bufferText(sh.term).split("\n").some((l) => l.trim() === `WSLSHELL:${distro}:${toWslPath(repo)}`);
    }, 30000);
    const shellLine = bufferText(sh.term).slice(-200);
    sh.terminate();
    await tools.resetToAuto("shell");
    tools.useWindows("claude");
    ai.setProvider(prevProvider);
    return [
      summary === `WSL 커밋: You write git / b/ai-wsl.txt` && pathOk && hookOk && modeOk && shellOk,
      `distro=${distro} path=${w?.path} summary=${summary} err=${aiErr} agent=${agentLine} hook=${hookOk} mode=${modeOk} shell=${shellOk} ${shellLine.replace(/\s+/g, " ")}`,
    ];
  });

  // CI/CD: 가짜 GitLab·GitHub 서버로 파이프라인·작업 읽기, 수동 작업 실행, 새 파이프라인, workflow_dispatch
  await step("CI/CD(수동 작업 실행·워크플로 실행)", async () => {
    const root = "http://127.0.0.1:18080";
    try {
      if ((await ipc.http("GET", root + "/ci/calls", {}, undefined, 3000)).status !== 200) return [true, "가짜 서버 없음 — 건너뜀"];
    } catch {
      return [true, "가짜 서버 없음 — 건너뜀"];
    }
    const gl = { target: { provider: "gitlab" as const, remote: "origin", host: "127.0.0.1", path: "g/p" }, token: "gl-token", apiBase: root + "/api/v4" };
    const pipes = await CIAPI.pipelines(gl, null);
    const jobs = await CIAPI.jobs(gl, pipes[0].id);
    const manual = jobs.filter(canPlay);
    await CIAPI.play(gl, manual[0].id);
    await CIAPI.runPipeline(gl, "main", [["DEPLOY_ENV", "staging"]]);
    const gh = { target: { provider: "github" as const, remote: "origin", host: "github.com", path: "o/r" }, token: "gh-token", apiBase: root + "/gh" };
    const flows = await CIAPI.workflows(gh, "main");
    await CIAPI.dispatch(gh, flows[0].id, "main", { target: "production" });
    const calls = JSON.parse((await ipc.http("GET", root + "/ci/calls", {})).body) as { url: string; body: unknown; token: string }[];
    const urls = calls.map((c) => c.url);
    // 그래프: 커밋에 파이프라인이 있으면 줄에 CI 상태 표시
    const head = s.headHash!;
    s.ci.showPipelines([{ id: 1, number: 7, name: "CI", title: "", ref: "main", sha: head, status: "failed", url: "http://127.0.0.1/p/1", created: null, event: "push", actor: null }]);
    const badge = await until(() => !!document.querySelector(".commit-row .ci-badge"), 3000);
    s.ci.reset();
    // 화면: CI/CD 탭이 그려지는지(이 저장소는 원격이 없어 안내 문구)
    settings.set("sidebarMode", "ci");
    const panel = await until(() => document.body.innerText.includes("원격이 있는 저장소에서 파이프라인"), 3000);
    settings.set("sidebarMode", "list");
    const ok =
      pipes.length === 1 &&
      pipes[0].status === "success" &&
      jobs.map((j) => j.name).join(",") === "build,deploy-prod" &&
      manual.length === 1 &&
      urls.includes("/api/v4/projects/g%2Fp/jobs/102/play") &&
      calls.some((c) => c.url === "/api/v4/projects/g%2Fp/pipeline" && JSON.stringify(c.body).includes("DEPLOY_ENV") && c.token === "gl-token") &&
      flows.length === 1 &&
      flows[0].inputs[0]?.options.join(",") === "staging,production" &&
      calls.some((c) => c.url === "/gh/repos/o/r/actions/workflows/7/dispatches" && JSON.stringify(c.body) === '{"ref":"main","inputs":{"target":"production"}}' && c.token === "Bearer gh-token") &&
      panel &&
      badge;
    return [ok, `badge=${badge} pipes=${pipes.length} jobs=${jobs.map((j) => `${j.stage}/${j.name}:${j.status}`)} flows=${flows.map((f) => f.name + ":" + f.inputs.map((i) => i.name))} calls=${urls} panel=${panel}`];
  });

  // 다른 브랜치에 머지: 방금 만든 브랜치(같은 커밋)를 그 줄에 놓으면 '이미 들어 있음', 커밋 후 놓으면 '…에 머지 — 체크아웃'
  await step("다른 브랜치에 머지(끌어다 놓기)", async () => {
    const base = s.headBranch!;
    const branch = "selftest/merge-into";
    await s.createBranch(branch, s.headHash!, true);
    const row = () => s.entries.find((e) => (s.refsByCommit.get(e.commit.id) ?? []).some((r) => r.name === base))!;
    const drop = async () => {
      s.dropRequest = null;
      s.handleDrop(branchPayload + branch, row());
      await until(() => !!s.dropRequest, 3000);
      const r = s.dropRequest as DropRequest | null; // handleDrop 이 비동기로 채운다
      s.dropRequest = null;
      return r;
    };
    const same = (await drop())?.title ?? "";
    await ipc.writeText(joinPath(repo, "merge-into.txt"), "merge\n");
    await until(() => s.status.unstaged.some((c) => c.path === "merge-into.txt"), 8000);
    await s.stageAll();
    s.setSummary("머지할 커밋");
    await s.commit();
    const req = await drop();
    const choice = req?.choices.find((c) => c.title.includes(`'${base}'에 머지`));
    await choice?.action();
    const merged = s.headBranch === base && (await s.isAncestor(`refs/heads/${branch}`, `refs/heads/${base}`));
    return [same.includes("이미") && !!choice && merged, `same=${same} choices=${req?.choices.map((c) => c.title)} head=${s.headBranch} merged=${merged}`];
  });

  // diff: 두 군데 고친 파일에서 한 줄만 스테이지, 나란히 보기, 이미지 비교
  await step("diff(줄 단위 스테이지·나란히·이미지)", async () => {
    const file = "lines.txt";
    const nums = Array.from({ length: 30 }, (_, i) => String(i + 1));
    await ipc.writeText(joinPath(repo, file), nums.join("\n") + "\n");
    await until(() => s.status.unstaged.some((c) => c.path === file), 8000);
    await s.stage(s.status.unstaged.filter((c) => c.path === file));
    s.setSummary("줄 파일");
    await s.commit();
    const edited = nums.map((n) => (n === "3" ? "three" : n === "15" ? "fifteen" : n === "16" ? "sixteen" : n));
    await ipc.writeText(joinPath(repo, file), edited.join("\n") + "\n");
    await until(() => s.status.unstaged.some((c) => c.path === file), 8000);
    s.openDiff({ kind: "working", change: s.status.unstaged.find((c) => c.path === file)! });
    await until(() => !!s.diff && s.diff.hunks.length === 2, 5000);
    const editable = s.canEditDiffLines;
    const idx = s.diff!.lines.findIndex((l) => l.kind === "added" && l.text === "sixteen");
    s.toggleDiffLine(idx, false);
    await s.applyLines("stage", s.diff!.lines[idx].hunk!);
    const staged = (await gitRaw(["diff", "--cached", "-U0"], repo)).stdout.split(/\r?\n/).filter((l) => /^[-+][^-+]/.test(l));
    s.setDiffSplit(true);
    const split = await until(() => !!document.querySelector(".diff-split-row"), 3000);
    s.setDiffSplit(false);
    s.closeDiff();
    await s.unstageAll();
    await gitRaw(["checkout", "--", file], repo);
    // 이미지: image-v2 의 그림으로 작업 트리만 바꾸고 비교
    await gitRaw(["restore", "--source=image-v2", "--worktree", "img.png"], repo);
    await until(() => s.status.unstaged.some((c) => c.path === "img.png"), 8000);
    s.openDiff({ kind: "working", change: s.status.unstaged.find((c) => c.path === "img.png")! });
    const images = await until(() => !!s.diffImages?.old && !!s.diffImages?.new, 8000);
    const shown = await until(() => document.querySelectorAll(".image-diff img").length === 2, 3000);
    s.closeDiff();
    await gitRaw(["checkout", "--", "img.png"], repo);
    await s.reload();
    const ok = editable && staged.join(",") === "+sixteen" && split && images && shown;
    return [ok, `editable=${editable} staged=${staged} split=${split} images=${images} shown=${shown} error=${s.errorMessage}`];
  });

  // PR·MR 리뷰: 가짜 GitHub·GitLab 으로 대화·승인 상태·바뀐 파일 읽기, 승인·댓글·승인 취소 보내기, 바뀐 파일 diff
  await step("PR·MR 리뷰(가짜 서버)", async () => {
    const root = "http://127.0.0.1:18080";
    try {
      if ((await ipc.http("GET", root + "/ci/calls", {}, undefined, 3000)).status !== 200) return [true, "가짜 서버 없음 — 건너뜀"];
    } catch {
      return [true, "가짜 서버 없음 — 건너뜀"];
    }
    const gh = { target: { provider: "github" as const, remote: "origin", host: "github.com", path: "o/r" }, token: "t", apiBase: root + "/gh", me: "lee" };
    const r = await ReviewAPI.load(gh, 5);
    await ReviewAPI.approve(gh, 5, "좋습니다");
    await ReviewAPI.comment(gh, 5, "고맙습니다");
    const gl = { target: { provider: "gitlab" as const, remote: "origin", host: "127.0.0.1", path: "g/p" }, token: "t", apiBase: root + "/api/v4", me: "lee" };
    const m = await ReviewAPI.load(gl, 5);
    await ReviewAPI.unapprove(gl, 5);
    const calls = (await ipc.http("GET", root + "/ci/calls", {})).body;
    s.openDiff({ kind: "review", number: 5, change: reviewFileChange(r.files[0]), patch: r.files[0].patch ?? "" });
    const diff = await until(() => !!s.diff && s.diff.lines.some((l) => l.kind === "added" && l.text === "B"), 3000);
    s.closeDiff();
    const ok =
      r.comments.map((c) => c.author).join(",") === "kim,kim,lee,park" &&
      r.state.approvedByMe &&
      r.state.changesRequestedBy.join() === "park" &&
      m.comments.some((c) => c.kind === "system") &&
      m.state.approvalsLeft === 1 &&
      calls.includes('"event":"APPROVE"') &&
      calls.includes("고맙습니다") &&
      calls.includes("/merge_requests/5/unapprove") &&
      diff;
    return [ok, `gh=${r.comments.map((c) => c.author + ":" + c.kind)} gl=${m.comments.length}/${m.state.approvalsLeft} diff=${diff}`];
  });

  await step("Markdown in PR text (no scripts, safe links only)", async () => {
    const el = document.createElement("div");
    document.body.appendChild(el);
    const root = createRoot(el);
    const text = '## Title\n\n- [x] done\n- [ ] todo\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n<script>window.mdHacked = 1</script><img src=x onerror="window.mdHacked = 1"> [js](javascript:window.mdHacked=1) Fixes #5';
    root.render(createElement(Markdown, { text, refs: markdownRefs({ provider: "github", remote: "origin", host: "github.com", path: "o/r" }), canLoadImage: () => false }));
    const drawn = await until(() => !!el.querySelector("table"), 3000);
    const links = Array.from(el.querySelectorAll("a")).map((a) => a.getAttribute("href") ?? "");
    const ok =
      drawn &&
      !!el.querySelector("h2") &&
      el.querySelectorAll("li.task input:checked").length === 1 &&
      !el.querySelector("script, img, iframe") &&
      links.join() === "https://github.com/o/r/issues/5" &&
      !(window as { mdHacked?: number }).mdHacked;
    const detail = `links=${links} tags=${Array.from(el.querySelectorAll("*")).map((e) => e.tagName.toLowerCase()).join(",")}`;
    root.unmount();
    el.remove();
    return [ok, detail];
  });

  // 파일 히스토리·blame: app.txt 를 바꾼 커밋들과 줄마다 마지막 커밋
  await step("파일 히스토리·줄별 작성자", async () => {
    s.openFileHistory("app.txt");
    const history = await until(() => s.fileHistory.length >= 4 && !!s.fileHistoryDiff?.lines.length, 8000);
    const rows = await until(() => document.querySelectorAll(".history-row").length >= 4, 3000);
    s.setFileInspectMode("blame");
    const blame = await until(() => s.blameLines.length >= 4 && s.blameLines.every((l) => l.author === "Self Test"), 8000);
    const gutter = await until(() => document.querySelectorAll(".blame-gutter").length >= 4, 3000);
    const n = s.fileHistory.length;
    s.closeFileInspect();
    return [history && rows && blame && gutter, `history=${n} rows=${rows} blame=${s.blameLines.length} gutter=${gutter}`];
  });

  await step("CLI 앱 링크 → 실행 중인 앱에서 파일·줄 이동", async () => {
    const route = new URL("gitrochi://open");
    route.searchParams.set("repo", repo);
    route.searchParams.set("file", "app.txt");
    route.searchParams.set("line", "3");
    const before = workspace.tabs.length;
    const result = await ipc.run(env.exe, [route.toString()], { timeoutMs: 10000 });
    let launches: Awaited<ReturnType<typeof ipc.takeAppLaunches>> = [];
    const received = await until(async () => {
      launches.push(...await ipc.takeAppLaunches());
      return launches.length > 0;
    }, 5000);
    const good = launches.find((item) => "Ok" in item);
    if (!good || !("Ok" in good)) return [false, JSON.stringify({ received, result, launches })];
    await applyAppLaunch(good.Ok);
    const focused = await until(() => !!document.querySelector('.blame-line[data-line="3"][data-focused="true"]'), 8000);
    const ok = focused && workspace.tabs.length === before && workspace.active === s && s.fileInspectLine === 3;
    s.closeFileInspect();
    return [ok, `received=${received} focused=${focused} tabs=${workspace.tabs.length}/${before}`];
  });

  // 그래프 거르기: 브랜치 숨기기(그 브랜치만의 커밋이 빠짐), 모두 보이기, 현재 브랜치만, 고정
  await step("그래프 거르기(숨기기·현재 브랜치만·고정)", async () => {
    const has = () => s.entries.some((e) => e.commit.subject === "이미지 바꿈");
    const b = s.localBranches.find((x) => x.name === "image-v2");
    if (!b) return [false, "image-v2 없음"];
    const before = has();
    await s.setHidden(b, true);
    const hidden = !has() && !(s.refsByCommit.get(b.target) ?? []).some((r) => r.name === "image-v2");
    await s.showAllBranches();
    const back = has();
    await s.setCurrentOnly(true);
    const current = !has() && s.entries.length > 0;
    await s.setCurrentOnly(false);
    s.setPinned(b, true);
    const pinned = await until(() => [...document.querySelectorAll(".side-section")].some((x) => x.textContent?.startsWith("고정")), 3000);
    s.setPinned(b, false);
    // the eye button on the sidebar row hides the branch and shows it again
    const eye = () => [...document.querySelectorAll(".side-row")].find((r) => r.textContent?.includes("image-v2"))?.querySelector<HTMLButtonElement>("button.icon-btn");
    eye()?.click();
    const eyeHid = await until(() => s.isHidden(b), 5000);
    eye()?.click();
    const eyeShown = await until(() => !s.isHidden(b) && has(), 5000);
    return [before && hidden && back && current && pinned && eyeHid && eyeShown, `before=${before} hidden=${hidden} back=${back} current=${current} pinned=${pinned} eye=${eyeHid}/${eyeShown}`];
  });

  // 충돌 해결: 두 브랜치에서 같은 줄을 고쳐 머지 → 화면의 충돌 블록에서 '상대 것'을 눌러 고르고 저장 → 머지 마침
  await step("충돌 해결 화면", async () => {
    const base = s.headBranch!;
    const file = "conflict.txt";
    const commitFile = async (text: string, summary: string) => {
      await ipc.writeText(joinPath(repo, file), text);
      await until(() => s.status.unstaged.some((c) => c.path === file), 8000);
      await s.stageAll();
      s.setSummary(summary);
      await s.commit();
    };
    await commitFile("1\n2\n3\n", "충돌 바탕");
    const branch = "selftest/conflict";
    await s.createBranch(branch, s.headHash!, true);
    await commitFile("1\ntwo-other\n3\n", "상대 쪽");
    await s.checkout(s.localBranches.find((x) => x.name === base)!);
    await commitFile("1\ntwo-main\n3\n", "내 쪽");
    await s.merge(branch);
    s.errorMessage = null;
    const conflicted = await until(() => s.status.conflicted.some((c) => c.path === file), 8000);
    s.openDiff({ kind: "working", change: s.status.conflicted.find((c) => c.path === file)! });
    const shown = await until(() => !!document.querySelector(".conflict-block"), 5000);
    const click = (text: string) => [...document.querySelectorAll<HTMLButtonElement>(".conflict-bar button, .conflict-block button")].find((b) => b.textContent?.trim() === text)?.click();
    click("상대 것");
    const chosen = await until(() => !!document.querySelector(".conflict-block.done"), 3000);
    click("저장하고 해결됨으로 표시");
    const resolved = await until(() => !s.status.conflicted.length && s.status.staged.some((c) => c.path === file), 8000);
    const text = ((await ipc.readText(joinPath(repo, file))) ?? "").replace(/\r\n/g, "\n");
    await s.continueOperation();
    const merged = s.repoState === "clean" && (s.entries.find((e) => !isWIP(e.commit))?.commit.parents.length ?? 0) === 2;
    s.closeDiff();
    const ok = conflicted && shown && chosen && resolved && text === "1\ntwo-other\n3\n" && merged;
    return [ok, `conflicted=${conflicted} shown=${shown} chosen=${chosen} resolved=${resolved} text=${JSON.stringify(text)} merged=${merged} error=${s.errorMessage}`];
  });

  // 되돌리기: 커밋 → 되돌리면 변경이 스테이지된 채로 돌아오고 메시지도 입력 칸에, 체크아웃 → 되돌리면 원래 브랜치
  await step("되돌리기(커밋·체크아웃)", async () => {
    const head = s.headHash;
    await ipc.writeText(joinPath(repo, "undo-test.txt"), "undo\n");
    await until(() => s.status.unstaged.some((c) => c.path === "undo-test.txt"), 8000);
    await s.stageAll();
    s.setSummary("되돌릴 커밋");
    await s.commit();
    const title = s.undoStack[s.undoStack.length - 1]?.title;
    await s.undo();
    const commitOk = s.headHash === head && s.status.staged.some((c) => c.path === "undo-test.txt") && s.summary === "되돌릴 커밋";
    await s.unstageAll();
    await ipc.remove(joinPath(repo, "undo-test.txt"));
    s.setSummary("");
    const base = s.headBranch;
    const other = s.localBranches.find((b) => !b.isCurrent);
    if (other) await s.checkout(other);
    const moved = s.headBranch !== base;
    await s.undo();
    const checkoutOk = moved && s.headBranch === base;
    return [commitOk && checkoutOk, `title=${title} commit=${commitOk} checkout=${checkoutOk} head=${s.headBranch} error=${s.errorMessage}`];
  });

  // 커밋 정리: 커밋 세 개를 만들고 가운데를 아래 커밋에 합치고 맨 위 메시지를 고친 뒤(실제 git rebase -i), 되돌리기
  await step("커밋 정리(인터랙티브 리베이스)", async () => {
    for (const n of [1, 2, 3]) {
      await ipc.writeText(joinPath(repo, `tidy-${n}.txt`), `${n}\n`);
      await until(() => s.status.unstaged.some((c) => c.path === `tidy-${n}.txt`), 8000);
      await s.stageAll();
      s.setSummary(`정리 ${n}`);
      await s.commit();
    }
    const first = s.entries.find((e) => e.commit.subject === "정리 1")?.commit.id ?? "";
    await s.startInteractiveRebase(first);
    const opened = await until(() => document.querySelectorAll(".rebase-item").length === 3, 3000);
    const plan = s.rebasePlan!;
    plan.items[0] = { ...plan.items[0], action: "reword", newMessage: "정리 3 고침 '따옴표'" };
    plan.items[1] = { ...plan.items[1], action: "squash" };
    s.sheet = null;
    s.changed();
    await s.runInteractiveRebase(plan);
    const log = (await gitRaw(["log", "-2", "--format=%s"], repo)).stdout.trim().split(/\r?\n/);
    const files = (await gitRaw(["show", "--name-only", "--format=", "HEAD~1"], repo)).stdout.trim().split(/\r?\n/);
    const tidied = log[0] === "정리 3 고침 '따옴표'" && log[1] === "정리 1" && files.join(",") === "tidy-1.txt,tidy-2.txt" && s.repoState === "clean";
    const title = s.undoStack[s.undoStack.length - 1]?.title;
    await s.undo();
    const back = (await gitRaw(["log", "-3", "--format=%s"], repo)).stdout.trim().split(/\r?\n/).join(",") === "정리 3,정리 2,정리 1";
    return [opened && tidied && title === "커밋 정리" && back, `opened=${opened} log=${log} files=${files} title=${title} back=${back} error=${s.errorMessage}`];
  });

  // 탭 우클릭 → '다른 탭 모두 닫기': 실제 화면의 탭에서 메뉴를 띄워 눌러 본다
  await step("탭 우클릭 메뉴(다른 탭 모두 닫기)", async () => {
    workspace.newTab();
    workspace.newTab();
    workspace.select(s.id);
    await until(() => document.querySelectorAll(".tabbar .tab").length === workspace.tabs.length, 3000);
    const before = workspace.tabs.length;
    const el = document.querySelectorAll(".tabbar .tab")[workspace.tabs.indexOf(s)] as HTMLElement | undefined;
    el?.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 40, clientY: 20 }));
    const shown = await until(() => [...document.querySelectorAll(".menu-item")].some((m) => m.textContent?.includes("다른 탭 모두 닫기")), 3000);
    const labels = [...document.querySelectorAll(".menu-item .label")].map((m) => m.textContent);
    ([...document.querySelectorAll(".menu-item")].find((m) => m.textContent?.includes("다른 탭 모두 닫기")) as HTMLElement | undefined)?.click();
    const closed = await until(() => workspace.tabs.length === 1 && workspace.tabs[0] === s && !!s.path, 3000);
    return [shown && closed && before >= 3, `before=${before} after=${workspace.tabs.length} menu=${labels}`];
  });

  // 저장소 메뉴의 바뀐 의존 · 의존 규칙 검사(gitch graph diff · check): 메뉴가 켜지고 페이지 · 검사 결과가 나오는지(브라우저는 열지 않는다)
  await step("바뀐 의존 · 의존 규칙 검사(gitch graph)", async () => {
    const reason = await gitch.checkGraph();
    if (reason) return [true, `앱에 든 gitch 를 쓸 수 없음 — 건너뜀 (${reason})`];
    const menus = structureGraphMenus(s).filter((m) => m !== "divider");
    const menuOk = menus.length === 3 && menus.every((m) => !m.disabled);
    const page = await gitch.graphDiff("tree", "v0.1", repo);
    const pageOk = await ipc.exists(page);
    const dir = joinPath(repo, ".gitch");
    await ipc.writeText(joinPath(repo, graphRulesFile), "[files]\nno-cycles\n");
    try {
      await s.runGraphCheck();
      const c = s.graphCheck;
      const ok = menuOk && pageOk && c?.kind === "done" && c.rules === 1 && c.result.ok;
      return [ok, `menus=${menus.map((m) => `${m.label}${m.disabled ? "(off)" : ""}`)} diff=${page} (${pageOk}) check=${JSON.stringify(c)}`];
    } finally {
      s.graphCheck = null;
      await ipc.remove(dir);
    }
  });

  // 테마: 다크·라이트로 바꾸면 화면 색과 창 제목 표시줄 테마가 따라오는지, 시스템으로 되돌리기
  await step("테마(시스템·라이트·다크)", async () => {
    const bg = () => getComputedStyle(document.documentElement).getPropertyValue("--bg").trim();
    const win = getCurrentWindow();
    theme.setMode("dark");
    await sleep(300);
    const dark = { attr: document.documentElement.dataset.theme, bg: bg(), win: await win.theme() };
    theme.setMode("light");
    await sleep(300);
    const light = { attr: document.documentElement.dataset.theme, bg: bg(), win: await win.theme() };
    let setErr = "";
    await win.setTheme("dark").catch((e) => (setErr = String(e)));
    theme.setMode("system");
    await sleep(200);
    const ok = dark.attr === "dark" && dark.bg === "#1e1e21" && light.attr === "light" && light.bg === "#f3f3f4" && !setErr && (dark.win === "dark" || env.os !== "windows");
    return [ok, `dark=${JSON.stringify(dark)} light=${JSON.stringify(light)} setTheme=${setErr || "ok"} system=${document.documentElement.dataset.theme}`];
  });

  await step("Switch worktrees in the same tab (terminals follow)", async () => {
    const wt = joinPath(dirname(repo), "selftest-worktree");
    await gitRaw(["worktree", "add", "-b", "selftest-worktree", wt], repo);
    await s.reload();
    const inWorktree = s.newTerminal(wt);
    const inRepo = s.newTerminal(repo);
    const tabs = workspace.tabs.length;
    await s.switchWorktree(wt);
    const switched = samePath(s.path, wt) && workspace.tabs.length === tabs && s.activeTerminal === inWorktree;
    await s.switchWorktree(repo);
    const back = samePath(s.path, repo) && s.activeTerminal === inRepo && s.terminals.includes(inWorktree);
    // the other worktree's change shows as its own row in this tab's graph, with a read-only diff
    await ipc.writeText(joinPath(wt, "from-worktree.txt"), "W\n");
    await s.refreshWorktreeStats();
    const row = await until(() => s.entries.some((e) => samePath(wipWorktree(e.commit) ?? "", wt)), 8000);
    const file = statusFiles(s.worktreeStatus[s.worktrees.find((w) => samePath(w.path, wt))?.path ?? ""] ?? emptyStatus())[0];
    if (file) s.openDiff({ kind: "worktree", path: s.worktrees.find((w) => samePath(w.path, wt))!.path, change: file });
    const diff = !!file && (await until(() => !!s.diff?.lines.some((l) => l.kind === "added" && l.text === "W"), 5000));
    s.closeDiff();
    const detail = `path=${s.path} tabs=${workspace.tabs.length}/${tabs} terminal=${s.activeTerminal?.directory} row=${row} diff=${diff}`;
    s.closeTerminal(inWorktree);
    s.closeTerminal(inRepo);
    await gitRaw(["worktree", "remove", "--force", wt], repo);
    await gitRaw(["branch", "-D", "selftest-worktree"], repo);
    await s.reload();
    return [switched && back && row && diff, detail];
  });

  await step("설정 화면", async () => {
    window.dispatchEvent(new KeyboardEvent("keydown", { key: ",", ctrlKey: !isMacLike(), metaKey: isMacLike(), bubbles: true }));
    const ok = await until(() => !!document.querySelector(".modal") && document.body.innerText.includes("사내 GitLab"), 3000);
    window.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
    await sleep(200);
    return [ok, ""];
  });

  await step("No uncaught errors and the app still renders", async () => {
    const alive = !!document.querySelector(".repo");
    return [uncaught.length === 0 && alive, `alive=${alive} ${uncaught.slice(0, 3).join(" | ")}`];
  });

  // 화면 캡처용: 그래프 + 터미널이 보이는 상태로 둔다
  s.select({ kind: "wip" });
  s.select({ kind: "commit", sha: s.headHash! });
  const result = { ok: checks.every((c) => c.ok), os: env.os, windows: isWindows(), checks };
  await ipc.writeText(out, JSON.stringify(result, null, 2));
  if (env.selftestOpen) window.dispatchEvent(new CustomEvent("gitrochi-open-settings", { detail: env.selftestOpen }));
  return true;
}

function isMacLike() {
  return env.os === "macos";
}

function bufferText(term: import("@xterm/xterm").Terminal) {
  const b = term.buffer.active;
  const lines: string[] = [];
  for (let i = 0; i < b.length; i++) lines.push(b.getLine(i)?.translateToString(true) ?? "");
  return lines.join("\n");
}
