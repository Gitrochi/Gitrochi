import { afterEach, describe, expect, it, vi } from "vitest";
import type { HostAccount } from "@/entities/git";
import { defaultGitchFolder, existingGitchAccount, gitchAccountName, type GitchAccount, gitHubEmails, gitLabEmails } from "@/entities/gitch";
import { AccountStore, MissingKeyScope } from "@/entities/hosting";
import { ipc } from "@/shared/api";

const gitch = (id: string, hosts: string): GitchAccount => ({ id, email: "", hosts, rules: null, sshKey: false } as unknown as GitchAccount);
const github: HostAccount = { id: "gh", provider: "github", server: "https://github.com", username: "octocat", name: null, avatarURL: null };
const gitlab: HostAccount = { id: "gl", provider: "gitlab", server: "https://gitlab.example.co.kr", username: "dev", name: null, avatarURL: null };
const store = () => { const s = new AccountStore(); s.accounts = [github, gitlab]; return s; };
const key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureKeyMaterial0000000000000000000000 dev@example";

afterEach(() => vi.restoreAllMocks());

describe("connecting a saved account to gitch", () => {
  it("names the account after the login, adding the server's label when another server has the name", () => {
    expect(gitchAccountName("octocat", "github.com", [])).toBe("octocat");
    expect(gitchAccountName("octocat", "github.com", [gitch("octocat", "github.com")])).toBe("octocat");
    expect(gitchAccountName("dev", "gitlab.example.co.kr", [gitch("dev", "github.com")])).toBe("dev-example");
    expect(gitchAccountName("dev", "gitlab.example.co.kr", [gitch("dev", "github.com"), gitch("dev-example", "github.com")])).toBe("dev-example-2");
    expect(gitchAccountName("_odd name", "github.com", [])).toBe("odd-name");
    expect(existingGitchAccount("dev", "gitlab.example.co.kr", [gitch("dev", "github.com, gitlab.example.co.kr(포트 2222)")])?.id).toBe("dev");
    expect(existingGitchAccount("dev", "gitlab.example.co.kr", [gitch("dev", "github.com")])).toBeNull();
  });

  it("offers verified emails with the primary first, and GitHub's noreply address when the email is private", () => {
    const listed = [{ email: "work@example.com", verified: true }, { email: "me@example.com", primary: true, verified: true }, { email: "old@example.com", verified: false }];
    expect(gitHubEmails(listed, null, 42, "octocat", true)).toEqual(["me@example.com", "work@example.com", "42+octocat@users.noreply.github.com"]);
    expect(gitHubEmails(null, "me@example.com", 42, "octocat", true)).toEqual(["me@example.com"]);
    expect(gitHubEmails(null, null, 42, "octocat", false)).toEqual([]);
    expect(gitLabEmails("commit@example.com", "Commit@example.com", null)).toEqual(["commit@example.com"]);
  });

  it("defaults the folder to an open repository's parent on the same server, never home, Desktop or root", () => {
    const home = "/Users/me";
    expect(defaultGitchFolder([{ path: "/Users/me/Desktop/work/app", host: "gitlab.example.co.kr" }], "gitlab.example.co.kr", home)).toBe("/Users/me/Desktop/work");
    expect(defaultGitchFolder([{ path: "/Users/me/Desktop/work/app", host: "github.com" }], "gitlab.example.co.kr", home)).toBeNull();
    expect(defaultGitchFolder([{ path: "/Users/me/Desktop/app", host: "github.com" }, { path: "/Users/me/app", host: "github.com" }, { path: "/app", host: "github.com" }], "github.com", home)).toBeNull();
    expect(defaultGitchFolder([{ path: "C:\\Users\\me\\Desktop\\app", host: "github.com" }, { path: "C:\\Users\\me\\src\\app", host: "github.com" }], "github.com", "C:\\Users\\me")).toBe("C:\\Users\\me\\src");
    expect(defaultGitchFolder([{ path: "D:\\app", host: "github.com" }], "github.com", "C:\\Users\\me")).toBeNull();
  });

  it("reads email choices with the saved token", async () => {
    vi.spyOn(ipc, "secretGet").mockResolvedValue("fixture-token");
    vi.spyOn(ipc, "http").mockImplementation(async (_method, url) => {
      if (url.endsWith("/api/v4/user")) return { status: 200, body: JSON.stringify({ commit_email: "c@example.com", email: "e@example.com", public_email: null }) };
      if (url.endsWith("/user/emails")) return { status: 404, body: "{}" };
      if (url.endsWith("/user")) return { status: 200, body: JSON.stringify({ id: 7, login: "octocat", email: null }) };
      return { status: 500, body: "" };
    });
    expect(await store().gitchEmails(gitlab)).toEqual(["c@example.com", "e@example.com"]);
    expect(await store().gitchEmails(github)).toEqual(["7+octocat@users.noreply.github.com"]);
  });

  it("registers the public key once, and reports a token without the scope instead of failing", async () => {
    vi.spyOn(ipc, "secretGet").mockResolvedValue("fixture-token");
    const posted: string[] = [];
    vi.spyOn(ipc, "http").mockImplementation(async (method, url, _headers, body) => {
      if (method === "GET") return { status: 200, body: url.includes("gitlab") ? "[]" : JSON.stringify([{ key: key.split(" ").slice(0, 2).join(" ") }]) };
      posted.push(url + " " + body);
      return { status: 201, body: "{}" };
    });
    expect(await store().registerSSHKey(github, key, "Gitrochi (octocat)")).toBe(false);
    expect(await store().registerSSHKey(gitlab, key, "Gitrochi (dev)")).toBe(true);
    expect(posted).toHaveLength(1);
    expect(posted[0]).toContain("https://gitlab.example.co.kr/api/v4/user/keys");
    expect(posted[0]).not.toContain("dev@example");

    vi.spyOn(ipc, "http").mockResolvedValue({ status: 403, body: JSON.stringify({ message: "insufficient_scope" }) });
    await expect(store().registerSSHKey(gitlab, key, "Gitrochi (dev)")).rejects.toBeInstanceOf(MissingKeyScope);
  });
});
