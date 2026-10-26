import { describe, expect, it } from "vitest";
import { displayPushURL, parsePushConfig, pushConfigStamp, resolvePushDestination, reviewedPushArguments, type PushReviewPlan } from "../src/entities/git/lib/push-review";

const resolve = (config: Record<string, string[]> = {}, branch = "topic", current: string | null = "topic", override?: string) => resolvePushDestination(config, ["origin", "fork"], branch, current, override);

describe("reviewed push destinations", () => {
  it("preserves repeated NUL config values and multiline values", () => {
    expect(parsePushConfig("remote.origin.push\nrefs/heads/a:refs/heads/b\0remote.origin.push\nrefs/heads/c:refs/heads/d\0user.name\nDemo\nName\0")).toEqual({ "remote.origin.push": ["refs/heads/a:refs/heads/b", "refs/heads/c:refs/heads/d"], "user.name": ["Demo\nName"] });
  });
  it("chooses branch pushRemote before remote.pushDefault and upstream", () => {
    expect(resolve({ "branch.topic.pushremote": ["fork"], "remote.pushdefault": ["origin"], "branch.topic.remote": ["origin"] }).remote).toBe("fork");
    expect(resolve({ "remote.pushdefault": ["fork"], "branch.topic.remote": ["origin"] }).remote).toBe("fork");
  });
  it("honors an upstream branch with another name", () => {
    expect(resolve({ "push.default": ["upstream"], "branch.topic.remote": ["origin"], "branch.topic.merge": ["refs/heads/review"] })).toEqual({ remote: "origin", destination: "refs/heads/review", setUpstream: false });
  });
  it("does not incorrectly preview simple as same-name upstream", () => {
    expect(() => resolve({ "branch.topic.remote": ["origin"], "branch.topic.merge": ["refs/heads/review"] })).toThrow("different name");
  });
  it("supports triangular simple pushes", () => {
    expect(resolve({ "branch.topic.remote": ["origin"], "branch.topic.merge": ["refs/heads/main"], "branch.topic.pushremote": ["fork"] }).destination).toBe("refs/heads/topic");
  });
  it("honors an exact configured push refspec for a noncurrent branch", () => {
    expect(resolve({ "remote.origin.push": ["refs/heads/topic:refs/heads/code-review"] }, "topic", "main").destination).toBe("refs/heads/code-review");
    expect(() => resolve({ "remote.origin.push": ["HEAD:refs/heads/code-review"] }, "topic", "main")).toThrow("does not select");
  });
  it.each(["matching", "nothing"])("blocks ambiguous push.default=%s", (mode) => {
    expect(() => resolve({ "push.default": [mode] })).toThrow("single branch");
  });
  it.each([["refs/heads/*:refs/heads/*"], ["+refs/heads/topic:refs/heads/topic"], ["topic:review", "other:other"]])("blocks multi-branch or implicit force refspecs %j", (...spec) => {
    expect(() => resolve({ "remote.origin.push": spec as string[] })).toThrow();
  });
  it("blocks an upstream mode without tracking instead of guessing", () => {
    expect(() => resolve({ "push.default": ["upstream"] })).toThrow("missing");
  });
  it("blocks mirrors and invalid branch destinations", () => {
    expect(() => resolve({ "remote.origin.mirror": ["true"] })).toThrow("Mirror");
    expect(() => resolve({ "remote.origin.push": ["topic:refs/tags/release"] })).toThrow("branch ref");
    expect(() => resolve({ "remote.origin.push": ["topic:refs/heads/a..b"] })).toThrow("branch ref");
  });
  it("uses an explicit PR target and same-name branch even with pushRemote or custom refspec", () => {
    expect(resolve({ "branch.topic.pushremote": ["fork"], "remote.origin.push": ["topic:another"], "push.default": ["matching"] }, "topic", "topic", "origin")).toEqual({ remote: "origin", destination: "refs/heads/topic", setUpstream: true });
  });
  it("stamps relevant destination/auth config but ignores unrelated UI config", () => {
    expect(pushConfigStamp({ "user.email": ["dev@example.com"], "ui.theme": ["dark"] })).toBe(pushConfigStamp({ "user.email": ["dev@example.com"], "ui.theme": ["light"] }));
    expect(pushConfigStamp({ "remote.origin.pushurl": ["ssh://example.com/one"] })).not.toBe(pushConfigStamp({ "remote.origin.pushurl": ["ssh://example.com/two"] }));
  });
  it("uses immutable source and a force lease for the exact observed destination", () => {
    const plan = { sourceOID: "a".repeat(40), remote: "fork", destination: "refs/heads/topic", destinationOID: "b".repeat(40), force: true } as PushReviewPlan;
    expect(reviewedPushArguments(plan)).toEqual(["push", "--porcelain", "--no-follow-tags", "--recurse-submodules=no", `--force-with-lease=refs/heads/topic:${"b".repeat(40)}`, "fork", `${"a".repeat(40)}:refs/heads/topic`]);
    expect(reviewedPushArguments({ ...plan, destinationOID: null })).toContain("--force-with-lease=refs/heads/topic:");
    expect(reviewedPushArguments({ ...plan, force: false }).some((a) => a.startsWith("--force"))).toBe(false);
  });
  it("redacts URL credentials in previews and git errors", () => {
    expect(displayPushURL("fatal: https://user:secret@example.com/demo.git?token=abc&x=1")).toBe("fatal: https://[redacted]@example.com/demo.git?token=[redacted]&x=1");
    expect(displayPushURL("git@example.com:demo/repo.git")).toBe("git@example.com:demo/repo.git");
  });
});
