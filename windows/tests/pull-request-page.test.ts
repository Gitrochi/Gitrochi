import { describe, expect, it } from "vitest";
import type { PullRequest } from "@/entities/git";
import type { PullRequestReview, ReviewComment } from "@/entities/hosting";
import {
  branchLabel, checkGroups, checkJob, checksBadge, commentCount, branchSummary, mergeReason, requestSummaryCard, requestToOpen, folderLabel, headerInOneRow, isCompact, isThisBranch, linkedIssues,
  reviewRequestedCount, sorted, splitAllowed, threadCount, treeWidth, viewedKey, withViewed,
} from "@/widgets/inspector/lib/pull-request-page";

const request = (number: number, extra: Partial<PullRequest> = {}): PullRequest =>
  ({ number, title: `Request ${number}`, author: "demo", source: "topic", target: "main", url: "", isDraft: false, updated: null, body: "", headSHA: "a", fromFork: false, ...extra });
const comment = (id: string, extra: Partial<ReviewComment> = {}): ReviewComment => ({ id, author: "demo", body: "", date: null, kind: "comment", ...extra });

describe("Pull requests page", () => {
  it("draws Changed files compact with the list shown, or in a narrow detail column", () => {
    expect(isCompact(true, 1400)).toBe(true);
    expect(isCompact(false, 916)).toBe(true);
    expect(isCompact(false, 917)).toBe(false);
    expect(treeWidth(true)).toBe(280);
    expect(treeWidth(false)).toBe(340);
  });

  it("folds the header into one row only on the page's Changed files tab, with room for it", () => {
    expect(headerInOneRow(true, "files", 916)).toBe(true);
    expect(headerInOneRow(true, "files", 719)).toBe(false);
    expect(headerInOneRow(true, "conversation", 1200)).toBe(false);
    expect(headerInOneRow(false, "files", 1200)).toBe(false);
    expect(mergeReason(false, "main", null, 1, [])).toBeNull();
    expect(mergeReason(true, "main", { kind: "failed", count: 1 }, 1, ["raw"])).toContain("main");
    expect(mergeReason(false, "main", null, null, ["raw"])).toBe("raw");
    const open = [{ number: 2, source: "a", fromFork: false }, { number: 3, source: "b", fromFork: false }] as never[];
    expect([requestToOpen(open, "b"), requestToOpen(open, "c"), requestToOpen([], "b")]).toEqual([3, 2, null]);
    expect(branchSummary(false, 3, 2, 3)).toEqual({ kind: "noRequest", commits: 3 });
    expect(branchSummary(true, 2, 5, 6)).toEqual({ kind: "notPushed", onServer: 4, local: 2 });
    expect(branchSummary(true, 0, 5, 3)).toEqual({ kind: "moved", incoming: 5, commits: 3 });
    expect(branchSummary(true, 0, 0, 3)).toEqual({ kind: "upToDate", commits: 3 });
  });

  it("gives the summary card a state from the first frame and never guesses about a request", () => {
    const counts = { incoming: 0, commits: 3 };
    // the list is not read yet: loading, whatever the local counts say
    expect(requestSummaryCard("pending", "topic", "main", false, 0, counts)).toEqual({ kind: "loading" });
    expect(requestSummaryCard("pending", "main", "main", false, 0, "unavailable")).toEqual({ kind: "loading" });
    // what needs no list is said at once
    expect(requestSummaryCard("noAccount", "topic", "main", false, 0, "pending")).toEqual({ kind: "noAccount" });
    expect(requestSummaryCard("noAccount", null, null, false, 0, "pending")).toEqual({ kind: "noAccount" });
    expect(requestSummaryCard("pending", null, "main", false, 0, "pending")).toEqual({ kind: "detached" });
    expect(requestSummaryCard("failed", "topic", "main", false, 0, counts)).toEqual({ kind: "failed" });
    // the list is read
    expect(requestSummaryCard("read", "main", "main", false, 0, "unavailable")).toEqual({ kind: "base" });
    expect(requestSummaryCard("read", "topic", "main", false, 0, "pending")).toEqual({ kind: "loading" });
    expect(requestSummaryCard("read", "topic", null, false, 0, "unavailable")).toEqual({ kind: "uncounted", hasRequest: false });
    expect(requestSummaryCard("read", "topic", "main", true, 0, "unavailable")).toEqual({ kind: "uncounted", hasRequest: true });
    expect(requestSummaryCard("read", "topic", "main", false, 0, counts)).toEqual({ kind: "branch", state: { kind: "noRequest", commits: 3 } });
    expect(requestSummaryCard("read", "topic", "main", true, 2, { incoming: 1, commits: 5 })).toEqual({ kind: "branch", state: { kind: "notPushed", onServer: 3, local: 2 } });
  });

  it("allows Split only from a 1000 px diff", () => {
    expect(splitAllowed(999)).toBe(false);
    expect(splitAllowed(1000)).toBe(true);
  });

  it("sorts the loaded requests without touching the loaded order", () => {
    const list = [request(5, { comments: 1 }), request(9), request(7, { comments: 4 }), request(3, { comments: 1 })];
    expect(sorted(list, "updated")).toBe(list);
    expect(sorted(list, "newest").map((item) => item.number)).toEqual([9, 7, 5, 3]);
    // unknown counts go last and equal counts keep the loaded order
    expect(sorted(list, "comments").map((item) => item.number)).toEqual([7, 5, 3, 9]);
    expect(list.map((item) => item.number)).toEqual([5, 9, 7, 3]);
  });

  it("counts review requests and reads a row's comment count", () => {
    expect(reviewRequestedCount([request(1, { reviewRequested: true }), request(2), request(3, { reviewRequested: true })])).toBe(2);
    const review = { number: 2, comments: [comment("a"), comment("b", { kind: "system" }), comment("c", { kind: "approved" })] } as PullRequestReview;
    expect(commentCount(request(1, { comments: 6 }), review)).toBe(6);
    expect(commentCount(request(2), review)).toBe(2);
    expect(commentCount(request(3), review)).toBeNull();
    expect(commentCount(request(3), null)).toBeNull();
  });

  it("names the checked-out branch instead of repeating it", () => {
    expect(isThisBranch(request(1), "topic")).toBe(true);
    expect(isThisBranch(request(1, { fromFork: true }), "topic")).toBe(false);
    expect(branchLabel(request(1), "topic")).toBe("This branch → main");
    expect(branchLabel(request(1, { source: "fix/terminal-focus" }), "topic")).toBe("fix/terminal-focus → main");
    expect(branchLabel(request(1, { fromFork: true }), "topic")).toBe("topic → main (fork)");
    expect(branchLabel(request(1), null)).toBe("topic → main");
  });

  it("shortens a folder from the start by whole segments", () => {
    expect(folderLabel("README.md")).toBe("");
    expect(folderLabel("docs/search.md")).toBe("docs");
    expect(folderLabel("windows/tests/search.test.ts")).toBe("windows/tests");
    expect(folderLabel("macos/Sources/Views/Search/SearchPanel.swift")).toBe("…/Views/Search");
  });

  it("groups checks and counts only what needs attention on the tab", () => {
    const checks = [{ id: 1, status: "success" as const }, { id: 2, status: "failed" as const }, { id: 3, status: "running" as const }, { id: 4, status: "skipped" as const }, { id: 5, status: "pending" as const }, { id: 6, status: "neutral" as const }];
    const groups = checkGroups(checks);
    expect(groups.failed.map((check) => check.id)).toEqual([2]);
    expect(groups.running.map((check) => check.id)).toEqual([3, 5]);
    expect(groups.passed.map((check) => check.id)).toEqual([1, 4, 6]);
    expect(checksBadge(checks)).toEqual({ kind: "failed", count: 1 });
    expect(checksBadge(checks.filter((check) => check.status !== "failed"))).toEqual({ kind: "running", count: 2 });
    expect(checksBadge(groups.passed)).toBeNull();
    expect(checksBadge([])).toBeNull();
  });

  it("finds the issues a description closes", () => {
    expect(linkedIssues("Keeps the query.\n\nCloses #42, fixes #7 and resolved #42. See #9.")).toEqual([42, 7]);
    expect(linkedIssues("Fix: #3")).toEqual([3]);
    expect(linkedIssues("Prefixes #5 are not keywords")).toEqual([]);
  });

  it("counts the threads on a file", () => {
    const comments = [comment("a", { path: "a.ts", threadID: "t1" }), comment("b", { path: "a.ts", threadID: "t1" }), comment("c", { path: "a.ts", threadID: "t2" }), comment("d", { path: "b.ts", threadID: "t3" }), comment("e", { path: "a.ts", kind: "system" })];
    expect(threadCount(comments, "a.ts")).toBe(2);
    expect(threadCount(comments, "b.ts")).toBe(1);
    expect(threadCount(comments, "c.ts")).toBe(0);
  });

  it("keeps Viewed marks per request version", () => {
    const key = viewedKey("github:example.com/demo/app", 58, "abc");
    expect(key).toBe("github:example.com/demo/app#58@abc");
    expect(viewedKey("github:example.com/demo/app", 58, "def")).not.toBe(key);
    const marked = withViewed({}, key, "a.ts", true);
    expect(marked).toEqual({ [key]: ["a.ts"] });
    expect(withViewed(marked, key, "a.ts", true)).toEqual({ [key]: ["a.ts"] });
    expect(withViewed(marked, key, "a.ts", false)).toEqual({});
    const many = Object.fromEntries(Array.from({ length: 60 }, (_, index) => [`k${index}`, ["x"]]));
    expect(Object.keys(withViewed(many, key, "a.ts", true))).toHaveLength(40);
    expect(withViewed(many, key, "a.ts", true)[key]).toEqual(["a.ts"]);
  });

  it("reads the job behind a check from its address", () => {
    expect(checkJob("https://github.com/demo/app/actions/runs/316/job/9001")).toEqual({ run: 316, job: 9001 });
    expect(checkJob("https://gitlab.example.com/demo/app/-/jobs/77")).toEqual({ run: null, job: 77 });
    expect(checkJob("https://ci.example.invalid/security")).toBeNull();
    expect(checkJob("")).toBeNull();
  });
});
