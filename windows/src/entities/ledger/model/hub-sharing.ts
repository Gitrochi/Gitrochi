import { ipc } from "@/shared/api";
import { settings } from "@/shared/config";
import { Observable, publishTeamPresence, teamHubEndpoint, type TeamOverlap, type TeamPresenceAnswer, withdrawTeamPresence } from "@/shared/lib";
import type { LedgerBackend } from "../api/backend";
import { HUB_REFRESH_MS, HUB_TICK_MS, hubBackoff, hubOutcome, type HubOutcome, hubOverlaps, hubPlan, type HubPublished, type LedgerHubOverlap, type LedgerHubShareResult, newHubComputer } from "../lib/hub-share";
import { ledgerStore } from "./store";

/** The hub calls and the credential read; the app's own, replaced in tests and the self-test */
export interface LedgerHubTransport {
  secret(name: string): Promise<string | null>;
  publish(endpoint: string, body: string, token: string): Promise<TeamPresenceAnswer>;
  withdraw(endpoint: string, repo: string, client: string, token: string): Promise<{ status: number; text: string }>;
}

const appTransport: LedgerHubTransport = {
  secret: (name) => ipc.secretGet(name),
  publish: publishTeamPresence,
  withdraw: withdrawTeamPresence,
};

export type LedgerHubStatus =
  | { kind: "off" }
  /** the demo backend: its sessions are not real work */
  | { kind: "demo" }
  /** no hub connected under Work validation */
  | { kind: "noHub" }
  | { kind: "connecting"; host: string }
  | { kind: "sharing"; host: string; count: number; unshared: number; plain: boolean }
  | { kind: "unreachable"; host: string }
  | { kind: "rejected"; host: string };

export const LEDGER_HUB_SETTING = "ledgerHubSharing";
const COMPUTER_SETTING = "ledgerHubComputer";
/** Where the Team overlap evidence panel keeps the hub it connected to */
const ENDPOINT_SETTING = "teamHubEndpoint";
const HOLD_MS = 600_000;

/** The Credential Manager entry the Team overlap evidence panel keeps the hub's token in */
export const hubSecretName = (endpoint: string) => "teamHub:" + endpoint;

/**
 * Settings › Ledger › Team hub (docs/ledger/DESIGN.md §14 D4): off until a person turns it on. While it is on, this
 * computer's live Ledger sessions are shared with the team hub the app already reads under Work validation › Team
 * overlap evidence — its URL, and its token in the Credential Manager. What a session's entry holds is the core's
 * `hub_share`; this only sends it, when `rev` moves and every four minutes, and withdraws entries whose session closed or
 * is archived, or all of them when sharing is turned off. An unreachable hub only changes the status line, and passes
 * wait longer after each failure. The hub's answers carry overlaps with other members' sessions, which the inspector
 * shows under Touches. With it off nothing is read or sent. (macOS: Services/LedgerHubSharing.swift)
 */
export class LedgerHubSharing extends Observable {
  status: LedgerHubStatus = { kind: "off" };
  private overlapMap: Record<string, LedgerHubOverlap[]> = {};
  private timer: ReturnType<typeof setInterval> | null = null;
  private busy = false;
  /** moves when sharing stops or the hub changes, so a pass that was under way drops its results */
  private generation = 0;
  private endpoint: string | null = null;
  private token: string | null = null;
  private member: string | null = null;
  private published = new Map<string, HubPublished>();
  private overlapsByRepo = new Map<string, TeamOverlap[]>();
  /** the hub predates the `ledger` field */
  private plain = false;
  private lastRev = -1;
  private lastFull = 0;
  private failures = 0;
  private retryAt = 0;

  constructor(
    private readonly backend: () => LedgerBackend = () => ledgerStore(null).backend,
    private readonly transport: LedgerHubTransport = appTransport,
    private readonly now: () => number = Date.now,
  ) {
    super();
  }

  /** Whether a person turned sharing on (off by default) */
  get on(): boolean {
    return settings.get<boolean>(LEDGER_HUB_SETTING, false);
  }

  /** The connected hub's URL, when there is a valid one */
  get hubEndpoint(): string | null {
    const value = settings.get<string>(ENDPOINT_SETTING, "");
    if (!value) return null;
    try {
      return teamHubEndpoint(value);
    } catch {
      return null;
    }
  }

  /** Other computers' sessions touching what this computer's session touches */
  overlapsFor(sessionId: string): LedgerHubOverlap[] {
    return this.overlapMap[sessionId] ?? [];
  }

  /** The person turned sharing on or off */
  async setOn(on: boolean) {
    settings.set(LEDGER_HUB_SETTING, on || undefined);
    if (!on) return this.stop();
    const url = this.hubEndpoint;
    if (url) {
      if (url !== this.endpoint) this.reset();
      this.endpoint = url;
      this.token = await this.transport.secret(hubSecretName(url)).catch(() => null);
    }
    this.emit();
    this.start();
  }

  /** Follows the ledger while sharing is on; the app calls it at start */
  start() {
    if (!this.on) return;
    this.timer ??= setInterval(() => void this.pass(), HUB_TICK_MS);
    this.lastRev = -1;
    this.retryAt = 0;
    void this.pass();
  }

  /** Stops, and withdraws every entry this app reported (once; the hub forgets the rest within minutes) */
  async stop() {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
    const entries = [...this.published].sort(([a], [b]) => (a < b ? -1 : 1)), url = this.endpoint, token = this.token;
    const wasOff = this.status.kind === "off" && !entries.length;
    this.reset();
    this.setStatus({ kind: "off" });
    if (wasOff || !url || !token) return;
    for (const [client, entry] of entries) {
      try {
        await this.transport.withdraw(url, entry.repo, client, token);
      } catch {
        return;
      }
    }
  }

  /** One pass: read `rev`; when it moved or a refresh is due, report what changed and withdraw what went away */
  async pass() {
    if (!this.on || this.busy) return;
    this.busy = true;
    try {
      await this.share();
    } finally {
      this.busy = false;
    }
  }

  private async share() {
    const backend = this.backend();
    if (backend.kind !== "native") return this.setStatus({ kind: "demo" });
    const url = this.hubEndpoint;
    if (!url) {
      this.reset();
      return this.setStatus({ kind: "noHub" });
    }
    if (url !== this.endpoint) {
      this.reset();
      this.endpoint = url;
    }
    const mine = this.generation;
    const live = () => mine === this.generation && this.on;
    const host = new URL(url).host;
    const now = this.now();
    if (now < this.retryAt) return;
    if (this.token === null) {
      this.token = await this.transport.secret(hubSecretName(url)).catch(() => null);
      if (!live()) return;
    }
    const token = this.token;
    if (!token) {
      this.retryAt = now + HOLD_MS;
      return this.setStatus({ kind: "rejected", host });
    }
    if (this.status.kind !== "sharing" && this.status.kind !== "connecting") this.setStatus({ kind: "connecting", host });
    const full = now - this.lastFull >= HUB_REFRESH_MS;
    let rev: number, result: LedgerHubShareResult;
    try {
      rev = (await backend.call("rev", {})).rev;
      if (rev === this.lastRev && !full) return;
      result = await backend.call("hub_share", { client: this.computer() });
    } catch {
      return; // the ledger cannot be read now; the next pass tries again
    }
    if (!live()) return;
    const plan = hubPlan(result.sessions, this.published, this.plain, full);
    for (const post of plan.post) {
      let answer: TeamPresenceAnswer;
      try {
        answer = await this.transport.publish(url, post.body, token);
      } catch {
        return this.fail(host);
      }
      if (!live()) return;
      const outcome = hubOutcome(answer.status, answer.text);
      if (outcome === "accepted") {
        this.published.set(post.client, { repo: post.repo, body: post.body, accepted: true });
        this.member = answer.member ?? this.member;
        this.overlapsByRepo.set(post.repo, answer.overlaps);
      } else if (outcome === "skipped") {
        this.published.set(post.client, { repo: post.repo, body: post.body, accepted: false });
      } else if (outcome === "plainBodyNeeded") {
        // the next pass sends the same sessions without `ledger`
        this.plain = true;
        this.lastRev = -1;
        return;
      } else return this.refused(outcome, host, now);
    }
    for (const gone of plan.withdraw) {
      let outcome: HubOutcome;
      try {
        const answer = await this.transport.withdraw(url, gone.repo, gone.client, token);
        outcome = hubOutcome(answer.status, answer.text);
      } catch {
        return this.fail(host);
      }
      if (!live()) return;
      if (outcome === "accepted" || outcome === "skipped" || outcome === "plainBodyNeeded") {
        if (this.published.get(gone.client)?.repo === gone.repo) this.published.delete(gone.client);
      } else return this.refused(outcome, host, now);
    }
    const repos = new Set([...this.published.values()].map((p) => p.repo));
    for (const repo of [...this.overlapsByRepo.keys()]) if (!repos.has(repo)) this.overlapsByRepo.delete(repo);
    this.failures = 0;
    this.lastRev = rev;
    if (full) this.lastFull = now;
    const count = [...this.published.values()].filter((p) => p.accepted).length;
    this.setStatus({ kind: "sharing", host, count, unshared: result.unshared.filter((u) => u.reason === "no_remote").length, plain: this.plain });
    this.updateOverlaps();
  }

  private refused(outcome: HubOutcome, host: string, now: number) {
    if (outcome !== "rejected") return this.fail(host);
    this.token = null;
    this.retryAt = now + HOLD_MS;
    this.setStatus({ kind: "rejected", host });
  }

  private fail(host: string) {
    this.failures++;
    this.retryAt = this.now() + hubBackoff(this.failures);
    this.setStatus({ kind: "unreachable", host });
  }

  /** Forgets the hub's state: a new hub, or sharing turned off */
  private reset() {
    this.generation++;
    this.published = new Map();
    this.overlapsByRepo = new Map();
    this.member = null;
    this.plain = false;
    this.lastRev = -1;
    this.lastFull = 0;
    this.failures = 0;
    this.retryAt = 0;
    this.endpoint = null;
    this.token = null;
    if (Object.keys(this.overlapMap).length) {
      this.overlapMap = {};
      this.emit();
    }
  }

  private updateOverlaps() {
    const rows = [...this.overlapsByRepo.values()].flat();
    const next = this.member ? hubOverlaps(rows, this.member, this.computer()) : {};
    if (JSON.stringify(next) !== JSON.stringify(this.overlapMap)) {
      this.overlapMap = next;
      this.emit();
    }
  }

  private setStatus(next: LedgerHubStatus) {
    if (JSON.stringify(next) === JSON.stringify(this.status)) return;
    this.status = next;
    this.emit();
  }

  /** This computer's random name on the hub, made once */
  private computer(): string {
    const stored = settings.get<string>(COMPUTER_SETTING, "");
    if (stored) return stored;
    const name = newHubComputer();
    settings.set(COMPUTER_SETTING, name);
    return name;
  }
}

export const ledgerHubSharing = new LedgerHubSharing();
