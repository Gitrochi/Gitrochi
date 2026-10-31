import { canLoadImage, markdownRefs, type RepoTarget } from "@/entities/git";
import type { HubItem } from "../api/hub";

/** Release ordering mirrors macOS Core/ReleaseCatalog.swift. */
export interface ReleaseVersion { family: string; core: string[]; pre: string[] }
export function releaseVersion(tag: string): ReleaseVersion | null {
  const match = /^(.*?)(?:v|V)?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([\da-zA-Z-]+(?:\.[\da-zA-Z-]+)*))?(?:\+([\da-zA-Z-]+(?:\.[\da-zA-Z-]+)*))?$/.exec(tag);
  if (!match) return null;
  const pre = match[5]?.split(".") ?? [];
  if (pre.some(x => /^\d+$/.test(x) && x.length > 1 && x.startsWith("0"))) return null;
  const family = match[1];
  if (family && !/[@/\-_]$/.test(family)) return null;
  return { family, core: match.slice(2, 5), pre };
}
const numeric = (a: string, b: string) => a.length - b.length || (a < b ? -1 : a > b ? 1 : 0);
export function compareReleaseVersions(a: string, b: string): number | null {
  const x = releaseVersion(a), y = releaseVersion(b);
  if (!x || !y || x.family !== y.family) return null;
  for (let i = 0; i < 3; i++) { const n = numeric(x.core[i], y.core[i]); if (n) return n; }
  if (!x.pre.length || !y.pre.length) return Number(!x.pre.length) - Number(!y.pre.length);
  for (let i = 0; i < Math.max(x.pre.length, y.pre.length); i++) {
    const p = x.pre[i], q = y.pre[i];
    if (p === undefined || q === undefined) return x.pre.length - y.pre.length;
    if (p === q) continue;
    const pn = /^\d+$/.test(p), qn = /^\d+$/.test(q);
    return pn && qn ? numeric(p, q) : pn !== qn ? (pn ? -1 : 1) : p < q ? -1 : 1;
  }
  return 0;
}
export const releaseTag = (item: HubItem) => String(item.data.tag_name ?? item.subtitle.split(" · ")[0]);
export const releaseDate = (item: HubItem) => String(item.data.published_at ?? item.data.released_at ?? item.data.created_at ?? "");
export const releaseState = (item: HubItem) => item.data.draft === true ? "Draft" : item.data.prerelease === true ? "Prerelease" : "Stable";
export const releaseFamily = (item: HubItem) => releaseVersion(releaseTag(item))?.family ?? /^(.*[@/])[^@/]+$/.exec(releaseTag(item))?.[1] ?? "";
export function orderedReleases(items: HubItem[], sort: "date" | "version" = "date"): HubItem[] {
  // A global numeric sort is meaningful only within one package's version scheme.
  const versions = items.map(item => releaseVersion(releaseTag(item)));
  const numericOrder = sort === "version" && versions.every(v => v && v.family === versions[0]?.family);
  return [...items].sort((a, b) => (numericOrder ? compareReleaseVersions(releaseTag(b), releaseTag(a)) ?? 0 : 0) || releaseDate(b).localeCompare(releaseDate(a)) || a.id.localeCompare(b.id));
}
export function newestReleases(items: HubItem[]) {
  const sorted = orderedReleases(items);
  return { stable: sorted.find(item => releaseState(item) === "Stable"), prerelease: sorted.find(item => releaseState(item) === "Prerelease") };
}
/** The package a page opens with: the one whose release was published last. */
export function defaultReleaseFamily(items: HubItem[]): string {
  const newest = orderedReleases(items.filter(item => releaseState(item) !== "Draft"))[0] ?? orderedReleases(items)[0];
  return newest ? releaseFamily(newest) : "";
}
/** A readable package name: its newest release's title without the version ("Desktop 1.2.0" → "Desktop"). */
export function releasePackageName(items: HubItem[], family: string): string {
  const newest = orderedReleases(items.filter(item => releaseFamily(item) === family))[0];
  if (newest) {
    const tag = releaseTag(newest), version = releaseVersion(tag);
    let name = version ? newest.title.replace(new RegExp(`v?${version.core.join("\\.")}(?:-[\\w.-]+)?`, "gi"), " ") : newest.title;
    name = name.split(tag).join(" ");
    name = name.replace(/\(\s*\)|\[\s*\]/g, " ").replace(/\s+/g, " ").replace(/^[\s\-–—:·@/_]+|[\s\-–—:·@/_]+$/g, "");
    if (name) return name;
  }
  return family.replace(/[@/\-_]+$/, "");
}
/** Recent releases of one package, oldest first: older stables, the newest stable, then a newer prerelease. */
export function releaseTimeline(items: HubItem[], family: string, count = 4) {
  const sorted = orderedReleases(items.filter(item => releaseFamily(item) === family && releaseState(item) !== "Draft"));
  const index = sorted.findIndex(item => releaseState(item) === "Stable");
  if (index < 0) return { stable: undefined, prerelease: sorted[0], path: sorted.slice(0, 1) };
  const stable = sorted[index], prerelease = index > 0 ? sorted[0] : undefined;
  const older = sorted.slice(index + 1).filter(item => releaseState(item) === "Stable").slice(0, count - 1).reverse();
  return { stable, prerelease, path: [...older, stable, ...(prerelease ? [prerelease] : [])] };
}
const packageFile = /\.(dmg|pkg|zip|exe|msi|msix|appimage|deb|rpm|apk|tar\.gz|tgz|tar\.xz|7z)$/i;
/** Installers and archives of this version come first; checksums, signatures and helper binaries fold away. */
export function releaseAssetGroups<T extends { name: string }>(assets: T[], tag: string): { primary: T[]; other: T[] } {
  const version = releaseVersion(tag), packages = assets.filter(asset => packageFile.test(asset.name));
  const versioned = version ? packages.filter(asset => asset.name.includes(version.core.join("."))) : [];
  const primary = versioned.length ? versioned : packages;
  if (!primary.length || primary.length === assets.length) return { primary: assets, other: [] };
  return { primary, other: assets.filter(asset => !primary.includes(asset)) };
}
export function releaseCompareURL(target: RepoTarget | null, base: string, head: string): string | null {
  if (!target || !base || !head || base === head || [base, head].some(x => /[\x00-\x20\x7f]/.test(x))) return null;
  const a = releaseVersion(base), b = releaseVersion(head);
  if (a?.family !== b?.family || (!a && !b && base.split(/[@/]/).slice(0, -1).join("/") !== head.split(/[@/]/).slice(0, -1).join("/"))) return null;
  return `https://${target.host}/${target.path}/${target.provider === "gitlab" ? "-/" : ""}compare/${encodeURIComponent(base)}...${encodeURIComponent(head)}`;
}
export function releaseAssetSize(size: number): string {
  if (size < 1024) return `${size} B`;
  const units = ["KB", "MB", "GB", "TB"];
  let value = size / 1024, unit = 0;
  while (value >= 1024 && unit < units.length - 1) { value /= 1024; unit++; }
  return `${value.toFixed(value < 10 ? 1 : 0)} ${units[unit]}`;
}

/** Release notes and app updates resolve relative files at the published tag. */
export function releaseMarkdownLinks(target: RepoTarget | null, tag: string) {
  if (!target) return {};
  const web = `https://${target.host}/${target.path}`, revision = tag || "HEAD";
  return {
    refs: {
      ...markdownRefs(target, revision),
      link: (href: string) => {
        try { return new URL(href, `${web}/${target.provider === "gitlab" ? "-/" : ""}blob/${encodeURIComponent(revision)}/`).href; }
        catch { return null; }
      },
    },
    canLoadImage: (src: string) => canLoadImage(target, src),
  };
}
