import type { TeamOverlap } from "@/shared/lib";

/**
 * What the core's `hub_share` answers: one team hub presence body per shared session. The core decides what is in a body
 * (crates/gitrochi-ledger CONTRACT.md, Sharing with the team hub); the app posts it as it is.
 * (macOS: Core/LedgerHubShare.swift)
 */
export interface LedgerHubShareItem {
  sessionId: string;
  repo: string;
  client: string;
  presence: Record<string, unknown>;
}

export interface LedgerHubShareResult {
  rev: number;
  sessions: LedgerHubShareItem[];
  unshared: { sessionId: string; reason: "no_remote" | "limit" }[];
}

/** Another computer's Ledger session that touches what one of this computer's sessions touches, as the hub found it */
export interface LedgerHubOverlap {
  session: string;
  member: string;
  branch: string;
  paths: string[];
}

/** How the hub answered one report or withdrawal */
export type HubOutcome =
  /** taken */
  | "accepted"
  /** a hub older than the `ledger` field: send the same body without it */
  | "plainBodyNeeded"
  /** this one entry was refused; it is not sent again until it changes */
  | "skipped"
  /** the token was not accepted */
  | "rejected"
  | "limited"
  | "unreachable";

/** One entry as the hub last answered it; `accepted` is false when it refused this body */
export interface HubPublished {
  repo: string;
  body: string;
  accepted: boolean;
}

export interface HubPost {
  client: string;
  repo: string;
  body: string;
}

export interface HubWithdrawal {
  client: string;
  repo: string;
}

/** Every entry is sent again this often, below the hub's 10-minute presence lifetime, which also refreshes overlaps */
export const HUB_REFRESH_MS = 240_000;
/** How often `rev` is read while sharing is on */
export const HUB_TICK_MS = 15_000;
const PREFIX = "ledger/";

export function hubOutcome(status: number, text: string): HubOutcome {
  if (status >= 200 && status < 300) return "accepted";
  // the hub's JSON error message quotes the field: unknown field \"ledger\"
  if (status === 400 && text.includes('unknown field \\"ledger\\"')) return "plainBodyNeeded";
  if (status === 401 || status === 403) return "rejected";
  if (status === 429) return "limited";
  if (status >= 400 && status < 500) return "skipped";
  return "unreachable";
}

/** The wait after `failures` failed passes in a row: 30 s, doubling, at most 10 minutes */
export const hubBackoff = (failures: number) => Math.min(600_000, 30_000 * 2 ** Math.min(Math.max(failures - 1, 0), 5));

/** A random name for this computer on the hub: says nothing about it, only stays the same */
export function newHubComputer(): string {
  const bytes = new Uint8Array(6);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

/** `ledger/<computer>/<session>` → its parts; null for anything else, such as a monitor's entry */
export function parseHubClient(client: string): { computer: string; session: string } | null {
  if (!client.startsWith(PREFIX)) return null;
  const parts = client.slice(PREFIX.length).split("/");
  return parts.length === 2 && parts[0] && parts[1] ? { computer: parts[0], session: parts[1] } : null;
}

const sorted = (value: unknown): unknown => {
  if (Array.isArray(value)) return value.map(sorted);
  if (value && typeof value === "object") return Object.fromEntries(Object.keys(value).sort().map((k) => [k, sorted((value as Record<string, unknown>)[k])]));
  return value;
};

/**
 * The body to post: the core's presence with sorted keys, so an unchanged session is recognised, and without `ledger`
 * for a hub that predates it
 */
export function hubBody(presence: Record<string, unknown>, plain: boolean): string {
  const value: Record<string, unknown> = { ...presence };
  if (plain) delete value.ledger;
  return JSON.stringify(sorted(value));
}

/** What to send: new and changed sessions (all of them on a full refresh), and the entries of sessions no longer shared */
export function hubPlan(items: LedgerHubShareItem[], published: ReadonlyMap<string, HubPublished>, plain: boolean, full: boolean): { post: HubPost[]; withdraw: HubWithdrawal[] } {
  const post: HubPost[] = [];
  const wanted = new Set<string>();
  const moved: HubWithdrawal[] = [];
  for (const item of items) {
    wanted.add(item.client);
    const body = hubBody(item.presence, plain);
    const before = published.get(item.client);
    if (full || !before || before.body !== body || before.repo !== item.repo) post.push({ client: item.client, repo: item.repo, body });
    // an entry that moved to another repository leaves the old one
    if (before && before.repo !== item.repo) moved.push({ client: item.client, repo: before.repo });
  }
  const gone = [...published].filter(([client]) => !wanted.has(client)).map(([client, entry]) => ({ client, repo: entry.repo }));
  gone.sort((a, b) => (a.client < b.client ? -1 : a.client > b.client ? 1 : 0));
  return { post, withdraw: [...gone, ...moved] };
}

/**
 * This computer's sessions → other computers' sessions touching the same things. The hub never overlaps one member's own
 * entries; entries that are not Ledger sessions (a monitor's) are left out.
 */
export function hubOverlaps(rows: TeamOverlap[], member: string, computer: string): Record<string, LedgerHubOverlap[]> {
  const out: Record<string, LedgerHubOverlap[]> = {};
  for (const row of rows) {
    for (const [mine, other] of [[row.a, row.b], [row.b, row.a]] as const) {
      const own = parseHubClient(mine.client), theirs = parseHubClient(other.client);
      if (mine.member !== member || other.member === member || !own || own.computer !== computer || !theirs) continue;
      const list = out[own.session] ?? (out[own.session] = []);
      const found = list.find((o) => o.member === other.member && o.session === theirs.session);
      if (found) found.paths = [...found.paths, ...row.paths.filter((p) => !found.paths.includes(p))];
      else list.push({ session: theirs.session, member: other.member, branch: other.branch, paths: [...row.paths] });
      const key = (o: LedgerHubOverlap) => o.member + "\u0000" + o.session;
      list.sort((a, b) => (key(a) < key(b) ? -1 : key(a) > key(b) ? 1 : 0));
    }
  }
  return out;
}
