import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { hubBackoff, hubBody, hubOutcome, hubOverlaps, hubPlan, type HubPublished, type LedgerBackend, type LedgerHubShareItem, type LedgerHubShareResult, LedgerHubSharing, type LedgerHubTransport, parseHubClient } from "@/entities/ledger";
import { ipc } from "@/shared/api";
import { settings } from "@/shared/config";
import { decodePresenceAnswer, type TeamOverlap, withdrawTeamPresence } from "@/shared/lib";

const COMPUTER = "a1b2c3d4e5f6";
const HUB = "https://hub.example.com";

/** A presence body as the core's hub_share builds it (crates/gitrochi-ledger tests check what it may hold) */
const presence = (session: string, changed: string[], extra: Record<string, unknown> = {}) => ({
  repo: "example.com/team/app",
  branch: `feature/${session}`,
  changed,
  related: [],
  client: `ledger/${COMPUTER}/${session}`,
  ledger: { session, project: "app", title: "Retry policy", kind: "research", role: "research", verdict: "active", lastActivity: "2026-11-03T09:00:00Z" },
  ...extra,
});
const item = (session: string, changed: string[] = ["src/retry.ts"], repo = "example.com/team/app"): LedgerHubShareItem => ({ sessionId: session, repo, client: `ledger/${COMPUTER}/${session}`, presence: { ...presence(session, changed), repo } });
const overlap = (a: [string, string], b: [string, string], paths: string[]): TeamOverlap => ({ kind: "same-file", a: { member: a[0], client: a[1], branch: "a", head: "" }, b: { member: b[0], client: b[1], branch: "b", head: "" }, paths });

describe("Team hub sharing: pure parts", () => {
  it("reads the hub's answers", () => {
    expect(hubOutcome(200, "")).toBe("accepted");
    expect(hubOutcome(204, "")).toBe("accepted");
    expect(hubOutcome(400, '{"error":{"code":"INVALID_ARGUMENT","message":"invalid JSON body: unknown field \\"ledger\\""}}')).toBe("plainBodyNeeded");
    expect(hubOutcome(400, '{"error":{"code":"INVALID_ARGUMENT","message":"changed[0]: path must be repository-relative"}}')).toBe("skipped");
    expect(hubOutcome(401, "")).toBe("rejected");
    expect(hubOutcome(403, "")).toBe("rejected");
    expect(hubOutcome(429, "")).toBe("limited");
    expect(hubOutcome(503, "")).toBe("unreachable");
    expect(hubOutcome(0, "")).toBe("unreachable");
  });

  it("waits longer after each failure, at most ten minutes", () => {
    expect([1, 2, 3, 4, 5, 6, 7, 20].map(hubBackoff)).toEqual([30_000, 60_000, 120_000, 240_000, 480_000, 600_000, 600_000, 600_000]);
  });

  it("reads only Ledger client names", () => {
    expect(parseHubClient("ledger/a1b2/S1103-01")).toEqual({ computer: "a1b2", session: "S1103-01" });
    for (const client of ["laptop", "ledger/a1b2", "ledger//S1", "ledger/a1b2/", "ledger/a/b/c", "default"]) expect(parseHubClient(client)).toBeNull();
  });

  it("sends the core's body as it is, with sorted keys, and drops only ledger for an older hub", () => {
    const body = presence("S1103-01", ["src/retry.ts"]);
    expect(JSON.parse(hubBody(body, false))).toEqual(body);
    expect(hubBody({ b: 1, a: { d: 2, c: 3 } }, false)).toBe('{"a":{"c":3,"d":2},"b":1}');
    const plain = JSON.parse(hubBody(body, true));
    expect(Object.keys(plain).sort()).toEqual(["branch", "changed", "client", "related", "repo"]);
  });

  it("plans new, changed and gone entries, and everything on a refresh", () => {
    const published = new Map<string, HubPublished>();
    const first = hubPlan([item("S1"), item("S2")], published, false, false);
    expect(first.post.map((p) => p.client)).toEqual([`ledger/${COMPUTER}/S1`, `ledger/${COMPUTER}/S2`]);
    expect(first.withdraw).toEqual([]);
    for (const p of first.post) published.set(p.client, { repo: p.repo, body: p.body, accepted: true });
    expect(hubPlan([item("S1"), item("S2")], published, false, false).post).toEqual([]);
    expect(hubPlan([item("S1"), item("S2")], published, false, true).post).toHaveLength(2);
    const changed = hubPlan([item("S1", ["src/other.ts"]), item("S2")], published, false, false);
    expect(changed.post.map((p) => p.client)).toEqual([`ledger/${COMPUTER}/S1`]);
    const gone = hubPlan([item("S1")], published, false, false);
    expect(gone.withdraw).toEqual([{ client: `ledger/${COMPUTER}/S2`, repo: "example.com/team/app" }]);
    const moved = hubPlan([item("S1", ["src/retry.ts"], "example.com/team/lib"), item("S2")], published, false, false);
    expect(moved.post.map((p) => p.repo)).toEqual(["example.com/team/lib"]);
    expect(moved.withdraw).toEqual([{ client: `ledger/${COMPUTER}/S1`, repo: "example.com/team/app" }]);
  });

  it("keeps overlaps between this computer's sessions and other members' sessions only", () => {
    const rows = [
      overlap(["alex", `ledger/${COMPUTER}/S1`], ["sam", "ledger/f00dfeed/S9"], ["src/retry.ts"]),
      overlap(["sam", "ledger/f00dfeed/S9"], ["alex", `ledger/${COMPUTER}/S1`], ["REQ-12"]),
      overlap(["alex", "laptop"], ["sam", "ledger/f00dfeed/S9"], ["src/retry.ts"]),
      overlap(["alex", `ledger/${COMPUTER}/S1`], ["sam", "desk"], ["src/retry.ts"]),
      overlap(["alex", "ledger/0ther0ther/S4"], ["sam", "ledger/f00dfeed/S9"], ["src/retry.ts"]),
    ];
    expect(hubOverlaps(rows, "alex", COMPUTER)).toEqual({ S1: [{ session: "S9", member: "sam", branch: "b", paths: ["src/retry.ts", "REQ-12"] }] });
    expect(hubOverlaps(rows, "nobody", COMPUTER)).toEqual({});
  });

  it("decodes presence answers and keeps withdrawal queries safe", async () => {
    const answer = decodePresenceAnswer({ presence: { member: "alex" }, overlaps: [{ kind: "same-file", a: { member: "alex", client: "c", branch: "x", head: "" }, b: { member: "sam", client: "d", branch: "y", head: "" }, paths: ["src/a.ts", "/etc/passwd"] }, { kind: "other", a: {}, b: {}, paths: ["x"] }] });
    expect(answer.member).toBe("alex");
    expect(answer.overlaps.map((o) => o.paths)).toEqual([["src/a.ts"]]);
    const spy = vi.spyOn(ipc, "hubWithdraw").mockResolvedValue({ status: 204, body: "" });
    await withdrawTeamPresence(HUB, "example.com/team/a+b", "ledger/a1b2/S1&x", "token");
    expect(spy).toHaveBeenCalledWith(`${HUB}/api/v1/presence?repo=example.com/team/a%2Bb&client=ledger/a1b2/S1%26x`, "token");
    vi.restoreAllMocks();
  });
});

/** A native-looking backend that answers rev and hub_share; records every method */
function fakeBackend(share: () => LedgerHubShareResult, rev: () => number) {
  const calls: string[] = [];
  const backend = {
    kind: "native",
    async call(method: string) {
      calls.push(method);
      if (method === "rev") return { rev: rev() };
      if (method === "hub_share") return share();
      throw new Error(`unexpected ${method}`);
    },
  } as unknown as LedgerBackend;
  return { backend, calls };
}

function fakeHub(answer: (body: Record<string, unknown>) => { status: number; text?: string; overlaps?: TeamOverlap[] } = () => ({ status: 200 })) {
  const posts: Record<string, unknown>[] = [], withdrawals: [string, string][] = [], secrets: string[] = [];
  let down = false;
  const transport: LedgerHubTransport = {
    async secret(name) { secrets.push(name); return "grh_fixture"; },
    async publish(_endpoint, body, token) {
      expect(token).toBe("grh_fixture");
      if (down) throw new Error("offline");
      const parsed = JSON.parse(body) as Record<string, unknown>;
      posts.push(parsed);
      const a = answer(parsed);
      return { status: a.status, text: a.text ?? "", member: a.status === 200 ? "alex" : null, overlaps: a.overlaps ?? [] };
    },
    async withdraw(_endpoint, repo, client) {
      if (down) throw new Error("offline");
      withdrawals.push([repo, client]);
      return { status: 204, text: "" };
    },
  };
  return { transport, posts, withdrawals, secrets, setDown: (v: boolean) => { down = v; } };
}

describe("Team hub sharing: the model", () => {
  let now = Date.UTC(2026, 10, 3, 9);
  beforeEach(() => {
    now = Date.UTC(2026, 10, 3, 9);
    settings.set("ledgerHubSharing", undefined);
    settings.set("ledgerHubComputer", COMPUTER);
    settings.set("teamHubEndpoint", HUB);
  });
  afterEach(() => {
    settings.set("ledgerHubSharing", undefined);
    settings.set("ledgerHubComputer", undefined);
    settings.set("teamHubEndpoint", undefined);
  });

  it("reads and sends nothing while sharing is off", async () => {
    const { backend, calls } = fakeBackend(() => ({ rev: 1, sessions: [item("S1")], unshared: [] }), () => 1);
    const hub = fakeHub();
    const sharing = new LedgerHubSharing(() => backend, hub.transport, () => now);
    sharing.start();
    await sharing.pass();
    expect(calls).toEqual([]);
    expect(hub.posts).toEqual([]);
    expect(hub.secrets).toEqual([]);
    expect(sharing.status).toEqual({ kind: "off" });
  });

  it("never shares demo data", async () => {
    const hub = fakeHub();
    const demo = { kind: "demo", call: vi.fn() } as unknown as LedgerBackend;
    const sharing = new LedgerHubSharing(() => demo, hub.transport, () => now);
    settings.set("ledgerHubSharing", true);
    await sharing.pass();
    expect(sharing.status).toEqual({ kind: "demo" });
    expect(hub.posts).toEqual([]);
  });

  it("posts what the core built, follows rev, refreshes, withdraws and shows overlaps", async () => {
    let rev = 1;
    let result: LedgerHubShareResult = { rev: 1, sessions: [item("S1"), item("S2", ["docs/a.md"])], unshared: [{ sessionId: "S3", reason: "no_remote" }] };
    const { backend, calls } = fakeBackend(() => result, () => rev);
    // like the hub, every answer carries all of this member's overlaps in the repository, whichever entry was sent
    const hub = fakeHub(() => ({ status: 200, overlaps: [overlap(["alex", `ledger/${COMPUTER}/S1`], ["sam", "ledger/f00dfeed/S9"], ["src/retry.ts"])] }));
    const sharing = new LedgerHubSharing(() => backend, hub.transport, () => now);
    settings.set("ledgerHubSharing", true);
    await sharing.pass();
    expect(hub.secrets).toEqual([`teamHub:${HUB}`]);
    expect(hub.posts).toEqual([presence("S1", ["src/retry.ts"]), presence("S2", ["docs/a.md"])]);
    expect(sharing.status).toEqual({ kind: "sharing", host: "hub.example.com", count: 2, unshared: 1, plain: false });
    expect(sharing.overlapsFor("S1")).toEqual([{ session: "S9", member: "sam", branch: "b", paths: ["src/retry.ts"] }]);
    expect(sharing.overlapsFor("S2")).toEqual([]);

    // the same rev: nothing is sent
    await sharing.pass();
    expect(hub.posts).toHaveLength(2);
    expect(calls.filter((m) => m === "hub_share")).toHaveLength(1);

    // S2 closed: its entry is withdrawn, S1 is not sent again
    rev = 2;
    result = { rev: 2, sessions: [item("S1")], unshared: [] };
    await sharing.pass();
    expect(hub.posts).toHaveLength(2);
    expect(hub.withdrawals).toEqual([["example.com/team/app", `ledger/${COMPUTER}/S2`]]);

    // every four minutes everything is sent again, which keeps it alive on the hub
    now += 240_000;
    await sharing.pass();
    expect(hub.posts).toHaveLength(3);

    // turning it off withdraws what is left and forgets the overlaps
    await sharing.setOn(false);
    expect(hub.withdrawals).toEqual([["example.com/team/app", `ledger/${COMPUTER}/S2`], ["example.com/team/app", `ledger/${COMPUTER}/S1`]]);
    expect(sharing.overlapsFor("S1")).toEqual([]);
    expect(sharing.status).toEqual({ kind: "off" });
  });

  it("goes quiet when the hub is unreachable and waits before trying again", async () => {
    const { backend } = fakeBackend(() => ({ rev: 1, sessions: [item("S1")], unshared: [] }), () => 1);
    const hub = fakeHub();
    hub.setDown(true);
    const sharing = new LedgerHubSharing(() => backend, hub.transport, () => now);
    settings.set("ledgerHubSharing", true);
    await sharing.pass();
    expect(sharing.status).toEqual({ kind: "unreachable", host: "hub.example.com" });
    hub.setDown(false);
    now += 10_000;
    await sharing.pass();
    expect(hub.posts).toEqual([]);
    now += 30_000;
    await sharing.pass();
    expect(hub.posts).toHaveLength(1);
    expect(sharing.status.kind).toBe("sharing");
  });

  it("sends the same sessions without ledger to a hub that predates it", async () => {
    const { backend } = fakeBackend(() => ({ rev: 1, sessions: [item("S1")], unshared: [] }), () => 1);
    const hub = fakeHub((body) => (body.ledger ? { status: 400, text: '{"error":{"code":"INVALID_ARGUMENT","message":"invalid JSON body: unknown field \\"ledger\\""}}' } : { status: 200 }));
    const sharing = new LedgerHubSharing(() => backend, hub.transport, () => now);
    settings.set("ledgerHubSharing", true);
    await sharing.pass();
    await sharing.pass();
    expect(hub.posts.map((p) => "ledger" in p)).toEqual([true, false]);
    expect(sharing.status).toEqual({ kind: "sharing", host: "hub.example.com", count: 1, unshared: 0, plain: true });
  });

  it("stops on a refused token and needs a connected hub", async () => {
    const { backend } = fakeBackend(() => ({ rev: 1, sessions: [item("S1")], unshared: [] }), () => 1);
    const hub = fakeHub(() => ({ status: 401 }));
    const sharing = new LedgerHubSharing(() => backend, hub.transport, () => now);
    settings.set("ledgerHubSharing", true);
    await sharing.pass();
    expect(sharing.status).toEqual({ kind: "rejected", host: "hub.example.com" });
    now += 60_000;
    await sharing.pass();
    expect(hub.posts).toHaveLength(1);
    settings.set("teamHubEndpoint", undefined);
    now += 600_000;
    await sharing.pass();
    expect(sharing.status).toEqual({ kind: "noHub" });
  });
});
