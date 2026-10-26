import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
vi.hoisted(() => vi.stubGlobal("matchMedia", () => ({ matches: false, addEventListener() {} })));
vi.mock("@/entities/terminal", () => ({ TerminalSession: class {} }));
import * as hosting from "@/entities/hosting";
import { accounts } from "@/entities/hosting";
import { RepoStore } from "@/entities/repo";
import * as platform from "@/shared/platform";

const profile = { id: "demo", provider: "github" as const, server: "https://github.com", username: "demo", name: null, avatarURL: null };
let pushURL = "git@github.com:demo/repo.git";
function fixture() {
  const s = new RepoStore();
  s.path = "/fixture/repo"; s.headBranch = "feature"; s.headHash = "a".repeat(40);
  s.target = { provider: "github", remote: "origin", host: "github.com", path: "demo/repo" };
  vi.spyOn(s, "loadPullRequests").mockResolvedValue();
  vi.spyOn(s, "select").mockImplementation(() => {});
  vi.spyOn(s, "openUrl").mockImplementation(() => {});
  return s;
}
beforeEach(() => {
  pushURL = "git@github.com:demo/repo.git";
  vi.spyOn(accounts, "accountFor").mockReturnValue(profile);
  vi.spyOn(accounts, "token").mockResolvedValue("fixture-token");
  vi.spyOn(platform, "git").mockImplementation(async () => ({ status: 0, stdout: pushURL + "\n", stderr: "" }));
  vi.spyOn(hosting, "createPullRequest").mockResolvedValue({ number: 7, url: "https://github.com/demo/repo/pull/7", title: "Feature", author: "demo", source: "feature", target: "main", isDraft: false, updated: null, body: "Details", headSHA: "a".repeat(40), fromFork: false });
});
afterEach(() => vi.restoreAllMocks());

describe("PR creation uses the reviewed publication destination", () => {
  it("keeps the form draft and does not publish a PR when push review is cancelled", async () => {
    const s = fixture(), review = vi.spyOn(s, "requestPushReview").mockResolvedValue(false);
    await s.createPullRequest("Feature", "Details", "main", true);
    expect(review).toHaveBeenCalledWith("feature", false, "origin");
    expect(hosting.createPullRequest).not.toHaveBeenCalled();
    expect(s.newPullRequestDraft).toMatchObject({ title: "Feature", body: "Details", base: "main", draft: true });
  });
  it("blocks a different repository in the push URL before requesting publication", async () => {
    const s = fixture(), review = vi.spyOn(s, "requestPushReview").mockResolvedValue(true);
    pushURL = "https://github.com/other/repo.git";
    await s.createPullRequest("Feature", "Details", "main", false);
    expect(review).not.toHaveBeenCalled(); expect(hosting.createPullRequest).not.toHaveBeenCalled();
    expect(s.errorMessage).toContain("different repository");
  });
  it("creates the PR only after successful review and clears the saved form on success", async () => {
    const s = fixture(), review = vi.spyOn(s, "requestPushReview").mockResolvedValue(true);
    await s.createPullRequest("Feature", "Details", "main", false);
    expect(review).toHaveBeenCalledOnce(); expect(hosting.createPullRequest).toHaveBeenCalledOnce();
    expect(s.newPullRequestDraft).toBeNull(); expect(s.busy).toBeNull();
  });
  it("does not create after the branch changes during push review", async () => {
    const s = fixture();
    vi.spyOn(s, "requestPushReview").mockImplementation(async () => { s.headHash = "b".repeat(40); return true; });
    await s.createPullRequest("Feature", "Details", "main", false);
    expect(hosting.createPullRequest).not.toHaveBeenCalled(); expect(s.newPullRequestDraft?.title).toBe("Feature");
  });
  it("suppresses a late creation error after the same repository has been reopened", async () => {
    const s = fixture(); vi.spyOn(s, "requestPushReview").mockResolvedValue(true);
    let reject!: (error: Error) => void;
    vi.mocked(hosting.createPullRequest).mockImplementation(() => new Promise((_resolve, fail) => { reject = fail; }));
    const pending = s.createPullRequest("Feature", "Details", "main", false);
    await vi.waitFor(() => expect(hosting.createPullRequest).toHaveBeenCalled());
    (s as unknown as { resetState(): void }).resetState();
    s.path = "/fixture/repo"; s.busy = "New operation";
    reject(new Error("Old failure")); await pending;
    expect(s.busy).toBe("New operation"); expect(s.errorMessage).toBeNull();
  });
});
