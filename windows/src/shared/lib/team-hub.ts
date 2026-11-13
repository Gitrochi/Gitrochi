import { ipc } from "@/shared/api";
import { t } from "@/shared/i18n";
import { safeWorkPath } from "./work-validation";

export interface HubParticipant { member: string; client: string; branch: string; head: string; }
export interface TeamOverlap { kind: "same-file" | "related-file"; a: HubParticipant; b: HubParticipant; paths: string[]; }
export interface TeamPresence extends HubParticipant { changed: string[]; related: string[]; updated: string; expires: string; }
export interface TeamSnapshot { repo: string; presence: TeamPresence[]; overlaps: TeamOverlap[]; observedAt: string; }
const object = (v: unknown): Record<string, unknown> => v !== null && typeof v === "object" && !Array.isArray(v) ? v as Record<string, unknown> : {};
const text = (v: unknown) => typeof v === "string" && v.length <= 1024 && !/[\x00-\x1f]/.test(v) ? v : "";
const paths = (v: unknown) => Array.isArray(v) ? [...new Set(v.filter((x): x is string => typeof x === "string" && safeWorkPath(x)))].slice(0, 5000) : [];
const participant = (value: unknown): HubParticipant => { const v = object(value); return { member: text(v.member), client: text(v.client), branch: text(v.branch), head: text(v.head) }; };

/** HTTPS, or loopback HTTP; secrets never travel through redirects. */
export function teamHubEndpoint(value: string): string {
  let url: URL;
  try { url = new URL(value); } catch { throw new Error("Use an HTTPS hub URL, or HTTP on loopback, without credentials or query parameters."); }
  if (url.username || url.password || url.search || url.hash || (url.protocol !== "https:" && !(url.protocol === "http:" && ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname)))) throw new Error("Use an HTTPS hub URL, or HTTP on loopback, without credentials or query parameters.");
  return url.href.replace(/\/$/, "");
}

export function teamRepoKey(value: string): string {
  const raw = value.trim().replace(/\.git\/?$/, "");
  let result = raw;
  if (/^[a-z][a-z0-9+.-]*:\/\//i.test(raw)) { let url: URL; try { url = new URL(raw); } catch { throw new Error("Enter the repository key as host/owner/repository."); } if (url.protocol === "file:") throw new Error("Choose a repository remote, not a local path."); result = url.hostname.toLowerCase() + url.pathname; }
  else if (/^[^/@:]+@[^/:]+:/.test(raw)) result = raw.slice(raw.indexOf("@") + 1).replace(":", "/");
  const slash = result.indexOf("/");
  if (slash < 1 || !safeWorkPath(result) || !/^[a-zA-Z0-9.-]+\//.test(result)) throw new Error("Enter the repository key as host/owner/repository.");
  return result.slice(0, slash).toLowerCase() + result.slice(slash);
}

/** Reject cross-repository responses rather than showing unrelated work. */
export function decodeTeamSnapshot(repo: string, presenceValue: unknown, overlapValue: unknown, now = new Date()): TeamSnapshot {
  const p = object(presenceValue), o = object(overlapValue);
  const presenceRows = p.presence === null ? [] : p.presence;
  const overlapRows = o.overlaps === null ? [] : o.overlaps;
  if (p.repo !== repo || o.repo !== repo || !Array.isArray(presenceRows) || !Array.isArray(overlapRows) || presenceRows.length > 1000 || overlapRows.length > 5000) throw new Error("The team hub returned an invalid repository snapshot.");
  const presence = presenceRows.flatMap(value => {
    const row = object(value), member = participant(row);
    const expires = text(row.expires), updated = text(row.updated);
    if (!member.member || !Number.isFinite(Date.parse(updated)) || Date.parse(expires) <= now.getTime() || !Number.isFinite(Date.parse(expires))) return [];
    return [{ ...member, changed: paths(row.changed), related: paths(row.related), updated, expires }];
  });
  const active = new Set(presence.map(row => row.member + "\0" + row.client));
  const matches = (person: HubParticipant) => presence.some(row => row.member === person.member && row.client === person.client && row.branch === person.branch && row.head === person.head);
  const seen = new Set<string>();
  const overlaps = overlapRows.flatMap(value => {
    const row = object(value), a = participant(row.a), b = participant(row.b);
    if ((row.kind !== "same-file" && row.kind !== "related-file") || !active.has(a.member + "\0" + a.client) || !active.has(b.member + "\0" + b.client) || !matches(a) || !matches(b) || a.member === b.member) return [];
    const changed = paths(row.paths); if (!changed.length) return [];
    const key = JSON.stringify([row.kind, a, b, changed]); if (seen.has(key)) return []; seen.add(key);
    return [{ kind: row.kind as TeamOverlap["kind"], a, b, paths: changed }];
  });
  return { repo, presence, overlaps, observedAt: now.toISOString() };
}

/** Read-only snapshots use the same v1 API as the monitor; no presence is published. */
export async function readTeamSnapshot(endpoint: string, repo: string, token: string): Promise<TeamSnapshot> {
  const base = teamHubEndpoint(endpoint), key = teamRepoKey(repo);
  const read = async (resource: "presence" | "overlaps") => {
    const response = await ipc.hubRead(`${base}/api/v1/repos/${key.split("/").map(encodeURIComponent).join("/")}/${resource}`, token);
    if (response.status !== 200) throw new Error(t("Team hub request failed ({0}).", response.status));
    if (response.body.length > 2_000_000) throw new Error("The team hub response is too large.");
    return JSON.parse(response.body) as unknown;
  };
  const [presence, overlaps] = await Promise.all([read("presence"), read("overlaps")]);
  return decodeTeamSnapshot(key, presence, overlaps);
}
