import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
vi.hoisted(() => vi.stubGlobal("matchMedia", () => ({ matches: false, addEventListener() {} })));
vi.mock("@/entities/terminal", () => ({ TerminalSession: class {} }));
import { RepoStore } from "@/entities/repo";
import { accounts } from "@/entities/hosting";
import { gitch } from "@/entities/gitch";
import * as platform from "@/shared/platform";

const sha = "a".repeat(40), old = "b".repeat(40);
let source = sha, url = "ssh://git@example.com/demo/repo.git", config = "";
let preflight: "OK" | "STOP" = "OK";
const makeStore = () => { const store = new RepoStore(); store.path = "/demo/repo"; store.headBranch = "topic"; store.headHash = sha; return store; };

beforeEach(() => {
  source = sha; url = "ssh://git@example.com/demo/repo.git"; preflight = "OK";
  config = "user.name\nDemo\0user.email\ndev@example.com\0branch.topic.remote\norigin\0branch.topic.merge\nrefs/heads/topic\0";
  vi.spyOn(accounts, "gitEnvironment").mockResolvedValue({});
  vi.spyOn(gitch, "status").mockResolvedValue({ inRepo: true, lockedAccount: "demo", account: "demo", accountSource: "lock", pushAccount: "demo", ignored: false });
  vi.spyOn(gitch, "preflight").mockImplementation(async () => ({ result: preflight, checks: preflight === "STOP" ? [{ level: "STOP", code: "blocked", message: "Blocked by policy" }] : [] }));
  vi.spyOn(platform, "git").mockImplementation(async (args) => {
    const stdout = args[0] === "config" ? config : args[0] === "remote" && args[1] === "get-url" ? url + "\n" : args[0] === "remote" ? "origin\n" : args[0] === "rev-parse" ? source + "\n" : args[0] === "symbolic-ref" ? "topic\n" : args[0] === "ls-remote" ? `${old}\trefs/heads/topic\n` : args[0] === "log" ? `${source}\x1fDemo\x1fdev@example.com\x1fAdd feature\n` : args[0] === "rev-list" ? "1\n" : args[0] === "diff" ? "src/demo.ts\0" : "";
    return { status: 0, stdout, stderr: "" };
  });
});
afterEach(() => vi.restoreAllMocks());

describe("push review lifecycle", () => {
  it("does not execute a push before confirmation and cancellation resumes caller as false", async () => {
    const store = makeStore();
    const run = vi.spyOn(store, "run").mockResolvedValue(true);
    const result = store.push();
    expect(store.sheet?.kind).toBe("pushReview");
    await store.loadPushReview("topic");
    expect(store.pushReview?.commits[0].subject).toBe("Add feature");
    expect(run).not.toHaveBeenCalled();
    store.cancelPushReview();
    expect(await result).toBe(false);
  });
  it.each(["source", "URL", "config", "account"])("requires another review when %s changes", async (change) => {
    const store = makeStore();
    const run = vi.spyOn(store, "run").mockResolvedValue(true);
    const result = store.push();
    await store.loadPushReview("topic");
    if (change === "source") source = "c".repeat(40);
    if (change === "URL") url = "ssh://git@example.com/demo/other.git";
    if (change === "config") config += "branch.topic.pushremote\norigin\0";
    if (change === "account") vi.mocked(gitch.status).mockResolvedValue({ inRepo: true, lockedAccount: "other", account: "other", accountSource: "lock", pushAccount: "other", ignored: false });
    expect(await store.confirmPushReview()).toBe(false);
    expect(store.pushReviewError).toContain("changed");
    expect(run).not.toHaveBeenCalled();
    store.cancelPushReview();
    expect(await result).toBe(false);
  });
  it("rechecks preflight and blocks a newly reported STOP", async () => {
    const store = makeStore();
    const run = vi.spyOn(store, "run").mockResolvedValue(true);
    const result = store.push();
    await store.loadPushReview("topic");
    preflight = "STOP";
    expect(await store.confirmPushReview()).toBe(false);
    expect(store.pushReview?.preflight.result).toBe("STOP");
    expect(run).not.toHaveBeenCalled();
    store.cancelPushReview();
    await result;
  });
  it("uses a fresh explicit force lease after confirmation and resumes the caller", async () => {
    const store = makeStore();
    const run = vi.spyOn(store, "run").mockResolvedValue(true);
    vi.spyOn(store, "loadPullRequests").mockResolvedValue();
    vi.spyOn(store.ci, "refreshBadges").mockResolvedValue();
    const result = store.push(true);
    await store.loadPushReview("topic", true);
    expect(await store.confirmPushReview()).toBe(true);
    expect(await result).toBe(true);
    expect(run.mock.calls[0][1]).toContain(`--force-with-lease=refs/heads/topic:${old}`);
    expect(run.mock.calls[0][1].at(-1)).toBe(`${sha}:refs/heads/topic`);
    expect(vi.mocked(gitch.preflight)).toHaveBeenCalledTimes(2);
  });
  it("reads the actual push URL even when the fetch remote differs", async () => {
    const store = makeStore();
    const result = store.push();
    await store.loadPushReview("topic");
    expect(vi.mocked(platform.git).mock.calls.find(([args]) => args[0] === "ls-remote")?.[0]).toEqual(["ls-remote", "--refs", "--", url, "refs/heads/topic"]);
    store.cancelPushReview();
    await result;
  });
  it("blocks multiple push URLs instead of omitting one from the review", async () => {
    const store = makeStore();
    url += "\nssh://git@example.com/demo/other.git";
    const result = store.push();
    await store.loadPushReview("topic");
    expect(store.pushReview).toBeNull();
    expect(store.pushReviewError).toContain("Multiple push URLs");
    store.cancelPushReview();
    await result;
  });
  it("excludes existing remote history when publishing a new branch and compares from its merge base", async () => {
    const store = makeStore();
    const original = vi.mocked(platform.git).getMockImplementation()!;
    vi.mocked(platform.git).mockImplementation(async (args, cwd, options) => {
      if (args[0] === "ls-remote") return { status: 0, stdout: args.includes("--symref") ? `ref: refs/heads/main\tHEAD\n${old}\tHEAD\n${old}\trefs/heads/main\n` : "", stderr: "" };
      if (args[0] === "cat-file") return { status: 0, stdout: `${old} commit 100\n`, stderr: "" };
      if (args[0] === "merge-base") return { status: 0, stdout: old + "\n", stderr: "" };
      return original(args, cwd, options);
    });
    const result = store.push();
    await store.loadPushReview("topic");
    expect(store.pushReview?.fileScope).toBe("changes");
    expect(store.pushReview?.comparisonBase).toBe(old);
    const calls = vi.mocked(platform.git).mock.calls.map(([args]) => args);
    expect(calls.find((args) => args[0] === "log")).toContain("--not");
    expect(calls.find((args) => args[0] === "log")).toContain(old);
    expect(calls.find((args) => args[0] === "diff")).toEqual(["diff", "--name-only", "-z", old, sha, "--"]);
    store.cancelPushReview(); await result;
  });

  it("labels an empty remote's complete file snapshot honestly", async () => {
    const store = makeStore();
    const original = vi.mocked(platform.git).getMockImplementation()!;
    vi.mocked(platform.git).mockImplementation(async (args, cwd, options) => args[0] === "ls-remote" ? { status: 0, stdout: "", stderr: "" } : original(args, cwd, options));
    const result = store.push();
    await store.loadPushReview("topic");
    expect(store.pushReview?.fileScope).toBe("snapshot");
    expect(store.pushReview?.comparisonBase).toBeNull();
    expect(vi.mocked(platform.git).mock.calls.some(([args]) => args[0] === "ls-tree")).toBe(true);
    store.cancelPushReview(); await result;
  });

  it("does not redirect an operation after repository switch during its initial snapshot", async () => {
    const store = makeStore();
    let finish!: (value: null) => void;
    vi.spyOn(store as unknown as { refSnapshot(): Promise<null> }, "refSnapshot").mockImplementation(() => new Promise((resolve) => { finish = resolve; }));
    const operation = store.run("Pushing…", ["push", "origin", "topic"]);
    store.cancelPushReview(); store.path = "/demo/other"; store.busy = "Another operation";
    finish(null);
    expect(await operation).toBe(false);
    expect(vi.mocked(platform.git).mock.calls.some(([args]) => args[0] === "push")).toBe(false);
    expect(store.busy).toBe("Another operation");
  });

  it("does not clear a new repository's sheet after an old push finishes", async () => {
    const store = makeStore();
    let finish!: (value: boolean) => void;
    const run = vi.spyOn(store, "run").mockImplementation(() => new Promise((resolve) => { finish = resolve; }));
    const result = store.push();
    await store.loadPushReview("topic");
    const confirmed = store.confirmPushReview();
    await vi.waitFor(() => expect(run).toHaveBeenCalled());
    store.cancelPushReview(); store.path = "/demo/other";
    const newSheet = { kind: "newBranch" as const, start: "HEAD", label: "main" }; store.sheet = newSheet;
    finish(true);
    expect(await confirmed).toBe(false);
    expect(await result).toBe(false);
    expect(store.sheet).toBe(newSheet);
    expect(vi.mocked(platform.git).mock.calls.some(([args]) => args[0] === "config" && args[1].startsWith("branch.") && args.length === 3)).toBe(false);
  });

  it("redacts credentials reported by gitch preflight", async () => {
    const store = makeStore();
    vi.mocked(gitch.preflight).mockResolvedValue({ result: "STOP", checks: [{ level: "STOP", code: "url", message: "Blocked https://name:secret@example.com/demo?private_token=abc" }] });
    const result = store.push(); await store.loadPushReview("topic");
    expect(store.pushReview?.preflight.checks[0].message).toBe("Blocked https://[redacted]@example.com/demo?private_token=[redacted]");
    store.cancelPushReview(); await result;
  });

});
