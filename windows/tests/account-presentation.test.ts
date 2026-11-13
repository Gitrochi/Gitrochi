import { describe, expect, it } from "vitest";
import type { HostAccount, RepoTarget } from "@/entities/git";
import { type AccountStatus, accountInitial, accountStatusFor, accountReason, accountReasonText, accountStatusAction, accountStatusCaption, accountStatusIcon, accountStatusTitle, toolbarAccountBadge } from "@/entities/hosting";

const account = (id: string, server = "https://github.com"): HostAccount => ({ id, provider: "github", server, username: id, name: null, avatarURL: null });
const target: RepoTarget = { provider: "github", host: "github.com", path: "sample-studio/desktop", remote: "origin" };
const statuses: AccountStatus[] = ["signedIn", "needsApproval", "needsYourApproval", "expired"];

describe("Account presentation", () => {
  it("badges the toolbar only when the repository's own account needs attention", () => {
    expect(toolbarAccountBadge(null)).toBe(false);
    expect(toolbarAccountBadge("signedIn")).toBe(false);
    for (const status of ["needsApproval", "needsYourApproval", "expired"] as const) expect(toolbarAccountBadge(status)).toBe(true);
  });

  it("does not call an unreadable saved sign-in expired", () => {
    // a locked or missing credential may only need another read
    expect(accountStatusFor("unavailable", false, null)).toBe("unreadable");
    expect(accountStatusAction("unreadable")).toBe("Retry");
    expect(accountStatusTitle("unreadable")).not.toBe(accountStatusTitle("expired"));
    // only a token the server rejected is an expired sign-in
    expect(accountStatusFor("unavailable", true, null)).toBe("expired");
    expect(accountStatusFor("authorizationRequired", false, "signedIn")).toBe("needsYourApproval");
    expect(accountStatusFor("ready", true, "expired")).toBe("signedIn");
  });

  it("keeps the previous state while a read or an approval is under way", () => {
    for (const previous of ["needsYourApproval", "unreadable", "expired", "signedIn"] as const) expect(accountStatusFor("loading", false, previous)).toBe(previous);
    // nothing known yet: neither signed in nor a badge
    expect(accountStatusFor("loading", false, null)).toBe("checking");
    expect(toolbarAccountBadge("checking")).toBe(false);
    expect(accountStatusAction("checking")).toBeNull();
    expect(toolbarAccountBadge(accountStatusFor("loading", false, "needsYourApproval"))).toBe(true);
    expect(toolbarAccountBadge("unreadable")).toBe(true);
  });

  it("gives each state its own icon, words and action", () => {
    expect(statuses.map(accountStatusIcon)).toEqual(["check", "shield", "key", "warning"]);
    expect(new Set(statuses.map(accountStatusTitle)).size).toBe(4);
    expect(statuses.map(accountStatusAction)).toEqual([null, "Renew…", "Approve…", "Sign in again…"]);
    expect(accountStatusCaption("signedIn")).toBeNull();
    expect(accountStatusCaption("expired")).toBe("The token expired or was revoked.");
  });

  it("says why the repository uses its account", () => {
    const alice = account("alice"), bob = account("bob"), mirror = account("carol", "https://git.example.com");
    expect(accountReason(alice, target, [alice], null)).toEqual({ kind: "matches", repository: "sample-studio/desktop" });
    expect(accountReason(alice, target, [alice, bob], null)).toEqual({ kind: "first", host: "github.com" });
    // the user's choice wins over every other reason
    expect(accountReason(bob, target, [alice, bob], "bob")).toEqual({ kind: "chosen" });
    expect(accountReason(mirror, target, [mirror], "carol")).toEqual({ kind: "chosen" });
    // a choice for another account does not explain this one
    expect(accountReason(alice, target, [alice, bob], "gone")).toEqual({ kind: "first", host: "github.com" });
    expect(accountReason(mirror, target, [mirror], null)).toEqual({ kind: "sameServer", host: "github.com" });
    expect(accountReasonText({ kind: "matches", repository: "sample-studio/desktop" })).toBe("Matches sample-studio/desktop");
    expect(accountReasonText({ kind: "chosen" })).toBe("Chosen for this repository");
    expect(accountReasonText({ kind: "first", host: "github.com" })).toBe("First account on github.com");
    expect(accountReasonText({ kind: "sameServer", host: "github.com" })).toBe("Same server as github.com");
  });

  it("takes the initial from the name, else the username", () => {
    expect(accountInitial("Alex Kim", "demo-alex")).toBe("A");
    expect(accountInitial(null, "demo-alex")).toBe("D");
    expect(accountInitial("  ", "zoe")).toBe("Z");
    expect(accountInitial("김하늘", "sky")).toBe("김");
    expect(accountInitial("😀 Team", "team")).toBe("😀");
    expect(accountInitial("", "")).toBe("?");
  });
});
