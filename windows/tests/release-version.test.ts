import { describe, expect, it } from "vitest";
import { betaEndpoint, compareVersions, isNewerVersion, isPrerelease } from "../src/shared/platform/release-version";

describe("release versions", () => {
  it("orders betas before their release, as semver does", () => {
    const order = ["0.4.1", "0.4.2-alpha", "0.4.2-beta.1", "0.4.2-beta.2", "0.4.2-beta.10", "0.4.2-rc.1", "0.4.2", "v0.4.10", "1.0.0"];
    for (let i = 0; i + 1 < order.length; i++) {
      expect(compareVersions(order[i], order[i + 1])).toBe(-1);
      expect(compareVersions(order[i + 1], order[i])).toBe(1);
    }
    expect(compareVersions("v0.4.2-beta.1", "0.4.2-beta.1")).toBe(0);
    expect(compareVersions("0.4", "0.4.0")).toBe(0);
  });
  it("tells a beta user about the release, and a release user not about an older beta", () => {
    expect(isNewerVersion("0.4.2", "0.4.2-beta.3")).toBe(true);
    expect(isNewerVersion("0.4.2-beta.1", "0.4.2")).toBe(false);
    expect(isNewerVersion("0.4.2-beta.1", "0.4.1")).toBe(true);
  });
  it("spots pre-releases", () => {
    expect(isPrerelease("0.4.2-beta.1")).toBe(true);
    expect(isPrerelease("v0.4.2")).toBe(false);
  });
});

describe("beta update address", () => {
  const asset = (tag: string) => [{ name: "latest.json", browser_download_url: `https://example.com/${tag}/latest.json` }];
  it("points at the newest pre-release, and at nothing once a newer release is out", () => {
    const beta = { tag_name: "v0.4.2-beta.1", prerelease: true, assets: asset("v0.4.2-beta.1") };
    const stable = { tag_name: "v0.4.1", assets: asset("v0.4.1") };
    const draft = { tag_name: "v0.4.2-beta.2", prerelease: true, draft: true, assets: asset("v0.4.2-beta.2") };
    const macOnly = { tag_name: "v0.4.2-beta.3", prerelease: true, assets: [{ name: "Gitrochi-0.4.2-beta.3-macOS.zip" }] };
    expect(betaEndpoint([draft, macOnly, beta, stable])).toBe("https://example.com/v0.4.2-beta.1/latest.json");
    expect(betaEndpoint([{ tag_name: "v0.4.2", assets: asset("v0.4.2") }, beta, stable])).toBeNull();
    expect(betaEndpoint([])).toBeNull();
  });
});
