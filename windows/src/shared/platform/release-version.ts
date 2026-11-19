/**
 * Release versions, ordered as semver: 0.4.2-beta.1 < 0.4.2-beta.2 < 0.4.2 < 0.4.10. A leading "v" is ignored.
 * macOS: ReleaseVersion in App/Updater.swift; gitch: ver_lt
 */

function parts(version: string) {
  const v = version.trim().replace(/^[vV]/, "");
  const dash = v.indexOf("-");
  const core = (dash < 0 ? v : v.slice(0, dash)).split(".").map((n) => Number.parseInt(n, 10) || 0);
  const pre = dash < 0 ? [] : v.slice(dash + 1).split("+")[0].split(".");
  return { core, pre };
}

/** Negative when a comes before b, positive after, 0 when equal */
export function compareVersions(a: string, b: string): number {
  const x = parts(a), y = parts(b);
  for (let i = 0; i < Math.max(x.core.length, y.core.length); i++) {
    const d = (x.core[i] ?? 0) - (y.core[i] ?? 0);
    if (d) return Math.sign(d);
  }
  // a pre-release comes before its release
  if (!x.pre.length || !y.pre.length) return x.pre.length === y.pre.length ? 0 : x.pre.length ? -1 : 1;
  for (let i = 0; i < Math.max(x.pre.length, y.pre.length); i++) {
    const l = x.pre[i], r = y.pre[i];
    if (l === undefined || r === undefined) return l === undefined ? -1 : 1;
    if (l === r) continue;
    const ln = /^\d+$/.test(l), rn = /^\d+$/.test(r);
    if (ln && rn) return Math.sign(Number(l) - Number(r));
    // numbers come before words; words in ASCII order
    if (ln !== rn) return ln ? -1 : 1;
    return l < r ? -1 : 1;
  }
  return 0;
}

export const isNewerVersion = (a: string, b: string) => compareVersions(a, b) > 0;

export const isPrerelease = (version: string) => parts(version).pre.length > 0;

export type ReleaseEntry = { tag_name?: string; draft?: boolean; prerelease?: boolean; assets?: { name?: string; browser_download_url?: string }[] };

/**
 * The beta channel's update address: latest.json of the newest release that has one, pre-releases included. null when
 * that is a regular release, which the default address (releases/latest) already serves.
 * macOS: the release filter in UpdateCenter.check
 */
export function betaEndpoint(releases: ReleaseEntry[]): string | null {
  const candidates = releases.filter((r) => !r.draft && r.tag_name && r.assets?.some((a) => a.name === "latest.json" && a.browser_download_url));
  const newest = candidates.reduce<ReleaseEntry | null>((best, r) => (!best || compareVersions(r.tag_name!, best.tag_name!) > 0 ? r : best), null);
  if (!newest?.prerelease) return null;
  return newest.assets!.find((a) => a.name === "latest.json")!.browser_download_url!;
}
