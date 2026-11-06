import { describe, expect, it } from "vitest";
import type { AccountWorkItem } from "@/entities/hosting";
import { HostingError } from "@/entities/hosting";
import { inboxReason, inboxReasonLabel, isLocalWork, repositoryName, visibleWork, workGroups, workMatches, workReference, workWhen } from "@/features/account-work/lib/account-inbox";
import { accountWorkFailure } from "@/features/account-work/model/account-work-model";

const item = (id: string, extra: Partial<AccountWorkItem> = {}): AccountWorkItem => ({
  id, title: id, repository: "sample-studio/desktop", host: "github.com", url: "https://github.com/sample-studio/desktop/pull/1", number: 1, state: "", author: "",
  unread: false, origin: "", kind: "request", reason: "", actor: "", updated: null, status: "", body: "", source: "", target: "", ...extra,
});
const at = (year: number, month: number, day: number, hour = 0, minute = 0) => new Date(year, month - 1, day, hour, minute).getTime() / 1000;

describe("Account inbox", () => {
  it("names why a notification is in the inbox, on GitHub and on GitLab", () => {
    expect(["review_requested", "approval_required"].map((reason) => inboxReason({ reason, title: "" }))).toEqual(["review", "review"]);
    expect(["mention", "team_mention", "mentioned", "directly_addressed"].map((reason) => inboxReason({ reason, title: "" }))).toEqual(["mention", "mention", "mention", "mention"]);
    expect(["assign", "assigned"].map((reason) => inboxReason({ reason, title: "" }))).toEqual(["assigned", "assigned"]);
    expect(inboxReason({ reason: "build_failed", title: "" })).toBe("ciFailed");
    // GitHub says only that a run finished; the title says how it ended
    expect(inboxReason({ reason: "ci_activity", title: "CI workflow run failed for main branch" })).toBe("ciFailed");
    expect(inboxReason({ reason: "ci_activity", title: "CI workflow run succeeded" })).toBe("ci");
    expect(["subscribed", "state_change", ""].map((reason) => inboxReason({ reason, title: "" }))).toEqual(["update", "update", "update"]);
    expect(inboxReasonLabel("mention", "Sam")).toBe("Mentioned by Sam");
    expect(inboxReasonLabel("mention")).toBe("Mentioned");
    expect(inboxReasonLabel("review")).toBe("Review requested");
  });

  it("writes a time as minutes or hours within a day, then Yesterday, then the day", () => {
    const now = at(2026, 11, 5, 9);
    expect(workWhen(now - 20, now, "en")).toBe("Just now");
    expect(workWhen(now - 3 * 60, now, "en")).toBe("3m ago");
    expect(workWhen(now - 2 * 3600, now, "en")).toBe("2h ago");
    // 23 hours ago is still hours, although the calendar day is yesterday
    expect(workWhen(at(2026, 11, 4, 10), now, "en")).toBe("23h ago");
    expect(workWhen(at(2026, 11, 4, 8), now, "en")).toBe("Yesterday");
    expect(workWhen(at(2026, 10, 30, 12), now, "en")).toBe("Oct 30");
    expect(workWhen(at(2025, 12, 30, 12), now, "en")).toBe("Dec 30, 2025");
  });

  it("shows the number and the repository's name, or no number for what has none", () => {
    expect(workReference(item("a", { number: 57 }))).toBe("#57");
    expect(workReference(item("a", { number: 0 }))).toBe("");
    expect(repositoryName("sample-studio/desktop")).toBe("desktop");
    expect(repositoryName("group/sub/website")).toBe("website");
  });

  it("searches the title, the repository, the number and the reason", () => {
    const row = item("Terminal loses focus", { number: 41, reason: "mention", actor: "Sam" });
    expect(workMatches(row, " FOCUS ")).toBe(true);
    expect(workMatches(row, "desktop")).toBe(true);
    expect(workMatches(row, "#41")).toBe(true);
    expect(workMatches(row, "mentioned by sam")).toBe(true);
    expect(workMatches(row, "pricing")).toBe(false);
    expect(workMatches(row, "  ")).toBe(true);
  });

  it("filters to unread and sorts by time, keeping the server's order for equal or missing times", () => {
    const rows = [
      item("old", { updated: 100 }), item("new", { updated: 300, unread: true }), item("same-a", { updated: 200, unread: true }),
      item("same-b", { updated: 200 }), item("undated-a"), item("undated-b", { unread: true }),
    ];
    expect(visibleWork(rows, "", false, false).map((row) => row.id)).toEqual(["new", "same-a", "same-b", "old", "undated-a", "undated-b"]);
    expect(visibleWork(rows, "", false, true).map((row) => row.id)).toEqual(["undated-a", "undated-b", "old", "same-a", "same-b", "new"]);
    expect(visibleWork(rows, "", true, false).map((row) => row.id)).toEqual(["new", "same-a", "undated-b"]);
    expect(visibleWork(rows, "same", true, false).map((row) => row.id)).toEqual(["same-a"]);
  });

  it("groups what changed today apart from the earlier rows", () => {
    const now = at(2026, 11, 5, 9);
    const groups = workGroups([item("today", { updated: at(2026, 11, 5, 0, 5) }), item("yesterday", { updated: at(2026, 11, 4, 23, 55) }), item("undated")], now);
    expect(groups.today.map((row) => row.id)).toEqual(["today"]);
    expect(groups.earlier.map((row) => row.id)).toEqual(["yesterday", "undated"]);
  });

  it("opens in the app only a numbered request or issue of the open repository", () => {
    const target = { host: "GitHub.com", path: "Sample-Studio/desktop" };
    expect(isLocalWork(item("a", { number: 57 }), target)).toBe(true);
    expect(isLocalWork(item("a", { number: 57, kind: "issue" }), target)).toBe(true);
    expect(isLocalWork(item("a", { number: 57, kind: "other" }), target)).toBe(false);
    expect(isLocalWork(item("a", { number: 0 }), target)).toBe(false);
    expect(isLocalWork(item("a", { number: 57, repository: "sample-studio/website" }), target)).toBe(false);
    expect(isLocalWork(item("a", { number: 57, host: "gitlab.example.com" }), target)).toBe(false);
    expect(isLocalWork(item("a", { number: 57 }), null)).toBe(false);
  });

  it("tells an expired sign-in from a server's answer and from a request that never arrived", () => {
    expect(accountWorkFailure(new HostingError(401, "{}"))).toEqual({ kind: "expired" });
    expect(accountWorkFailure(new HostingError(403, JSON.stringify({ message: "Forbidden" })))).toMatchObject({ kind: "message" });
    expect(accountWorkFailure(new Error("Invalid notification."))).toEqual({ kind: "message", text: "Invalid notification." });
    // the transport rejects with plain text when there was no answer at all
    expect(accountWorkFailure("error sending request")).toEqual({ kind: "unreachable" });
  });
});
