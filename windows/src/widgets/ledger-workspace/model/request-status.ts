import { CIAPI, gitlabStatus } from "@/entities/ci";
import type { RepoTarget } from "@/entities/git";
import { requestState, type ReviewAccess } from "@/entities/hosting";
import { Observable } from "@/shared/lib";
import { type LedgerRequestChecks, type LedgerRequestLink, type LedgerRequestStatus, REQUEST_STATUS_FRESH_MS, summarizeRequestChecks } from "../lib/request-status";

/**
 * What the Ledger uses of the repository's tab to read a linked request: its folder, hosting project and account, and
 * the access its own request pages use. The repository store satisfies it as it is.
 */
export interface LedgerRequestHost {
  readonly path: string | null;
  readonly target: RepoTarget | null;
  readonly hostingAccount: { id: string } | null;
  workspaceAccess(): Promise<ReviewAccess | null>;
}

/**
 * The state and checks of requests linked to Ledger sessions, read through the repository's existing hosting access
 * (`requestState`, `CIAPI`): no other client and no token of its own. One cache for the app, so the Inbox and the
 * inspector share a read; it only reads, and never changes a Ledger status. (macOS: Store/LedgerRequestStatusStore.swift)
 */
export class LedgerRequestStatusStore extends Observable {
  private statuses = new Map<string, LedgerRequestStatus>();
  private readAt = new Map<string, number>();
  /** When a read last failed, so a server that refuses is not asked again sooner than a value would be */
  private failedAt = new Map<string, number>();
  private reading = new Set<string>();

  constructor(private readonly now: () => number = Date.now) {
    super();
  }

  status(link: LedgerRequestLink | null | undefined): LedgerRequestStatus | null {
    return link ? this.statuses.get(link.key) ?? null : null;
  }

  /** Reads the request unless a value younger than `maxAge` is cached; callers asking for one request at once share one read */
  async refresh(link: LedgerRequestLink, host: LedgerRequestHost, maxAge = REQUEST_STATUS_FRESH_MS): Promise<void> {
    const key = link.key, now = this.now(), target = host.target;
    if (now - (this.readAt.get(key) ?? -Infinity) < maxAge || now - (this.failedAt.get(key) ?? -Infinity) < REQUEST_STATUS_FRESH_MS) return;
    if (this.reading.has(key) || !target || target.host.toLowerCase() !== link.host.toLowerCase() || target.path.toLowerCase() !== link.path.toLowerCase()) return;
    this.reading.add(key);
    try {
      const c = await host.workspaceAccess().catch(() => null);
      if (!c) return;
      const request = await requestState(c, link.number);
      let checks: LedgerRequestChecks | null = null;
      try {
        if (c.target.provider === "gitlab") {
          // the head pipeline's jobs are the checks; a pipeline without jobs counts as one
          const pipeline = request.headPipeline;
          if (pipeline) {
            const jobs = await CIAPI.jobs(c, pipeline.id, pipeline.projectID);
            checks = summarizeRequestChecks(jobs.length ? jobs : [{ status: gitlabStatus(pipeline.status) }]);
          }
        } else if (request.headSHA) checks = summarizeRequestChecks((await CIAPI.requestChecks(c, request.headSHA)).checks);
      } catch { /* the state alone */ }
      if (c.stillCurrent?.() === false) return;
      const next: LedgerRequestStatus = { state: request.state === "open" && request.draft ? "draft" : request.state, checks };
      this.readAt.set(key, this.now());
      this.failedAt.delete(key);
      const old = this.statuses.get(key);
      if (old?.state === next.state && old.checks?.state === next.checks?.state && old.checks?.count === next.checks?.count) return;
      this.statuses.set(key, next);
      this.emit();
    } catch {
      this.failedAt.set(key, this.now());
    } finally {
      this.reading.delete(key);
    }
  }
}

/** The app's one cache */
export const ledgerRequestStatus = new LedgerRequestStatusStore();
