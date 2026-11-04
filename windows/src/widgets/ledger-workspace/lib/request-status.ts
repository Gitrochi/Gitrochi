import type { LedgerSession } from "@/entities/ledger";

// The linked pull/merge request's state and checks, as the Ledger shows them next to the "#142" chip. These rules are
// pure; reading the server is LedgerRequestStatusStore's job. (macOS: Views/Ledger/LedgerRequestStatus.swift)

/** A session's request in the open repository's hosting project; `key` is one cache entry per request */
export interface LedgerRequestLink { host: string; path: string; number: number; key: string }

/** The request's state on the server; draft is an open request marked as a draft */
export type LedgerRequestState = "open" | "draft" | "merged" | "closed";

/** The checks on the request's head commit for one pill: failing ones when failing, pending ones when pending, else every check that passed */
export interface LedgerRequestChecks { state: "passing" | "failing" | "pending"; count: number }

export interface LedgerRequestStatus { state: LedgerRequestState; checks: LedgerRequestChecks | null }

/** The open repository, as far as the request rules need it */
export interface LedgerRequestRepository { path: string | null; project: string | null; target: { host: string; path: string } | null }

/** A value younger than this is shown as it is; the existing request views read again no sooner either */
export const REQUEST_STATUS_FRESH_MS = 60_000;

const folder = (p: string) => p.replace(/\\/g, "/").replace(/\/+$/, "").toLowerCase();

/**
 * The request the session links to, only when the session belongs to the open repository and the request lives in
 * that repository's hosting project: the session's linked folder is the repository (or, with no folder, its project is
 * the repository's), and the request's address is under the hosting project's path.
 */
export function ledgerRequestLink(s: LedgerSession, repo: LedgerRequestRepository): LedgerRequestLink | null {
  const pr = s.links.pr, target = repo.target;
  if (!pr || !(pr.number > 0) || !repo.path || !target?.host || !target.path) return null;
  const linked = s.links.repoPath ?? s.links.worktree ?? s.links.cwd;
  if (linked ? folder(linked) !== folder(repo.path) : !repo.project || s.project !== repo.project) return null;
  let url: URL;
  try { url = new URL(pr.url); } catch { return null; }
  const host = target.host.toLowerCase();
  if (!/^https?:$/.test(url.protocol) || (url.hostname.toLowerCase() !== host && pr.host.toLowerCase() !== host)) return null;
  let pathname = url.pathname;
  try { pathname = decodeURIComponent(pathname); } catch { /* left encoded */ }
  const project = `/${target.path.toLowerCase().replace(/^\/+|\/+$/g, "")}/`;
  if (!`${pathname.toLowerCase()}/`.startsWith(project)) return null;
  return { host: target.host, path: target.path, number: pr.number, key: `${host}/${target.path.toLowerCase()}#${pr.number}` };
}

/**
 * Passed, failing or pending over the checks' states (CI status words). Cancelled counts as failing, a job allowed to
 * fail as passed, and manual or unknown checks are left out. Null when nothing was reported.
 */
export function summarizeRequestChecks(checks: readonly { status: string; allowFailure?: boolean }[]): LedgerRequestChecks | null {
  let passed = 0, failed = 0, pending = 0;
  for (const c of checks) {
    if (c.status === "success" || c.status === "neutral" || c.status === "skipped") passed++;
    else if (c.status === "failed") { if (c.allowFailure) passed++; else failed++; }
    else if (c.status === "canceled") failed++;
    else if (c.status === "created" || c.status === "waiting" || c.status === "pending" || c.status === "running" || c.status === "scheduled") pending++;
  }
  if (failed) return { state: "failing", count: failed };
  if (pending) return { state: "pending", count: pending };
  return passed ? { state: "passing", count: passed } : null;
}

const finished = (s: LedgerSession) => s.status === "merged" || s.status === "closed" || s.status === "dropped";

/** "Request merged — mark merged?": the request is merged and the session is not finished. Nothing changes until a person picks the version. */
export const suggestsRequestMerged = (s: LedgerSession, status: LedgerRequestStatus | null | undefined) => status?.state === "merged" && !finished(s);

/**
 * How long to wait before reading again while the request is on screen: as often as the request checks panel while
 * checks run, every two minutes while it is open, never once it is merged or closed.
 */
export function requestPollMs(status: LedgerRequestStatus | null | undefined): number | null {
  if (!status || status.state === "merged" || status.state === "closed") return null;
  return status.checks?.state === "pending" ? 20_000 : 120_000;
}
