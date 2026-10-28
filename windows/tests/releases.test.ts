import { afterEach, describe, expect, it, vi } from "vitest";
import { compareReleaseVersions, releaseVersion, orderedReleases, releaseCompareURL, newestReleases, releaseAssetSize, releaseMarkdownLinks } from "@/entities/hosting/model/releases";
import { ReleasePortfolio } from "@/entities/hosting/model/release-portfolio";
import { accounts } from "@/entities/hosting/model/accounts";
import type { HubSource } from "@/entities/hosting/model/hub";
import type { HubItem, HubPage } from "@/entities/hosting/api/hub";
import { parseMarkdown } from "@/shared/lib/markdown";
const target = { provider: "github" as const, host: "github.com", path: "team/repo", remote: "origin" };
const account = { id: "fixture", provider: "github" as const, username: "reader", server: "https://github.com", name: "Demo reader", avatarURL: null };
const source = (name = "repo"): HubSource => ({ path: `/fixture/${name}`, target: { ...target, path: `team/${name}` }, hostingAccount: account });
const item = (tag: string, date = "2026-10-01", data: Record<string, unknown> = {}): HubItem => ({ id: tag, title: tag, subtitle: tag, body: "", url: "", data: { tag_name: tag, published_at: date, ...data } });
afterEach(() => vi.restoreAllMocks());
describe("release discovery", () => {
  it("orders SemVer without numeric overflow and follows prerelease identifier precedence", () => {
    const tags = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.9.0", "1.10.0", "999999999999999999999999.0.0"];
    for (let i = 1; i < tags.length; i++) expect(compareReleaseVersions(tags[i - 1], tags[i])).toBeLessThan(0);
    expect(compareReleaseVersions("v1.0.0+build.2", "1.0.0+build.1")).toBe(0);
    for (const tag of ["v01.0.0", "1.0.0-01", "1.0", "2026-10-28", "build1.2.3"]) expect(releaseVersion(tag)).toBeNull();
  });
  it("never compares different package series and falls back to published dates for mixed tags", () => {
    expect(compareReleaseVersions("client@1.0.0", "server@2.0.0")).toBeNull();
    expect(compareReleaseVersions("client/v1.9.0", "client/v1.10.0")).toBeLessThan(0);
    const items = [item("v1.9.0", "2026-10-02"), item("v1.10.0", "2026-10-01")];
    expect(orderedReleases(items, "version").map(x => x.id)).toEqual(["v1.10.0", "v1.9.0"]);
    expect(orderedReleases([...items, item("nightly", "2026-10-03")], "version")[0].id).toBe("nightly");
    expect(orderedReleases([item("a@9.0.0", "2026-10-01"), item("b@1.0.0", "2026-10-02")], "version")[0].id).toBe("b@1.0.0");
  });
  it("distinguishes drafts and prereleases without guessing from tag names", () => {
    const newest = newestReleases([item("draft", "2026-10-05", { draft: true }), item("v2.0.0-rc.1", "2026-10-03", { prerelease: true }), item("v1.0.0", "2026-10-01")]);
    expect(newest.stable?.id).toBe("v1.0.0"); expect(newest.prerelease?.id).toBe("v2.0.0-rc.1");
    expect(releaseAssetSize(1024)).toBe("1.0 KB");
  });
  it("encodes comparison refs and keeps GitLab and package scopes intact", () => {
    expect(releaseCompareURL(target, "client/v1.0.0", "client/v2.0.0")).toContain("client%2Fv1.0.0...client%2Fv2.0.0");
    expect(releaseCompareURL({ ...target, provider: "gitlab" }, "v1.0.0", "v2.0.0")).toContain("/-/compare/");
    expect(releaseCompareURL(target, "a@1.0.0", "b@2.0.0")).toBeNull();
    expect(releaseCompareURL(target, "a@nightly", "b@nightly")).toBeNull();
    expect(releaseCompareURL(target, "v1\n", "v2")).toBeNull();
  });
  it("resolves release-relative links while still rejecting script URLs", () => {
    const { refs } = releaseMarkdownLinks(target, "client/v1.0.0");
    const parsed = parseMarkdown("[Guide](docs/guide.md) [unsafe](javascript:alert(1))", refs);
    expect(JSON.stringify(parsed)).toContain("https://github.com/team/repo/blob/client%2Fv1.0.0/docs/guide.md");
    expect(JSON.stringify(parsed)).not.toContain('"href":"javascript:');
  });
});
describe("release portfolio", () => {
  it("limits concurrent reads to two, caches results and isolates one repository failure", async () => {
    let active = 0, peak = 0;
    const read = vi.fn(async (value: HubSource): Promise<HubPage> => {
      active++; peak = Math.max(peak, active); await new Promise(resolve => setTimeout(resolve, 5)); active--;
      if (value.target?.path.endsWith("bad")) throw new Error("HTTP 403");
      return { items: [item("v1.0.0")], more: true };
    });
    const portfolio = new ReleasePortfolio(read), sources = [source("one"), source("bad"), source("three")];
    await portfolio.refresh(sources);
    expect(peak).toBe(2); expect(read).toHaveBeenCalledTimes(3);
    expect(portfolio.entry(sources[0])).toMatchObject({ status: "Ready", page: { more: true } });
    expect(portfolio.entry(sources[1]).status).toBe("Access required");
    await portfolio.refresh(sources); expect(read).toHaveBeenCalledTimes(3);
    await portfolio.refresh([sources[0]], true); expect(read).toHaveBeenCalledTimes(4);
  });
  it("drops late replies after the repository or account revision changes", async () => {
    let finish!: (page: HubPage) => void;
    const read = vi.fn(() => new Promise<HubPage>(resolve => { finish = resolve; }));
    const portfolio = new ReleasePortfolio(read), value = source();
    const request = portfolio.refresh([value]);
    expect(portfolio.entry(value).status).toBe("Checking releases…");
    Object.assign(value, { target: { ...target, path: "other/repo" } });
    finish({ items: [item("v1.0.0")], more: false }); await request;
    expect(portfolio.entry(value).status).toBe("Not checked");
    const revision = accounts.revision;
    const next = portfolio.refresh([value]); accounts.revision++;
    finish({ items: [item("v1.0.0")], more: false }); await next;
    expect(portfolio.entry(value).status).toBe("Not checked"); accounts.revision = revision;
  });
  it("keeps no releases, missing access, offline and failed checks distinct", async () => {
    const value = source(), portfolio = new ReleasePortfolio(async () => ({ items: [], more: false }));
    await portfolio.refresh([value]); expect(portfolio.entry(value).status).toBe("No releases");
    const missing = { ...source(), hostingAccount: null }; await portfolio.refresh([missing]); expect(portfolio.entry(missing).status).toBe("Access required");
    const offline = new ReleasePortfolio(async () => { throw new Error("network connection lost"); }); await offline.refresh([value]); expect(offline.entry(value).status).toBe("Offline");
    const failed = new ReleasePortfolio(async () => { throw new Error("HTTP 500"); }); await failed.refresh([value]); expect(failed.entry(value).status).toBe("Check failed");
  });
});
