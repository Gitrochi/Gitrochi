import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
vi.hoisted(() => vi.stubGlobal("matchMedia", () => ({ matches: false, addEventListener() {} })));
vi.mock("@/entities/terminal", () => ({ TerminalSession: class {} }));
import { ai, changeQuestionContext, changeQuestionLimits, changeQuestionPrompt, createChangeQuestionSnapshot } from "@/entities/ai";
import { gitch, type GraphReview } from "@/entities/gitch";
import { parseDiff } from "@/entities/git";
import { RepoStore } from "@/entities/repo";
import { ipc } from "@/shared/api";
import * as platform from "@/shared/platform";

const patch = "diff --git a/a.ts b/a.ts\n--- a/a.ts\n+++ b/a.ts\n@@ -1 +1 @@\n-before\n+after\n";
function selected(staged = false) {
  const store = new RepoStore();
  store.path = "C:/one";
  store.headHash = "head-a";
  store.diffSource = { kind: "working", change: { path: "a.ts", oldPath: null, staged, kind: "modified" } };
  store.diff = parseDiff(patch);
  return store;
}
beforeEach(() => {
  vi.spyOn(platform, "git").mockResolvedValue({ status: 0, stdout: "head-a\n", stderr: "" });
  vi.spyOn(ai, "problem").mockReturnValue(null);
  vi.spyOn(ai, "providerFor").mockReturnValue("compatible");
});
afterEach(() => vi.restoreAllMocks());

describe("AI change snapshot and conversation", () => {
  it("opens a local preview without an AI request and freezes staged/unstaged scope", async () => {
    const write = vi.spyOn(ai, "complete").mockResolvedValue("answer");
    const store = selected(true);
    await store.openChangeQuestion();
    expect(write).not.toHaveBeenCalled();
    const snapshot = store.changeQuestionSession!.snapshot!;
    expect(snapshot.scope).toMatch(/Staged/);
    expect(snapshot.path).toBe("a.ts");
    expect(snapshot.diff).toContain("+after");
    store.diff = parseDiff(patch.replace("after", "different"));
    store.diffSource = null;
    store.setChangeQuestion("Which tests?");
    await store.sendChangeQuestion();
    expect(write.mock.calls[0][1]).toContain("+after");
    expect(write.mock.calls[0][1]).not.toContain("different");
    expect(store.changeQuestionSession!.messages).toHaveLength(2);
    expect(store.changeQuestionSession!.question).toBe("");
  });

  it("includes only picked lines and labels the missing context", async () => {
    const store = selected();
    const added = store.diff!.lines.findIndex((l) => l.kind === "added");
    store.diffSelection = new Set([added]);
    await store.openChangeQuestion();
    const snapshot = store.changeQuestionSession!.snapshot!;
    expect(snapshot.scope).toMatch(/Selected lines/);
    expect(snapshot.diff).toContain("new:1 +after");
    expect(snapshot.diff).not.toContain("before");
    expect(snapshot.limitations.join()).toContain("surrounding code");
  });

  it("does not reread untracked paths and clearly rejects binary data", async () => {
    const store = selected();
    store.diffSource = { kind: "working", change: { path: "link.ts", oldPath: null, staged: false, kind: "untracked" } };
    const read = vi.spyOn(ipc, "readHead");
    await store.openChangeQuestion();
    expect(read).not.toHaveBeenCalled();
    expect(store.changeQuestionSession!.snapshot!.scope).toMatch(/Untracked/);
    store.diff!.isBinary = true;
    await store.openChangeQuestion(true);
    expect(store.changeQuestionSession!.snapshot).toBeNull();
    expect(store.changeQuestionSession!.error).toMatch(/binary/);
  });

  it("blocks repeated sends and ignores a late answer after stop/close/new repository", async () => {
    const store = selected();
    await store.openChangeQuestion();
    store.setChangeQuestion("risks?");
    let finish!: (s: string) => void;
    const write = vi.spyOn(ai, "complete").mockImplementation(() => new Promise((resolve) => { finish = resolve; }));
    const sending = store.sendChangeQuestion();
    await store.sendChangeQuestion();
    expect(write).toHaveBeenCalledTimes(1);
    store.cancelChangeQuestion();
    store.path = "C:/two";
    finish("old answer");
    await sending;
    expect(store.changeQuestionSession!.messages).toEqual([]);
    expect(store.changeQuestionSession!.working).toBe(false);
    expect(store.changeQuestionSession!.question).toBe("risks?");
  });

  it("keeps the question and previous transcript after errors; followups use the same snapshot", async () => {
    const store = selected();
    await store.openChangeQuestion();
    const write = vi.spyOn(ai, "complete").mockResolvedValueOnce("first answer").mockRejectedValueOnce(new Error("offline"));
    store.setChangeQuestion("first question");
    await store.sendChangeQuestion();
    store.setChangeQuestion("followup");
    await store.sendChangeQuestion();
    expect(store.changeQuestionSession!.messages).toHaveLength(2);
    expect(store.changeQuestionSession!.error).toBe("offline");
    expect(store.changeQuestionSession!.question).toBe("followup");
    expect(write.mock.calls[1][1]).toContain("first answer");
    expect(write.mock.calls[1][1]).toContain("first question");
    expect(write.mock.calls[1][1]).toContain("+after");
  });

  it("bounds context, questions, answers and conversation sent to the provider", async () => {
    const snapshot = createChangeQuestionSnapshot({ repository: "repo", head: "h", scope: "staged", path: null, diff: "x".repeat(changeQuestionLimits.diff + 500) });
    expect(snapshot.diff.length).toBe(changeQuestionLimits.diff);
    expect(snapshot.omitted).toBe(500);
    expect(changeQuestionContext(snapshot)).toContain("500 characters omitted");
    const prompt = changeQuestionPrompt(snapshot, "question", Array.from({ length: 20 }, () => ({ role: "assistant" as const, text: "h".repeat(20_000) })));
    expect(prompt.length).toBeLessThan(170_000);
    const store = selected();
    await store.openChangeQuestion();
    const write = vi.spyOn(ai, "complete").mockResolvedValue("a".repeat(changeQuestionLimits.answer + 500));
    store.setChangeQuestion("q".repeat(changeQuestionLimits.question + 1));
    await store.sendChangeQuestion();
    expect(write).not.toHaveBeenCalled();
    store.setChangeQuestion("question");
    await store.sendChangeQuestion();
    expect(store.changeQuestionSession!.messages[1].text.length).toBe(changeQuestionLimits.answer);
  });

  it("uses selected PR patch rather than local staged changes", async () => {
    const store = selected();
    store.diffSource = { kind: "review", number: 8, change: { path: "a.ts", oldPath: null, staged: false, kind: "modified" }, patch };
    await store.openChangeQuestion();
    expect(store.changeQuestionSession!.snapshot!.scope).toBe("PR/MR #8");
    expect(vi.mocked(platform.git)).toHaveBeenCalledTimes(1);
  });

  it("blocks a send when the model or endpoint no longer matches the provider preview", async () => {
    const store = selected();
    await store.openChangeQuestion();
    const write = vi.spyOn(ai, "complete").mockResolvedValue("answer");
    store.setChangeQuestion("risks?");
    const previous = ai.baseURL;
    ai.baseURL = "https://changed.example/v1";
    await store.sendChangeQuestion();
    expect(write).not.toHaveBeenCalled();
    expect(store.changeQuestionSession!.error).toMatch(/settings changed/);
    expect(store.changeQuestionSession!.question).toBe("risks?");
    ai.baseURL = previous;
  });

  it("only adds staged impact and unrun test estimates when the same stamp brackets the diff", async () => {
    const store = selected();
    store.diffSource = null;
    store.selection = { kind: "wip" };
    vi.mocked(platform.git).mockImplementation(async (args) => ({ status: 0, stdout: args[0] === "rev-parse" ? "head-a" : patch, stderr: "" }));
    const report: GraphReview = { schemaVersion: 1, tool: "gitch graph review", scope: "staged", stamp: "stamp", snapshot: "tree", headSha: "head-a", branch: "feature", stale: false,
      changed: [{ path: "a.ts", status: "M", analyzed: true }], direct: [], indirect: [], tests: [{ path: "a.test.ts", kind: "name", depth: 0, heuristic: true }], coverage: { changed: 1, analyzed: 1, unsupported: 0 }, limitations: [] };
    store.commitImpact = { kind: "done", result: report, revision: 0 };
    vi.spyOn(gitch, "commitReviewStamp").mockResolvedValue("stamp");
    await store.openChangeQuestion();
    expect(store.changeQuestionSession!.snapshot!.impact).toContain("a.test.ts");
    expect(changeQuestionContext(store.changeQuestionSession!.snapshot!)).toContain("tests were NOT run");
    vi.mocked(gitch.commitReviewStamp).mockResolvedValueOnce("stamp").mockResolvedValueOnce("changed");
    await store.openChangeQuestion(true);
    expect(store.changeQuestionSession!.snapshot!.impact).toBeNull();
  });
});
