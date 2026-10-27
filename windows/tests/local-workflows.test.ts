import { execFileSync } from "node:child_process";
import { existsSync, lstatSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
vi.hoisted(() => vi.stubGlobal("matchMedia", () => ({ matches: false, addEventListener() {} })));
vi.mock("@/entities/terminal", () => ({ TerminalSession: class {} }));
let fixture = "";
vi.mock("@/shared/api/ipc", () => ({ ipc: {
  run: async (exe: string, args: string[], o: { cwd: string; env: Record<string, string>; stdin?: string }) => {
    const options = { cwd: o.cwd, env: { ...process.env, GIT_CONFIG_GLOBAL: join(fixture, "empty-config"), GIT_CONFIG_NOSYSTEM: "1", ...o.env }, input: o.stdin, encoding: "utf8" as const, stdio: "pipe" as const };
    try { return { status: 0, stdout: execFileSync(exe, args, options), stderr: "" }; }
    catch (e) { const error = e as { status: number; stdout: string; stderr: string }; return { status: error.status, stdout: error.stdout, stderr: error.stderr }; }
  },
  readHead: async (path: string) => ({ size: lstatSync(path).size }),
  remove: async (path: string) => { rmSync(path, { force: true }); },
  exists: async (path: string) => existsSync(path),
} }));
import { RepoStore } from "@/entities/repo";
import { git } from "@/shared/platform";
import { conflictProjection, parseConflict } from "@/entities/git";
import { parseRecoveryRefs, parseReflog, safeRepoPath, safeSubmoduleURL } from "@/entities/repo/lib/local-workflows";

let repo = "";
beforeEach(async () => {
  fixture = mkdtempSync(join(tmpdir(), "gitrochi-local-tools-")); writeFileSync(join(fixture, "empty-config"), "");
  await git(["init", "-q", "repo"], fixture); repo = join(fixture, "repo");
  // Git for Windows initializes repositories with symlink checkout disabled.
  await git(["config", "core.symlinks", "true"], repo);
  await git(["config", "user.name", "Fixture"], repo); await git(["config", "user.email", "fixture@example.com"], repo);
});
afterEach(() => { vi.restoreAllMocks(); rmSync(fixture, { recursive: true, force: true }); });
const makeStore = () => { const store = new RepoStore(); store.path = repo; store.gitDir = join(repo, ".git"); vi.spyOn(store, "reload").mockResolvedValue(undefined); return store; };

describe("로컬 안전 사본", () => {
  it("바이너리·새 파일·심볼릭 링크·별도 스테이지를 파일 이동 없이 보관하고 복원한다", async () => {
    // Git for Windows otherwise checks symlinks out as regular files, even when creation is allowed.
    await git(["config", "core.symlinks", "true"], repo);
    writeFileSync(join(repo, "file.txt"), "base\n"); await git(["add", "-A"], repo); await git(["commit", "-qm", "Base"], repo);
    writeFileSync(join(repo, "file.txt"), "staged\n"); await git(["add", "file.txt"], repo); writeFileSync(join(repo, "file.txt"), "unstaged\n");
    const binary = Buffer.from([0, 255, 42, 10]); writeFileSync(join(repo, "new.bin"), binary); symlinkSync("file.txt", join(repo, "link"));
    expect(lstatSync(join(repo, "link")).isSymbolicLink()).toBe(true);
    const before = (await git(["status", "--porcelain=v2", "-z"], repo)).stdout;
    const store = makeStore(); expect(await store.preserveDiscardedChanges(["file.txt"])).toBe(true);
    expect((await git(["log", "--all", "--oneline"], repo)).stdout).toContain("Base");
    expect((await git(["status", "--porcelain=v2", "-z"], repo)).stdout).toBe(before);
    expect(readFileSync(join(repo, "file.txt"), "utf8")).toBe("unstaged\n");
    await store.loadLocalWorkflows(); expect(store.localWorkflows.recovery).toHaveLength(1);
    const copy = store.localWorkflows.recovery[0];
    await git(["reset", "--hard", "HEAD"], repo); await git(["clean", "-fd"], repo);
    await store.restoreSafetyCopy(copy); await store.confirm!.action();
    expect(readFileSync(join(repo, "file.txt"), "utf8")).toBe("unstaged\n");
    expect((await git(["show", ":file.txt"], repo)).stdout).toBe("staged\n");
    expect(readFileSync(join(repo, "new.bin"))).toEqual(binary); expect(lstatSync(join(repo, "link")).isSymbolicLink()).toBe(true);
    expect((await git(["status", "--porcelain=v2", "-z"], repo)).stdout).toBe(before);
  });
  it("첫 커밋 전 스테이지와 새 파일도 보관한다", async () => {
    writeFileSync(join(repo, "staged.txt"), "staged"); await git(["add", "staged.txt"], repo); writeFileSync(join(repo, "new.txt"), "new");
    const store = makeStore(); expect(await store.preserveDiscardedChanges()).toBe(true);
    const refs = (await git(["for-each-ref", "--format=%(refname) %(objectname)", "refs/gitrochi/safety"], repo)).stdout;
    const [copy] = parseRecoveryRefs(refs); expect(copy).toBeDefined(); expect((await git(["show", `${copy.worktree}:new.txt`], repo)).stdout).toBe("new");
  });
  it("현재 작업 파일이 있으면 복원하지 않고 안전 사본을 유지한다", async () => {
    writeFileSync(join(repo, "file.txt"), "base"); await git(["add", "-A"], repo); await git(["commit", "-qm", "Base"], repo);
    writeFileSync(join(repo, "file.txt"), "saved"); const store = makeStore(); expect(await store.preserveDiscardedChanges()).toBe(true); await store.loadLocalWorkflows();
    writeFileSync(join(repo, "file.txt"), "new work"); await store.restoreSafetyCopy(store.localWorkflows.recovery[0]); await store.confirm!.action();
    expect(readFileSync(join(repo, "file.txt"), "utf8")).toBe("new work"); expect(store.errorMessage).toContain("clean working tree");
  });
  it("다른 워크트리의 사본을 섞지 않는다", async () => {
    await git(["commit", "--allow-empty", "-qm", "Base"], repo); writeFileSync(join(repo, "new.txt"), "copy"); const store = makeStore(); expect(await store.preserveDiscardedChanges()).toBe(true);
    const other = join(fixture, "other"); await git(["worktree", "add", "--detach", other, "HEAD"], repo); const second = new RepoStore(); second.path = other; await second.loadLocalWorkflows(); expect(second.localWorkflows.recovery).toEqual([]);
  });
  it("reflog 항목은 현재 체크아웃을 바꾸지 않고 새 브랜치로 복구한다", async () => {
    await git(["commit", "--allow-empty", "-qm", "Base"], repo); const sha = (await git(["rev-parse", "HEAD"], repo)).stdout.trim(); const original = (await git(["symbolic-ref", "HEAD"], repo)).stdout;
    const store = makeStore(); await store.recoverCommit(sha, "recovered-work"); expect((await git(["rev-parse", "recovered-work"], repo)).stdout.trim()).toBe(sha); expect((await git(["symbolic-ref", "HEAD"], repo)).stdout).toBe(original);
  });
});

describe("도구 입력 및 충돌 결과", () => {
  it.each(["../private", "/absolute", "C:/private", "a/.git/config", "-option", "a\\b", "a\nfile"])("위험한 경로를 거절한다: %s", (path) => expect(safeRepoPath(path)).toBe(false));
  it.each(["file:///private", "ext::command", "../relative", "https://user:token@example.com/repo", "ssh://-oProxyCommand=bad/repo", "https://example.com/a%0arepo"])("안전하지 않은 하위 저장소 URL을 거절한다: %s", (url) => expect(safeSubmoduleURL(url)).toBe(false));
  it.each(["https://example.com/repo.git", "git@example.com:org/repo.git", "ssh://git@example.com:2222/org/repo.git"])("검토 가능한 서버 URL을 허용한다: %s", (url) => expect(safeSubmoduleURL(url)).toBe(true));
  it("세 열 결과는 비충돌 내용을 포함하고 미선택 표식을 남긴다", () => {
    const doc = parseConflict("before\n<<<<<<< HEAD\nmine\n||||||| base\nold\n=======\ntheirs\n>>>>>>> topic\nafter\n");
    expect(conflictProjection(doc, "ours")).toBe("before\nmine\nafter\n"); expect(conflictProjection(doc, "base")).toBe("before\nold\nafter\n"); expect(parseConflict(conflictProjection(doc, "result")).blocks).toHaveLength(1);
    expect(conflictProjection(doc, "result", new Map([[0, { kind: "theirs" }]]))).toBe("before\ntheirs\nafter\n");
  });
  it("reflog 레코드와 불완전한 사본을 구분한다", () => { expect(parseReflog(`${"a".repeat(40)}\x1fHEAD@{0}\x1fcommit: Base\x1f2026-01-01`)).toHaveLength(1); expect(parseRecoveryRefs(`refs/gitrochi/safety/123-a/worktree ${"a".repeat(40)}`)).toEqual([]); });
});

describe("문제 커밋 찾기와 저장소 도구", () => {
  it("정상/문제 커밋 사이를 실제 bisect로 탐색하고 원래 브랜치로 돌아온다", async () => {
    const commits: string[] = [];
    for (let i = 0; i < 5; i++) { await git(["commit", "--allow-empty", "-qm", `Fixture ${i}`], repo); commits.push((await git(["rev-parse", "HEAD"], repo)).stdout.trim()); }
    const original = (await git(["symbolic-ref", "HEAD"], repo)).stdout;
    const store = makeStore(); await store.startBisect(commits[0], commits[4]);
    expect((await git(["symbolic-ref", "HEAD"], repo)).stdout).toBe(original);
    await store.confirm!.action(); expect(store.localWorkflows.bisectActive).toBe(true);
    let turns = 0;
    while (!store.localWorkflows.bisectResult && turns++ < 6) { const sha = (await git(["rev-parse", "HEAD"], repo)).stdout.trim(); await store.markBisect(commits.indexOf(sha) >= 2 ? "bad" : "good"); }
    expect(store.localWorkflows.bisectResult).toContain(commits[2]);
    await store.resetBisect(); expect(store.localWorkflows.bisectActive).toBe(false); expect((await git(["symbolic-ref", "HEAD"], repo)).stdout).toBe(original);
  });
  it("bisect 확인 이후 생긴 작업 변경을 건드리지 않는다", async () => {
    await git(["commit", "--allow-empty", "-qm", "Good"], repo); const good = (await git(["rev-parse", "HEAD"], repo)).stdout.trim(); await git(["commit", "--allow-empty", "-qm", "Bad"], repo);
    const store = makeStore(); await store.startBisect(good, "HEAD"); writeFileSync(join(repo, "new.txt"), "keep this"); await store.confirm!.action();
    expect(store.errorMessage).toContain("repository changed"); expect(readFileSync(join(repo, "new.txt"), "utf8")).toBe("keep this");
  });
  it("LFS 잠금 해제는 명시 확인 후 force 없이 실행한다", async () => {
    const store = makeStore(); const run = vi.spyOn(store, "run").mockResolvedValue(false);
    await store.lfsUnlock("123"); expect(run).not.toHaveBeenCalled(); await store.confirm!.action(); expect(run).toHaveBeenCalledWith(expect.any(String), ["lfs", "unlock", "--id=123"], { network: true });
  });
  it("하위 저장소는 검토한 HTTPS 주소와 기록된 정확한 SHA로 갱신한다", async () => {
    await git(["commit", "--allow-empty", "-qm", "Fixture"], repo); const sha = (await git(["rev-parse", "HEAD"], repo)).stdout.trim();
    writeFileSync(join(repo, ".gitmodules"), "[submodule \"library\"]\n\tpath = vendor/library\n\turl = https://example.com/library.git\n");
    await git(["update-index", "--add", "--cacheinfo", `160000,${sha},vendor/library`], repo);
    const store = makeStore(); await store.loadLocalWorkflows(); expect(store.localWorkflows.submodules[0].sha).toBe(sha);
    const run = vi.spyOn(store, "run").mockResolvedValue(false);
    await store.updateSubmodule(store.localWorkflows.submodules[0]); expect(run).not.toHaveBeenCalled(); await store.confirm!.action();
    expect(run).toHaveBeenCalledWith(expect.any(String), ["-c", "protocol.file.allow=never", "-c", "protocol.ext.allow=never", "-c", "submodule.library.url=https://example.com/library.git", "submodule", "update", "--init", "--checkout", "--", "vendor/library"], { network: false });
  });
});
