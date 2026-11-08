import { describe, expect, it } from "vitest";
import { assignedIssueCount, type AssignedIssue, issueNext, issueNumbers, issueProgress, issueSummary, issueSummaryCounts, issueSummaryLines, issueSummaryTotal } from "@/entities/hosting/model/issue-page";
import { listDay, listWhen } from "@/shared/lib/list-date";

describe("Issues page", () => {
  const assigned: AssignedIssue[] = [{ number: 42, progress: "inReview", branch: "feature/search" }, { number: 41, progress: "notStarted" }, { number: 37, progress: "notStarted" }];

  it("puts an issue in review once a linked branch has a request, in progress once it has a branch", () => {
    expect(issueProgress([], new Set(["a"]))).toBe("notStarted");
    expect(issueProgress(["b"], new Set(["a"]))).toBe("inProgress");
    expect(issueProgress(["b", "a"], new Set(["a"]))).toBe("inReview");
  });

  it("names the groups that have issues, the furthest along first", () => {
    const summary = issueSummary(assigned);
    expect(issueSummaryLines(summary)).toEqual(["#42 in review", "#41 and #37 not started"]);
    expect(issueSummaryCounts(summary)).toBe("1 in review, 2 not started");
    expect(issueSummaryTotal(summary)).toBe(3);
    expect(issueSummaryLines(issueSummary([]))).toEqual([]);
  });

  it("writes one or two numbers and counts three or more", () => {
    expect(issueNumbers([7])).toBe("#7");
    expect(issueNumbers([1, 2, 3])).toBe("3 issues");
  });

  it("offers the one next step: a request for the issue this branch works on, else a branch for the first one nobody started", () => {
    expect(issueNext(assigned, "feature/search")).toEqual({ kind: "createBranch", number: 41 });
    expect(issueNext([{ number: 62, progress: "inProgress", branch: "feature/export" }, { number: 63, progress: "notStarted" }], "feature/export")).toEqual({ kind: "createRequest", number: 62, branch: "feature/export" });
    expect(issueNext([{ number: 61, progress: "inReview" }], null)).toBeNull();
  });

  it("counts what is assigned on its segment, and nothing when nothing is", () => {
    expect(assignedIssueCount(0, false)).toBeNull();
    expect(assignedIssueCount(3, false)).toBe("3");
    expect(assignedIssueCount(30, true)).toBe("30+");
  });
});

describe("list dates", () => {
  const at = (year: number, month: number, day: number, hour = 0, minute = 0, second = 0) => new Date(year, month - 1, day, hour, minute, second).getTime() / 1000;
  const now = at(2026, 11, 5, 9);

  it("says how long ago within 24 hours", () => {
    expect(listWhen(at(2026, 11, 5, 8, 59, 30), now, "en")).toBe("Just now");
    expect(listWhen(at(2026, 11, 5, 8, 48), now, "en")).toBe("12m ago");
    expect(listWhen(at(2026, 11, 5, 7), now, "en")).toBe("2h ago");
    expect(listWhen(at(2026, 11, 4, 10), now, "en")).toBe("23h ago");
  });

  it("then says yesterday, then the day, with the year only for another year", () => {
    expect(listWhen(at(2026, 11, 4, 8), now, "en")).toBe("Yesterday");
    expect(listWhen(at(2026, 11, 3, 20), now, "en")).toBe("Nov 3");
    expect(listWhen(at(2025, 12, 30), now, "en")).toBe("Dec 30, 2025");
    expect(listDay(at(2026, 10, 28), now, "en")).toBe("Oct 28");
  });
});
