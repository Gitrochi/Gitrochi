import { describe, expect, it } from "vitest";
import { gitAccountAvatarURL, gitAccountHost, gitAccountKey } from "@/entities/gitch";

describe("Git account presentation", () => {
  it("does not count an SSH port description as another account", () => {
    expect(gitAccountHost("gitlab.example.com (port 2222)")).toBe("gitlab.example.com");
    expect(gitAccountKey("gitlab.example.com(port 2222)", "Alex")).toBe(gitAccountKey("gitlab.example.com", "alex"));
    expect(new Set([gitAccountKey("github.com", "alice"), gitAccountKey("github.com", "bob"), gitAccountKey("gitlab.example.com(port 2222)", "carol"), gitAccountKey("github.com", "Alice")]).size).toBe(3);
  });
  it("uses a GitHub profile image without requiring another sign-in", () => {
    expect(gitAccountAvatarURL("github.com", "octocat")).toBe("https://github.com/octocat.png?size=64");
    for (const username of ["../alice", "alice/name", "-alice", "alice?size=1", ""]) expect(gitAccountAvatarURL("github.com", username)).toBeNull();
    expect(gitAccountAvatarURL("gitlab.example.com", "alice")).toBeNull();
  });
});
