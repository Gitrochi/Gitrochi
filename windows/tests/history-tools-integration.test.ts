import { execFileSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { layoutGraph, logFormat, parseLog } from "@/entities/git";
vi.hoisted(() => vi.stubGlobal("matchMedia", () => ({ matches: false, addEventListener() {} })));
vi.mock("@/entities/terminal", () => ({ TerminalSession: class {} }));
let fixture = "";
vi.mock("@/shared/api/ipc", () => ({ ipc: {
  run: async (exe: string, args: string[], options: { cwd: string; env: Record<string, string>; stdin?: string }) => {
    try { return { status: 0, stdout: execFileSync(exe, args, { cwd: options.cwd, env: { ...process.env, GIT_CONFIG_GLOBAL: join(fixture, "empty-config"), GIT_CONFIG_NOSYSTEM: "1", ...options.env }, input: options.stdin, encoding: "utf8", stdio: "pipe" }), stderr: "" }; }
    catch (e) { const error = e as { status: number; stdout: string; stderr: string }; return { status: error.status, stdout: error.stdout, stderr: error.stderr }; }
  },
  exists: async (path: string) => existsSync(path),
  remove: async (path: string) => rmSync(path, { recursive: true, force: true }),
  writeText: async (path: string, text: string) => { mkdirSync(dirname(path), { recursive: true }); writeFileSync(path, text); },
} }));
import { RepoStore } from "@/entities/repo";
const { git } = await import("@/shared/platform/git");
let repo = "";
let store: RepoStore;
const g = async (...args: string[]) => (await git(args, repo)).stdout.trim();
async function commit(message: string, value: string, path = "f.txt") { writeFileSync(join(repo, path), value); await g("add", "--", path); await g("commit", "-qm", message); return g("rev-parse", "HEAD"); }
async function graph() {
  const commits = parseLog((await git(["log", "--all", "--date-order", `--format=${logFormat}`], repo)).stdout);
  const layout = layoutGraph(commits); store.entries = commits.map((c, i) => ({ commit: c, row: layout.rows[i] }));
  store.headHash = await g("rev-parse", "HEAD"); store.headBranch = await g("branch", "--show-current");
}
beforeEach(async () => {
  fixture = mkdtempSync(join(tmpdir(), "gitrochi-history-")); writeFileSync(join(fixture, "empty-config"), ""); repo = join(fixture, "repo");
  await git(["init", "-q", "repo"], fixture); await g("config", "user.name", "Fixture"); await g("config", "user.email", "fixture@example.com");
  store = new RepoStore(); store.path = repo; store.gitDir = join(repo, ".git"); vi.spyOn(store, "reload").mockResolvedValue(undefined);
});
afterEach(() => { vi.restoreAllMocks(); rmSync(fixture, { recursive: true, force: true }); });
describe("history tools with actual Git", () => {
  it("compares divergent branches directly or from a common ancestor with frozen refs", async () => {
    const base = await commit("Base", "base\n"); const branch = await g("branch", "--show-current");
    await g("switch", "-qc", "topic"); const topic = await commit("Topic", "topic\n");
    await g("switch", branch); const main = await commit("Main", "main\n", "main.txt");
    store.openRevisionComparison(branch, "topic"); await store.loadRevisionComparison();
    expect(store.historyTools.comparison?.files.map((f) => f.path).sort()).toEqual(["f.txt", "main.txt"]);
    expect(store.historyTools.comparison?.left).toBe(main); expect(store.historyTools.comparison?.right).toBe(topic);
    await g("branch", "-f", "topic", base);
    await store.selectComparisonFile(store.historyTools.comparison!.files.find((f) => f.path === "f.txt")!);
    expect(store.historyTools.comparisonPatch).toContain("+topic");
    await g("branch", "-f", "topic", topic);
    store.historyTools.useMergeBase = true; await store.loadRevisionComparison();
    expect(store.historyTools.comparison?.base).toBe(base);
    expect(store.historyTools.comparison?.files.map((f) => f.path)).toEqual(["f.txt"]);
  });
  it("traces changed lines and function history from a committed snapshot", async () => {
    await commit("Create function", "function example() {\n  return 1;\n}\n", "a.js");
    const head = await commit("Change function", "function example() {\n  return 2;\n}\n", "a.js");
    store.openLineHistory("a.js", head, 2, 2); await store.loadLineHistory();
    expect(store.historyTools.lineError).toBeNull(); expect(store.historyTools.lineEntries).toHaveLength(2);
    expect(store.historyTools.lineEntries[0].patch).toContain("+  return 2;");
    store.historyTools.functionName = "example"; await store.loadLineHistory();
    expect(store.historyTools.lineError).toBeNull(); expect(store.historyTools.lineEntries).toHaveLength(2);
  });
  it("applies ordered cherry-picks and stores an undo point", async () => {
    const base = await commit("Base", "base\n"); await g("switch", "-qc", "source");
    const a = await commit("First", "first\n", "a.txt"), b = await commit("Second", "second\n", "b.txt");
    await g("switch", "-qc", "target", base); await graph(); store.historyTools.selected = [b, a];
    await store.openBatchCommits(); expect(store.historyTools.batch.map((item) => item.sha)).toEqual([a, b]);
    await store.executeBatchCommits();
    expect(await g("log", "-2", "--format=%s")).toBe("Second\nFirst"); expect(store.undoStack).toHaveLength(1);
    expect(await g("for-each-ref", "--format=%(objectname)", "refs/gitrochi/batch")).toBe(base);
  });
  it("rejects a changed HEAD and dirty files after review", async () => {
    await commit("Base", "base\n"); const a = await commit("Change", "change\n"); await graph(); store.historyTools.selected = [a];
    await store.openBatchCommits("revert"); await g("commit", "--allow-empty", "-qm", "External"); await store.executeBatchCommits();
    expect(store.historyTools.batchError).toContain("repository changed"); expect(await g("log", "-1", "--format=%s")).toBe("External");
    await graph(); store.historyTools.selected = [a]; await store.openBatchCommits("revert"); writeFileSync(join(repo, "dirty.txt"), "keep"); await store.executeBatchCommits();
    expect(store.historyTools.batchError).toContain("Commit or stash");
    rmSync(join(repo, "dirty.txt"));
    await store.openBatchCommits("revert"); mkdirSync(join(repo, ".git", "sequencer")); await store.executeBatchCommits();
    expect(store.historyTools.batchError).toContain("Commit or stash");
  });
  it("builds adjacent squash plans and executes them with hooks enabled", async () => {
    await commit("Base", "base\n"); const a = await commit("First", "first\n", "a.txt"), b = await commit("Second", "second\n", "b.txt"); await graph();
    store.historyTools.selected = [b, a]; await store.openBatchCommits("squash"); await store.executeBatchCommits();
    expect(store.sheet?.kind).toBe("interactiveRebase"); expect(store.rebasePlan?.items.map((item) => item.action)).toEqual(["squash", "pick"]);
    await store.runInteractiveRebase(store.rebasePlan!);
    expect(await g("rev-list", "--count", "HEAD")).toBe("2"); expect(await g("log", "-1", "--format=%B")).toContain("Second");
  });
  it("keeps commit-message hooks active and leaves failed cleanup resumable", async () => {
    await commit("Base", "base\n"); const a = await commit("Change", "changed\n"); await graph();
    await store.startInteractiveRebase(a);
    const plan = store.rebasePlan!; plan.items[0].action = "reword"; plan.items[0].newMessage = "Reworded";
    const hook = join(repo, ".git", "hooks", "commit-msg");
    writeFileSync(hook, "#!/bin/sh\nexit 1\n"); chmodSync(hook, 0o755);
    await store.runInteractiveRebase(plan);
    expect(await g("log", "-1", "--format=%s")).toBe("Change");
    expect(existsSync(join(repo, ".git", "rebase-merge"))).toBe(true);
    expect(store.errorMessage).toBeTruthy();
  });
  it("rejects nonadjacent squash and retains intervening commits in drop plans", async () => {
    await commit("Base", "base\n"); const a = await commit("First", "first\n", "a.txt"); await commit("Keep", "keep\n", "keep.txt"); const c = await commit("Last", "last\n", "c.txt"); await graph();
    store.historyTools.selected = [c, a]; await store.openBatchCommits("squash"); await store.executeBatchCommits();
    expect(store.historyTools.batchError).toContain("adjacent commits");
    await store.openBatchCommits("drop"); await store.executeBatchCommits(); expect(store.rebasePlan?.items.map((item) => item.action)).toEqual(["drop", "pick", "drop"]);
    await store.runInteractiveRebase(store.rebasePlan!); expect(await g("log", "--format=%s")).toBe("Keep\nBase");
  });
});
