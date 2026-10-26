import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, realpathSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { buildPatch } from "@/entities/git/lib/diff";
import { CommitSearchQuery } from "@/entities/git/lib/search";
import { fileHistoryFormat, parseDiff, parseFileHistory, parseWorktrees } from "@/entities/git/lib/parsers";

vi.hoisted(() => vi.stubGlobal("matchMedia", () => ({ matches: false, addEventListener() {} })));
vi.mock("@/entities/terminal", () => ({ TerminalSession: class {} }));
import { RepoStore } from "@/entities/repo";

let fixture = "";
vi.mock("@/shared/api/ipc", () => ({
  ipc: {
    remove: async (path: string) => { rmSync(path, { force: true }); },
    readHead: async (path: string, max: number) => {
      const data = readFileSync(path);
      return { text: data.subarray(0, max).toString("utf8"), binary: data.includes(0), truncated: data.length > max, size: statSync(path).size };
    },
    run: async (exe: string, args: string[], o: { cwd: string; env: Record<string, string>; stdin?: string }) => {
      const options = { cwd: o.cwd, env: { ...process.env, GIT_CONFIG_GLOBAL: join(fixture, "empty-config"), GIT_CONFIG_NOSYSTEM: "1", ...o.env }, input: o.stdin, encoding: "utf8" as const, stdio: "pipe" as const };
      try {
        return { status: 0, stdout: execFileSync(exe, args, options), stderr: "" };
      } catch (e) {
        const err = e as { status: number; stdout: string; stderr: string };
        return { status: err.status, stdout: err.stdout, stderr: err.stderr };
      }
    },
  },
}));
const { git, gitRaw } = await import("@/shared/platform/git");

beforeEach(async () => {
  fixture = mkdtempSync(join(tmpdir(), "gitrochi-git-test-"));
  writeFileSync(join(fixture, "empty-config"), "");
  await git(["init", "-q", "repo"], fixture);
  await git(["config", "user.name", "Fixture"], join(fixture, "repo"));
  await git(["config", "user.email", "fixture@example.com"], join(fixture, "repo"));
});
afterEach(() => { vi.restoreAllMocks(); rmSync(fixture, { recursive: true, force: true }); });

describe("실제 Git과 파일 경계·패치 적용", () => {
  it.each([
    ["정리 1", "정리1"], ["정리1", "정 리 1"], ["정\t리   1", "정리 1"],
    ["Re Lease 2", "release2"], ["기능 🚀 2", "기능🚀2"],
    [String.raw`release [1].*+?(){}^$|\done`, String.raw`release[1].*+?(){}^$|\done`],
  ])("공백을 무시해 Git 본문을 검색한다: %j ← %j", async (message, query) => {
    const repo = join(fixture, "repo");
    await git(["commit", "--allow-empty", "-qm", "Search fixture", "-m", message], repo);
    const search = new CommitSearchQuery(query);
    const result = await git(["log", "--format=%s", "-i", "-E", "--grep=" + search.gitPattern], repo);
    expect(result.stdout.trim()).toBe("Search fixture");
  });

  it("공백 무시 검색에서도 특수문자는 문자 그대로 찾는다", async () => {
    const repo = join(fixture, "repo");
    await git(["commit", "--allow-empty", "-qm", "정리1xyz"], repo);
    const search = new CommitSearchQuery("정리[1].*");
    const result = await git(["log", "--format=%H", "-i", "-E", "--grep=" + search.gitPattern], repo);
    expect(result.stdout).toBe("");
  });

  it("첫 커밋을 되돌리면 커밋 없는 브랜치와 스테이지 내용으로 돌아간다", async () => {
    const repo = join(fixture, "repo");
    writeFileSync(join(repo, "f.txt"), "keep staged\n");
    await git(["add", "f.txt"], repo);
    const store = new RepoStore();
    store.path = repo;
    vi.spyOn(store, "reload").mockResolvedValue(undefined);
    expect(await store.run("commit", ["commit", "-m", "first"])).toBe(true);
    await store.undo();
    expect((await gitRaw(["rev-parse", "--verify", "HEAD"], repo)).status).not.toBe(0);
    expect((await git(["show", ":f.txt"], repo)).stdout).toBe("keep staged\n");
    expect(readFileSync(join(repo, "f.txt"), "utf8")).toBe("keep staged\n");
    expect(store.summary).toBe("first");
  });

  it("첫 커밋 전 전체 버리기는 스테이지 파일까지 비운다", async () => {
    const repo = join(fixture, "repo");
    writeFileSync(join(repo, "f.txt"), "staged\n");
    await git(["add", "f.txt"], repo);
    const store = new RepoStore();
    store.path = repo;
    vi.spyOn(store, "reload").mockResolvedValue(undefined);
    store.confirmDiscardAll();
    await store.confirm!.action();
    expect((await git(["ls-files"], repo)).stdout).toBe("");
    expect((await git(["status", "--porcelain"], repo)).stdout).toBe("");
  });
  it("대괄호 파일 하나를 스테이지하고 버려도 다른 파일은 바꾸지 않는다", async () => {
    const repo = join(fixture, "repo");
    for (const p of ["[a].txt", "a.txt"]) writeFileSync(join(repo, p), "base\n");
    await git(["add", "--", "[a].txt"], repo);
    expect((await git(["diff", "--cached", "--name-only", "-z"], repo)).stdout).toBe("[a].txt\0");
    await git(["add", "-A"], repo);
    await git(["commit", "-qm", "base"], repo);
    for (const p of ["[a].txt", "a.txt"]) writeFileSync(join(repo, p), "changed\n");
    await git(["restore", "--worktree", "--", "[a].txt"], repo);
    expect(readFileSync(join(repo, "[a].txt"), "utf8")).toBe("base\n");
    expect(readFileSync(join(repo, "a.txt"), "utf8")).toBe("changed\n");
    expect((await git(["log", "--format=%s", "--", ":(glob)**/*.txt"], repo, { env: { GIT_LITERAL_PATHSPECS: "0" } })).stdout.trim()).toBe("base");
  });

  it.each([false, true])("떨어진 덩어리를 골라 실제로 스테이지·역적용한다: reverse=%s", async (reverse) => {
    const repo = join(fixture, "repo");
    const old = Array.from({ length: 50 }, (_, n) => `line ${n + 1}`);
    writeFileSync(join(repo, "f.txt"), old.join("\n") + "\n");
    await git(["add", "f.txt"], repo);
    await git(["commit", "-qm", "base"], repo);
    const changed = [...old];
    changed.splice(2, 0, "inserted 1", "inserted 2");
    changed[26] = "replacement";
    writeFileSync(join(repo, "f.txt"), changed.join("\n") + "\n");
    const doc = parseDiff((await git(["diff", "--no-ext-diff"], repo)).stdout);
    expect(doc.hunks).toHaveLength(2);
    const patch = buildPatch(doc, [1], null, reverse)!;
    await git(["apply", "--recount", ...(reverse ? ["--reverse"] : ["--cached"]), "-"], repo, { input: patch });
    if (reverse) {
      const expected = [...old];
      expected.splice(2, 0, "inserted 1", "inserted 2");
      expect(readFileSync(join(repo, "f.txt"), "utf8")).toBe(expected.join("\n") + "\n");
    } else {
      const expected = [...old];
      expected[24] = "replacement";
      expect((await git(["show", ":f.txt"], repo)).stdout).toBe(expected.join("\n") + "\n");
    }
  });

  it("CRLF 마지막 줄의 스테이지가 줄 끝을 바꾸지 않는다", async () => {
    const repo = join(fixture, "repo");
    await git(["config", "core.autocrlf", "false"], repo);
    writeFileSync(join(repo, "f.txt"), "old\r\n");
    await git(["add", "f.txt"], repo);
    await git(["commit", "-qm", "base"], repo);
    writeFileSync(join(repo, "f.txt"), "new\r\n");
    const doc = parseDiff((await git(["diff"], repo)).stdout);
    await git(["apply", "--cached", "--recount", "-"], repo, { input: buildPatch(doc, [0], null, false)! });
    expect((await git(["show", ":f.txt"], repo)).stdout).toBe("new\r\n");
  });

  it.each([
    ["", "\n"], ["a\n", ""], ["a", "b"], ["a", "a\n"], ["a\n", "a"],
    ["a\r\nb", "a\r\nc"], ["\t한글\n", "\t변경\n"],
  ])("빈 파일·마지막 줄바꿈 변화를 실제로 왕복 적용한다: %j → %j", async (before, after) => {
    const repo = join(fixture, "repo");
    await git(["config", "core.autocrlf", "false"], repo);
    writeFileSync(join(repo, "f.txt"), before);
    await git(["add", "f.txt"], repo);
    await git(["commit", "-qm", "base"], repo);
    writeFileSync(join(repo, "f.txt"), after);
    const doc = parseDiff((await git(["diff", "--", "f.txt"], repo)).stdout);
    const hunks = doc.hunks.map((_, i) => i);
    await git(["apply", "--cached", "--recount", "-"], repo, { input: buildPatch(doc, hunks, null, false)! });
    expect((await git(["show", ":f.txt"], repo)).stdout).toBe(after);
    await git(["apply", "--cached", "--reverse", "--recount", "-"], repo, { input: buildPatch(doc, hunks, null, true)! });
    expect((await git(["show", ":f.txt"], repo)).stdout).toBe(before);
  });

  it.skipIf(process.platform === "win32")("Git 출력의 특수문자 파일명과 워크트리 경로를 그대로 읽는다", async () => {
    const repo = join(fixture, "repo");
    const path = '한글\n\x1e\t".txt';
    writeFileSync(join(repo, path), "text\n");
    await git(["add", "--", path], repo);
    await git(["commit", "-qm", "base"], repo);
    const history = await git(["log", "--follow", "--name-only", "-z", "--format=" + fileHistoryFormat, "--", path], repo);
    expect(parseFileHistory(history.stdout).map((e) => e.path)).toEqual([path]);
    const wt = join(fixture, '한글\n\t"worktree');
    await git(["worktree", "add", "-b", "topic", wt], repo);
    const worktrees = parseWorktrees((await git(["worktree", "list", "--porcelain", "-z"], repo)).stdout);
    expect(worktrees).toHaveLength(2);
    expect(worktrees[1].path).toBe(realpathSync(wt));
  });
});
