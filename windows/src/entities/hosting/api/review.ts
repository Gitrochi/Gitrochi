import type { ChangeKind, FileChange, RepoTarget } from "@/entities/git";
import { t } from "@/shared/i18n";
import * as Hosting from "./hosting";
import { githubReviewThreads, resolveGithubThread } from "./review-threads";

export type ReviewLineSide = "LEFT" | "RIGHT";
export type ReviewVerdict = "COMMENT" | "APPROVE" | "REQUEST_CHANGES";
export interface ReviewLineAnchor {
  path: string; oldPath: string | null; line: number; side: ReviewLineSide;
  /** Context lines require both coordinates for GitLab. */
  oldLine?: number; newLine?: number;
  headSHA: string; baseSHA: string; startSHA: string;
}
export interface ReviewDraftComment {
  id: string; repositoryKey: string; number: number; anchor: ReviewLineAnchor; body: string;
}
export interface ReviewComment {
  id: string; author: string; body: string; date: number | null;
  path?: string; line?: number; side?: ReviewLineSide;
  threadID?: string; replyID?: number; resolvable?: boolean; resolved?: boolean;
  kind: "comment" | "approved" | "changesRequested" | "system";
}
export interface ReviewFile {
  path: string; oldPath: string | null; kind: ChangeKind; additions: number; deletions: number; patch: string | null;
}
export interface ReviewState { approvedBy: string[]; changesRequestedBy: string[]; approvalsLeft: number | null; approvedByMe: boolean }
export interface ReviewRefs { headSHA: string; baseSHA: string; startSHA: string }
export interface PullRequestReview extends ReviewRefs {
  number: number; repositoryKey: string; comments: ReviewComment[]; files: ReviewFile[]; state: ReviewState; warnings: string[];
}
export interface ReviewAccess { target: RepoTarget; token: string; apiBase: string; me: string; stillCurrent?: () => boolean }
export const reviewRepositoryKey = (target: RepoTarget) => `${target.provider}:${target.host.toLowerCase()}/${target.path.toLowerCase()}`;
export const reviewFileChange = (f: ReviewFile): FileChange => ({ path: f.path, oldPath: f.oldPath, kind: f.kind, staged: false });
export const cleanReviewBody = (body: string) => body.replace(/\n?<!-- gitrochi-review:[^>]+ -->/g, "");
const staleMessage = () => t("This request changed. Refresh the diff and recreate comments on the current version before submitting.");
export class ReviewSubmissionError extends Error {
  constructor(message: string, readonly completedIDs: string[] = []) { super(message); }
}
interface GHUser { login: string }
interface GHComment { id: number; user?: GHUser | null; body?: string | null; created_at?: string }
interface GHLineComment extends GHComment { path?: string; line?: number | null; original_line?: number | null; side?: ReviewLineSide; in_reply_to_id?: number }
interface GHReview { id: number; user?: GHUser | null; body?: string | null; state: string; submitted_at?: string }
interface GHFile { filename: string; previous_filename?: string; status: string; additions: number; deletions: number; patch?: string }
interface GHRefs { head: { sha: string }; base: { sha: string } }
interface GLNote {
  id: number; author?: { username: string }; body: string; created_at?: string; system?: boolean; resolvable?: boolean; resolved?: boolean;
  position?: { new_path?: string; new_line?: number; old_path?: string; old_line?: number } | null;
}
interface GLDiscussion { id: string; individual_note?: boolean; notes: GLNote[] }
interface GLApprovals { approved_by?: { user: { username: string } }[]; approvals_left?: number }
interface GLChange { old_path: string; new_path: string; new_file?: boolean; deleted_file?: boolean; renamed_file?: boolean; diff?: string; collapsed?: boolean; too_large?: boolean }
interface GLRefs { sha?: string; diff_refs?: { head_sha: string; base_sha: string; start_sha: string } }
const repo = (c: ReviewAccess) => `${c.apiBase}/repos/${c.target.path}`;
const project = (c: ReviewAccess) => `${c.apiBase}/projects/${Hosting.projectID(c.target.path)}`;
const requestURL = (c: ReviewAccess, n: number) => c.target.provider === "github" ? `${repo(c)}/pulls/${n}` : `${project(c)}/merge_requests/${n}`;

/** Native HTTP bridge has no Link header; request successive pages until the first short page. */
async function pages<T>(c: ReviewAccess, url: string, maxPages = 1000): Promise<T[]> {
  const result: T[] = [];
  for (let page = 1; ; page++) {
    const batch = await Hosting.send<T[]>(c.target.provider, `${url}${url.includes("?") ? "&" : "?"}per_page=100&page=${page}`, c.token);
    result.push(...batch);
    if (batch.length < 100) return result;
    if (page >= maxPages && maxPages < 1000) return result;
    if (page >= maxPages) throw new Error(t("This request is too large to load completely. Open it in the browser."));
  }
}
const sameRefs = (a: ReviewRefs, b: ReviewRefs) => a.headSHA === b.headSHA && a.baseSHA === b.baseSHA && a.startSHA === b.startSHA;
const marker = (id: string) => `<!-- gitrochi-review:${id} -->`;
function fingerprint(content: string) {
  let hash = 14695981039346656037n;
  for (const byte of new TextEncoder().encode(content)) hash = BigInt.asUintN(64, (hash ^ BigInt(byte)) * 1099511628211n);
  return hash.toString(16);
}
function draftID(draft: ReviewDraftComment) {
  const a = draft.anchor;
  return `${draft.id}-${fingerprint(JSON.stringify([draft.repositoryKey, draft.number, draft.body.trim(), a.path, a.oldPath, a.line, a.side, a.oldLine ?? null, a.newLine ?? null, a.headSHA, a.baseSHA, a.startSHA]))}`;
}
export const reviewDraftMatches = (a: ReviewDraftComment, b: ReviewDraftComment) => draftID(a) === draftID(b);
function summaryID(refs: ReviewRefs, body: string, verdict: ReviewVerdict, drafts: ReviewDraftComment[]) {
  return `summary-${fingerprint(JSON.stringify([refs.headSHA, refs.baseSHA, refs.startSHA, verdict, body.trim(), drafts.map(draftID)]))}`;
}

export const ReviewAPI = {
  async refs(c: ReviewAccess, n: number): Promise<ReviewRefs> {
    if (c.target.provider === "github") {
      const r = await Hosting.send<GHRefs>("github", requestURL(c, n), c.token);
      return { headSHA: r.head.sha, baseSHA: r.base.sha, startSHA: r.base.sha };
    }
    const r = await Hosting.send<GLRefs>("gitlab", requestURL(c, n), c.token);
    const refs = r.diff_refs;
    if (!refs?.head_sha || !refs.base_sha || !refs.start_sha) throw new Error(t("The server has not prepared this diff yet. Refresh and try again."));
    return { headSHA: refs.head_sha, baseSHA: refs.base_sha, startSHA: refs.start_sha };
  },

  async load(c: ReviewAccess, n: number): Promise<PullRequestReview> {
    const refs = await ReviewAPI.refs(c, n);
    const review: PullRequestReview = { ...refs, number: n, repositoryKey: reviewRepositoryKey(c.target), comments: [], files: [], state: { approvedBy: [], changesRequestedBy: [], approvalsLeft: null, approvedByMe: false }, warnings: [] };
    if (c.target.provider === "github") {
      const [comments, lines, reviews, files] = await Promise.all([
        pages<GHComment>(c, `${repo(c)}/issues/${n}/comments`), pages<GHLineComment>(c, `${repo(c)}/pulls/${n}/comments`),
        pages<GHReview>(c, `${repo(c)}/pulls/${n}/reviews`), pages<GHFile>(c, `${repo(c)}/pulls/${n}/files`, 30),
      ]);
      review.comments.push(...comments.map((x): ReviewComment => ({ id: `c${x.id}`, author: x.user?.login ?? "", body: cleanReviewBody(x.body ?? ""), date: Hosting.date(x.created_at), kind: "comment" })));
      review.comments.push(...lines.map((x): ReviewComment => ({ id: `l${x.id}`, author: x.user?.login ?? "", body: cleanReviewBody(x.body ?? ""), date: Hosting.date(x.created_at), path: x.path, line: x.line ?? x.original_line ?? undefined, side: x.side, threadID: String(x.in_reply_to_id ?? x.id), replyID: x.in_reply_to_id ?? x.id, kind: "comment" })));
      try {
        const threads = await githubReviewThreads(c, n);
        for (const comment of review.comments) {
          const thread = comment.replyID ? threads.get(comment.replyID) : undefined;
          if (thread) { comment.threadID = thread.id; comment.resolvable = thread.isResolved ? thread.viewerCanUnresolve === true : thread.viewerCanResolve; comment.resolved = thread.isResolved; }
        }
      } catch { review.warnings.push(t("The server does not expose GitHub review threads. Use the browser for resolution.")); }
      const latest = new Map<string, string>();
      for (const r of reviews) {
        const who = r.user?.login ?? "";
        if (["APPROVED", "CHANGES_REQUESTED", "DISMISSED"].includes(r.state)) latest.set(who, r.state);
        const kind = r.state === "APPROVED" ? "approved" : r.state === "CHANGES_REQUESTED" ? "changesRequested" : "comment";
        const body = cleanReviewBody(r.body ?? "");
        if (kind === "comment" && !body) continue;
        review.comments.push({ id: `r${r.id}`, author: who, body, date: Hosting.date(r.submitted_at), kind });
      }
      review.state.approvedBy = [...latest].filter(([, s]) => s === "APPROVED").map(([w]) => w).sort();
      review.state.changesRequestedBy = [...latest].filter(([, s]) => s === "CHANGES_REQUESTED").map(([w]) => w).sort();
      review.state.approvedByMe = latest.get(c.me) === "APPROVED";
      review.files = files.map((f) => ({ path: f.filename, oldPath: f.previous_filename ?? null, kind: f.status === "added" ? "added" : f.status === "removed" ? "deleted" : f.status === "renamed" ? "renamed" : "modified", additions: f.additions, deletions: f.deletions, patch: f.patch ?? null }));
      if (files.length >= 3000) review.warnings.push(t("GitHub limits this response to 3,000 files. Open the request in the browser for the complete review."));
    } else {
      const [discussions, approvals, changes] = await Promise.all([
        pages<GLDiscussion>(c, `${project(c)}/merge_requests/${n}/discussions`),
        Hosting.send<GLApprovals>("gitlab", `${project(c)}/merge_requests/${n}/approvals`, c.token).catch(() => null),
        pages<GLChange>(c, `${project(c)}/merge_requests/${n}/diffs`),
      ]);
      review.comments = discussions.flatMap((d) => d.notes.map((x): ReviewComment => ({ id: `n${x.id}`, author: x.author?.username ?? "", body: cleanReviewBody(x.body), date: Hosting.date(x.created_at), path: x.position?.new_path ?? x.position?.old_path, line: x.position?.new_line ?? x.position?.old_line, side: x.position?.new_line != null ? "RIGHT" : "LEFT", threadID: d.individual_note ? undefined : d.id, resolvable: x.resolvable, resolved: x.resolved, kind: x.system ? "system" : "comment" })));
      review.state.approvedBy = (approvals?.approved_by ?? []).map((a) => a.user.username);
      review.state.approvalsLeft = approvals?.approvals_left ?? null;
      review.state.approvedByMe = review.state.approvedBy.includes(c.me);
      review.files = changes.map((x) => ({ path: x.new_path, oldPath: x.renamed_file ? x.old_path : null, kind: x.new_file ? "added" : x.deleted_file ? "deleted" : x.renamed_file ? "renamed" : "modified", additions: (x.diff ?? "").split("\n").filter((l) => l.startsWith("+")).length, deletions: (x.diff ?? "").split("\n").filter((l) => l.startsWith("-")).length, patch: x.too_large || x.collapsed ? null : x.diff || null }));
      if (changes.some((x) => x.too_large || x.collapsed)) review.warnings.push(t("Some diffs were omitted by the server. Open those files in the browser."));
    }
    if (!sameRefs(refs, await ReviewAPI.refs(c, n))) throw new ReviewSubmissionError(staleMessage());
    review.comments.sort((a, b) => (a.date ?? 0) - (b.date ?? 0));
    return review;
  },

  /** GitHub sends comments and verdict as one atomic review. GitLab posts threads sequentially. */
  async submit(c: ReviewAccess, n: number, expected: ReviewRefs, drafts: ReviewDraftComment[], body: string, verdict: ReviewVerdict, completed: (id: string) => void = () => {}) {
    if (c.target.provider === "gitlab" && verdict === "REQUEST_CHANGES") throw new Error(t("Request changes is only supported for GitHub reviews."));
    if (drafts.some((d) => d.repositoryKey !== reviewRepositoryKey(c.target) || d.number !== n || !sameRefs(d.anchor, expected))) throw new ReviewSubmissionError(staleMessage());
    if (drafts.some((d) => !d.body.trim() || d.anchor.line < 1)) throw new Error(t("Write a comment for every selected line before submitting."));
    if (!sameRefs(expected, await ReviewAPI.refs(c, n))) throw new ReviewSubmissionError(staleMessage());
    const done: string[] = [];
    const summary = summaryID(expected, body, verdict, c.target.provider === "github" ? drafts : []);
    if (c.target.provider === "github") {
      // A response can be lost after the server accepted a review. Reconcile before retrying it.
      const existing = await pages<GHReview>(c, `${repo(c)}/pulls/${n}/reviews`);
      if (!existing.some((r) => r.state === (verdict === "APPROVE" ? "APPROVED" : verdict === "REQUEST_CHANGES" ? "CHANGES_REQUESTED" : "COMMENTED") && r.body?.includes(marker(summary)))) {
        const payload: Record<string, unknown> = { commit_id: expected.headSHA, event: verdict, body: `${body.trim()}\n${marker(summary)}`.trim() };
        if (drafts.length) payload.comments = drafts.map((d) => ({ path: d.anchor.path, line: d.anchor.line, side: d.anchor.side, body: d.body.trim() }));
        await Hosting.sendRaw("github", `${repo(c)}/pulls/${n}/reviews`, c.token, "POST", payload);
      }
      drafts.forEach((d) => completed(d.id));
      return;
    }
    const discussions = await pages<GLDiscussion>(c, `${project(c)}/merge_requests/${n}/discussions`);
    const existingBodies = discussions.flatMap((d) => d.notes.map((note) => note.body));
    try {
      for (const draft of drafts) {
        if (!existingBodies.some((b) => b.includes(marker(draftID(draft))))) {
          const a = draft.anchor;
          const position: Record<string, unknown> = { position_type: "text", base_sha: a.baseSHA, start_sha: a.startSHA, head_sha: a.headSHA, old_path: a.oldPath ?? a.path, new_path: a.path };
          if (a.side === "LEFT") { position.old_line = a.line; if (a.newLine != null) position.new_line = a.newLine; }
          else { position.new_line = a.line; if (a.oldLine != null) position.old_line = a.oldLine; }
          await Hosting.sendRaw("gitlab", `${project(c)}/merge_requests/${n}/discussions`, c.token, "POST", { body: `${draft.body.trim()}\n${marker(draftID(draft))}`, position });
        }
        done.push(draft.id);
        completed(draft.id);
      }
      if (body.trim() && !existingBodies.some((b) => b.includes(marker(summary)))) await Hosting.sendRaw("gitlab", `${project(c)}/merge_requests/${n}/discussions`, c.token, "POST", { body: `${body.trim()}\n${marker(summary)}` });
      // Approval is a separate GitLab action, not a GitHub review verdict.
      if (verdict === "APPROVE") await Hosting.sendRaw("gitlab", `${project(c)}/merge_requests/${n}/approve`, c.token, "POST", { sha: expected.headSHA });
    } catch (e) {
      throw new ReviewSubmissionError(`${t("GitLab submits comments one at a time. Confirmed comments were removed from drafts; remaining drafts are kept and checked before retry.")}\n\n${e instanceof Error ? e.message : String(e)}`, done);
    }
  },
  comment: (c: ReviewAccess, n: number, body: string) => c.target.provider === "github" ? Hosting.sendRaw("github", `${repo(c)}/issues/${n}/comments`, c.token, "POST", { body }) : Hosting.sendRaw("gitlab", `${project(c)}/merge_requests/${n}/notes`, c.token, "POST", { body }),
  async approve(c: ReviewAccess, n: number, body: string) { await ReviewAPI.submit(c, n, await ReviewAPI.refs(c, n), [], body, "APPROVE"); },
  unapprove: (c: ReviewAccess, n: number) => Hosting.sendRaw("gitlab", `${project(c)}/merge_requests/${n}/unapprove`, c.token, "POST"),
  async requestChanges(c: ReviewAccess, n: number, body: string) { await ReviewAPI.submit(c, n, await ReviewAPI.refs(c, n), [], body, "REQUEST_CHANGES"); },
  reply(c: ReviewAccess, n: number, comment: ReviewComment, body: string) {
    if (c.target.provider === "github") return Hosting.sendRaw("github", `${repo(c)}/pulls/${n}/comments/${comment.replyID}/replies`, c.token, "POST", { body });
    return Hosting.sendRaw("gitlab", `${project(c)}/merge_requests/${n}/discussions/${encodeURIComponent(comment.threadID ?? "")}/notes`, c.token, "POST", { body });
  },
  resolve(c: ReviewAccess, n: number, threadID: string, resolved: boolean) {
    if (c.target.provider === "github") return resolveGithubThread(c, threadID, resolved);
    return Hosting.sendRaw("gitlab", `${project(c)}/merge_requests/${n}/discussions/${encodeURIComponent(threadID)}`, c.token, "PUT", { resolved });
  },
};
