import type { PullRequest } from "@/entities/git";
import { t } from "@/shared/i18n";
import { type ReviewAccess } from "./review";
import * as H from "./hosting";

export type RequestScope = "open" | "closed" | "merged" | "mine" | "reviewRequested";
export interface RequestQuery { scope: RequestScope; search: string; page: number }
export interface RequestPage { items: PullRequest[]; more: boolean; warning?: string }
export type MergeMethod = "merge" | "squash" | "rebase";
export interface RequestLifecycle {
  number: number; headSHA: string; state: "open" | "closed" | "merged"; title: string; body: string; base: string;
  reviewers: string[]; methods: MergeMethod[]; blockers: string[]; checks: string; policy: string;
  canEdit: boolean; canRebase: boolean; squashRequired: boolean;
}
export interface InboxItem {
  id: string; kind: "issue" | "review" | "mention"; number: number; title: string; url: string; body: string;
  state: string; updated: number | null; author: string; unread: boolean; readID?: string; readProvider?: "github" | "gitlab"; isRequest?: boolean;
}
export interface InboxDetail { item: InboxItem; comments: { id: string; author: string; body: string; date: number | null }[]; more: boolean; page: number }
export const collaborationRepoURL = (c: ReviewAccess) => c.target.provider === "github" ? `${c.apiBase}/repos/${c.target.path}` : `${c.apiBase}/projects/${H.projectID(c.target.path)}`;
const reqURL = (c: ReviewAccess, n: number) => `${collaborationRepoURL(c)}/${c.target.provider === "github" ? "pulls" : "merge_requests"}/${n}`;
interface User { login?: string; username?: string; id?: number }
interface GHPull { number: number; title: string; body?: string; user: User; head: { ref: string; sha: string; repo?: { full_name: string } }; base: { ref: string }; html_url: string; draft?: boolean; updated_at?: string; merged?: boolean; merged_at?: string | null; state: string; requested_reviewers?: User[]; mergeable?: boolean | null; mergeable_state?: string; maintainer_can_modify?: boolean }
interface GLMerge { iid: number; title: string; description?: string; author: User; source_branch: string; target_branch: string; web_url: string; sha: string; draft?: boolean; updated_at?: string; state: string; reviewers?: User[]; detailed_merge_status?: string; merge_status?: string; head_pipeline?: { status: string }; user?: { can_merge?: boolean }; source_project_id?: number; target_project_id?: number }
const ghPull = (c: ReviewAccess, p: GHPull): PullRequest => ({ number: p.number, title: p.title, body: p.body ?? "", author: p.user.login ?? "", source: p.head.ref, target: p.base.ref, headSHA: p.head.sha, isDraft: !!p.draft, updated: H.date(p.updated_at), url: p.html_url, fromFork: p.head.repo?.full_name.toLowerCase() !== c.target.path.toLowerCase() });
const glPull = (p: GLMerge): PullRequest => ({ number: p.iid, title: p.title, body: p.description ?? "", author: p.author.username ?? "", source: p.source_branch, target: p.target_branch, headSHA: p.sha, isDraft: !!p.draft, updated: H.date(p.updated_at), url: p.web_url, fromFork: p.source_project_id !== p.target_project_id });
const ensureCurrent = (c: ReviewAccess) => { if (c.stillCurrent?.() === false) throw new Error(t("The repository or account changed. Reopen this action.")); };
const send = <T>(c: ReviewAccess, url: string, method = "GET", body?: unknown) => { ensureCurrent(c); return H.send<T>(c.target.provider, url, c.token, method, body); };
const raw = (c: ReviewAccess, url: string, method: string, body?: unknown) => { ensureCurrent(c); return H.sendRaw(c.target.provider, url, c.token, method, body); };

/**
 * One page of the request list. GitHub's list endpoint carries everything the list shows, so no request is read on its own;
 * it has no author, reviewer or text filter, so those narrow each loaded page here (the search API is rate limited,
 * lags behind and is refused for some repositories). macOS: CollaborationAPI.requests.
 */
export async function requestPage(c: ReviewAccess, query: RequestQuery): Promise<RequestPage> {
  const page = Math.max(1, Math.floor(query.page)), search = query.search.trim();
  if (c.target.provider === "github") {
    const closed = query.scope === "closed" || query.scope === "merged";
    const filtered = closed || query.scope === "mine" || query.scope === "reviewRequested" || !!search;
    const perPage = filtered ? 100 : 30;
    const list = await send<GHPull[]>(c, `${collaborationRepoURL(c)}/pulls?${new URLSearchParams({ state: closed ? "closed" : "open", sort: "updated", direction: "desc", per_page: String(perPage), page: String(page) })}`);
    return { items: list.filter((p) => matchesQuery(c, p, query.scope, search)).map((p) => ghPull(c, p)), more: list.length === perPage, warning: search ? t("Search filters loaded pages. Load more to search older items.") : undefined };
  }
  const p = new URLSearchParams({ state: query.scope === "closed" ? "closed" : query.scope === "merged" ? "merged" : "opened", per_page: "30", page: String(page), order_by: "updated_at", sort: "desc", scope: "all" });
  if (search) p.set("search", search);
  if (query.scope === "mine") p.set("author_username", c.me);
  if (query.scope === "reviewRequested") p.set("reviewer_username", c.me);
  const items = await send<GLMerge[]>(c, `${collaborationRepoURL(c)}/merge_requests?${p}`);
  return { items: items.map(glPull), more: items.length === 30 };
}
function matchesQuery(c: ReviewAccess, p: GHPull, scope: RequestScope, search: string) {
  const me = (name?: string) => (name ?? "").toLowerCase() === c.me.toLowerCase();
  if (scope === "merged" && !p.merged_at) return false;
  if (scope === "closed" && p.merged_at) return false;
  if (scope === "mine" && !me(p.user.login)) return false;
  if (scope === "reviewRequested" && !(p.requested_reviewers ?? []).some((u) => me(u.login))) return false;
  if (!search) return true;
  const needle = search.toLowerCase();
  return [p.title, `#${p.number}`, p.user.login ?? "", p.head.ref].some((s) => s.toLowerCase().includes(needle));
}

/** 병합 권한·프로젝트 정책·최신 커밋 상태를 확인한다. 알 수 없는 상태는 병합하지 않는다. */
export async function requestLifecycle(c: ReviewAccess, n: number): Promise<RequestLifecycle> {
  if (c.target.provider === "github") {
    const [p, r] = await Promise.all([send<GHPull>(c, reqURL(c, n)), send<{ allow_merge_commit?: boolean; allow_squash_merge?: boolean; allow_rebase_merge?: boolean; permissions?: { push?: boolean; maintain?: boolean; admin?: boolean } }>(c, collaborationRepoURL(c))]);
    const blockers: string[] = [];
    if (p.state !== "open" || p.merged) blockers.push(t("This request is not open."));
    if (p.draft) blockers.push(t("Draft requests cannot be merged."));
    if (!r.permissions?.push && !r.permissions?.maintain && !r.permissions?.admin) blockers.push(t("The account cannot merge this request."));
    if (p.mergeable !== true || !["clean", "has_hooks"].includes(p.mergeable_state ?? "")) blockers.push(t("Merge readiness: {0}. Refresh after checks, approvals and conflicts are resolved.", p.mergeable_state ?? "unknown"));
    const [status, checks] = await Promise.all([
      send<{ state: string; total_count: number }>(c, `${collaborationRepoURL(c)}/commits/${encodeURIComponent(p.head.sha)}/status`).catch(() => null),
      send<{ total_count: number; check_runs: { status: string; conclusion?: string | null }[] }>(c, `${collaborationRepoURL(c)}/commits/${encodeURIComponent(p.head.sha)}/check-runs?filter=latest&per_page=100`).catch(() => null),
    ]);
    let ci = t("No checks reported");
    if (!status || !checks || !Array.isArray(checks.check_runs) || !Number.isFinite(checks.total_count)) blockers.push(t("The server could not verify check results."));
    else {
      const jobs = checks.check_runs, complete = jobs.filter((j) => j.status === "completed" && ["success", "neutral", "skipped"].includes(j.conclusion ?? "")).length;
      ci = t("Checks: {0}/{1} complete; commit status: {2}", complete, checks.total_count, status.total_count ? status.state : t("none"));
      if (checks.total_count > 100 || complete < jobs.length || (status.total_count > 0 && status.state !== "success")) blockers.push(t("Checks are incomplete, pending or failed. Refresh before merging."));
    }
    const methods: MergeMethod[] = [];
    if (r.allow_merge_commit) methods.push("merge"); if (r.allow_squash_merge) methods.push("squash"); if (r.allow_rebase_merge) methods.push("rebase");
    if (!methods.length) blockers.push(t("The server did not allow a merge method."));
    return { number: n, headSHA: p.head.sha, state: p.merged ? "merged" : p.state === "open" ? "open" : "closed", title: p.title, body: p.body ?? "", base: p.base.ref, reviewers: (p.requested_reviewers ?? []).map((u) => u.login ?? ""), methods, blockers, checks: `${p.mergeable_state ?? "unknown"} · ${ci}`, policy: t("GitHub branch rules, required checks and approvals are enforced again by the server."), canEdit: p.user.login === c.me || !!r.permissions?.push, canRebase: false, squashRequired: false };
  }
  const [p, r, approvals] = await Promise.all([send<GLMerge>(c, reqURL(c, n) + "?with_merge_status_recheck=true"), send<{ merge_method?: string; squash_option?: string; only_allow_merge_if_pipeline_succeeds?: boolean; only_allow_merge_if_all_discussions_are_resolved?: boolean }>(c, collaborationRepoURL(c)), send<{ approvals_left?: number; approved?: boolean }>(c, reqURL(c, n) + "/approvals").catch(() => null)]);
  const status = p.detailed_merge_status ?? p.merge_status ?? "unknown", blockers: string[] = [];
  if (p.state !== "opened") blockers.push(t("This request is not open."));
  if (p.draft) blockers.push(t("Draft requests cannot be merged."));
  if (p.user?.can_merge !== true) blockers.push(t("The account cannot merge this request."));
  if (status !== "mergeable" && status !== "can_be_merged") blockers.push(t("Merge readiness: {0}. Refresh after checks, approvals and conflicts are resolved.", status));
  if (approvals?.approvals_left == null && approvals?.approved !== true) blockers.push(t("The server could not verify approval requirements."));
  else if ((approvals?.approvals_left ?? 0) > 0) blockers.push(t("More approvals are required."));
  const pipeline = p.head_pipeline?.status ?? "none";
  if (r.only_allow_merge_if_pipeline_succeeds && pipeline !== "success") blockers.push(t("The required pipeline has not succeeded."));
  const methods: MergeMethod[] = r.squash_option === "always" ? ["squash"] : r.squash_option === "never" ? ["merge"] : ["merge", "squash"];
  return { number: n, headSHA: p.sha, state: p.state === "merged" ? "merged" : p.state === "opened" ? "open" : "closed", title: p.title, body: p.description ?? "", base: p.target_branch, reviewers: (p.reviewers ?? []).map((u) => u.username ?? ""), methods, blockers, checks: `${status} · pipeline: ${pipeline}`, policy: t("GitLab project merge method: {0}. The server enforces approval, discussion and pipeline rules.", r.merge_method ?? "unknown"), canEdit: p.author.username === c.me || p.user?.can_merge === true, canRebase: p.state === "opened" && p.user?.can_merge === true, squashRequired: r.squash_option === "always" };
}
export async function mergeRequest(c: ReviewAccess, expected: RequestLifecycle, method: MergeMethod) {
  const fresh = await requestLifecycle(c, expected.number);
  if (!expected.headSHA || fresh.headSHA !== expected.headSHA || fresh.base !== expected.base) throw new Error(t("The request changed. Refresh and review the latest commit before merging."));
  if (fresh.blockers.length || !fresh.methods.includes(method)) throw new Error(fresh.blockers.join("\n") || t("The server did not allow a merge method."));
  if (c.target.provider === "github") {
    const result = await send<{ merged: boolean; message?: string }>(c, reqURL(c, expected.number) + "/merge", "PUT", { sha: expected.headSHA, merge_method: method });
    if (!result.merged) throw new Error(result.message ?? t("The server did not merge this request."));
  } else {
    if (method === "rebase") throw new Error(t("GitLab rebases separately and uses the project merge method."));
    const result = await send<GLMerge>(c, reqURL(c, expected.number) + "/merge", "PUT", { sha: expected.headSHA, squash: method === "squash", should_remove_source_branch: false });
    if (result.state !== "merged") throw new Error(t("The server did not merge this request."));
  }
}
export const rebaseRequest = (c: ReviewAccess, n: number) => raw(c, reqURL(c, n) + "/rebase", "PUT", { skip_ci: false });
export const setRequestState = (c: ReviewAccess, n: number, open: boolean) => raw(c, reqURL(c, n), c.target.provider === "github" ? "PATCH" : "PUT", c.target.provider === "github" ? { state: open ? "open" : "closed" } : { state_event: open ? "reopen" : "close" });
export const updateRequest = (c: ReviewAccess, n: number, title: string, body: string, base: string) => raw(c, reqURL(c, n), c.target.provider === "github" ? "PATCH" : "PUT", c.target.provider === "github" ? { title, body, base } : { title, description: body, target_branch: base });
export async function setReviewers(c: ReviewAccess, n: number, names: string[], previous: string[]) {
  const unique = [...new Set(names.map((n) => n.trim()).filter(Boolean))];
  if (c.target.provider === "github") {
    const add = unique.filter((n) => !previous.includes(n)), remove = previous.filter((n) => !unique.includes(n));
    if (add.length) await raw(c, reqURL(c, n) + "/requested_reviewers", "POST", { reviewers: add });
    if (remove.length) await raw(c, reqURL(c, n) + "/requested_reviewers", "DELETE", { reviewers: remove });
  } else {
    const users = await Promise.all(unique.map(async (name) => {
      const list = await send<User[]>(c, `${c.apiBase}/users?username=${encodeURIComponent(name)}`), user = list.find((u) => u.username?.toLowerCase() === name.toLowerCase());
      if (!user?.id) throw new Error(t("Reviewer not found: {0}", name)); return user.id;
    }));
    await raw(c, reqURL(c, n), "PUT", { reviewer_ids: users.length ? users : [0] });
  }
}

interface Issue { number?: number; iid?: number; title: string; body?: string; description?: string; html_url?: string; web_url?: string; state: string; updated_at?: string; user?: User; author?: User; pull_request?: unknown }
const issue = (i: Issue): InboxItem => ({ id: `issue-${i.number ?? i.iid}`, kind: "issue", number: i.number ?? i.iid ?? 0, title: i.title, url: i.html_url ?? i.web_url ?? "", body: i.body ?? i.description ?? "", state: i.state, updated: H.date(i.updated_at), author: i.user?.login ?? i.author?.username ?? "", unread: false });
/** 현재 저장소·연결된 계정 범위의 할 일. GitLab 멘션은 서버 To-do를 사용한다. */
export async function inboxPage(c: ReviewAccess, kind: InboxItem["kind"], page = 1): Promise<{ items: InboxItem[]; more: boolean }> {
  if (kind === "review") {
    const p = await requestPage(c, { scope: "reviewRequested", search: "", page });
    return { items: p.items.map((p) => ({ id: `review-${p.number}`, kind, number: p.number, title: p.title, url: p.url, body: p.body, author: p.author, updated: p.updated, state: "open", unread: false, isRequest: true })), more: p.more };
  }
  if (kind === "issue") {
    const url = c.target.provider === "github" ? `${collaborationRepoURL(c)}/issues?state=open&assignee=${encodeURIComponent(c.me)}&per_page=30&page=${page}` : `${collaborationRepoURL(c)}/issues?state=opened&assignee_username=${encodeURIComponent(c.me)}&per_page=30&page=${page}`;
    const list = await send<Issue[]>(c, url);
    return { items: list.filter((i) => !i.pull_request).map(issue), more: list.length === 30 };
  }
  if (c.target.provider === "github") {
    const list = await send<{ id: string; reason: string; unread: boolean; updated_at?: string; subject: { title: string; url?: string; type: string }; repository: { full_name: string } }[]>(c, `${collaborationRepoURL(c)}/notifications?all=true&per_page=30&page=${page}`);
    return { items: list.filter((n) => ["mention", "team_mention", "review_requested"].includes(n.reason) && ["Issue", "PullRequest"].includes(n.subject.type) && /^\d+$/.test(n.subject.url?.split("/").pop() ?? "")).map((n) => {
      const number = Number(n.subject.url?.split("/").pop());
      return { id: `mention-${n.id}`, kind, number, title: n.subject.title, body: "", url: `https://${c.target.host}/${c.target.path}/${n.subject.type === "PullRequest" ? "pull" : "issues"}/${number}`, state: n.subject.type, updated: H.date(n.updated_at), author: "", unread: n.unread, readID: n.id, readProvider: "github", isRequest: n.subject.type === "PullRequest" };
    }), more: list.length === 30 };
  }
  const list = await send<{ id: number; action_name: string; state: string; target_type: string; target_url: string; body: string; updated_at?: string; author: User; project: { path_with_namespace: string }; target: { iid: number; title: string; description?: string; state: string } }[]>(c, `${c.apiBase}/todos?state=pending&per_page=30&page=${page}`);
  return { items: list.filter((x) => x.project?.path_with_namespace?.toLowerCase() === c.target.path.toLowerCase() && ["Issue", "MergeRequest"].includes(x.target_type) && ["mentioned", "directly_addressed", "review_requested"].includes(x.action_name)).map((x) => ({ id: `mention-${x.id}`, kind, number: x.target.iid, title: x.target.title, body: x.body, url: x.target_url, state: x.target_type, updated: H.date(x.updated_at), author: x.author.username ?? "", unread: true, readID: String(x.id), readProvider: "gitlab", isRequest: x.target_type === "MergeRequest" })), more: list.length === 30 };
}
export async function inboxDetail(c: ReviewAccess, item: InboxItem, page = 1): Promise<InboxDetail> {
  const isRequest = !!item.isRequest || item.kind === "review" || /PullRequest|MergeRequest/.test(item.state);
  const base = `${collaborationRepoURL(c)}/${c.target.provider === "github" ? "issues" : isRequest ? "merge_requests" : "issues"}/${item.number}`;
  const detail = await send<Issue>(c, isRequest && c.target.provider === "github" ? reqURL(c, item.number) : base);
  const list = await send<{ id: number; body: string; user?: User; author?: User; created_at?: string }[]>(c, `${base}/${c.target.provider === "github" ? "comments" : "notes"}?per_page=30&page=${page}`);
  return { item: { ...item, title: detail.title, body: detail.body ?? detail.description ?? "", state: detail.state }, page, more: list.length === 30, comments: list.map((n) => ({ id: String(n.id), body: n.body, author: n.user?.login ?? n.author?.username ?? "", date: H.date(n.created_at) })) };
}
export async function postInboxComment(c: ReviewAccess, item: InboxItem, body: string) {
  if (!body.trim()) return;
  const request = !!item.isRequest || item.kind === "review" || /PullRequest|MergeRequest/.test(item.state);
  const path = c.target.provider === "github" ? `issues/${item.number}/comments` : `${request ? "merge_requests" : "issues"}/${item.number}/notes`;
  await raw(c, `${collaborationRepoURL(c)}/${path}`, "POST", { body: body.trim() });
}
export const setIssueState = (c: ReviewAccess, item: InboxItem, open: boolean) => raw(c, `${collaborationRepoURL(c)}/issues/${item.number}`, c.target.provider === "github" ? "PATCH" : "PUT", c.target.provider === "github" ? { state: open ? "open" : "closed" } : { state_event: open ? "reopen" : "close" });
export const markInboxRead = (c: ReviewAccess, item: InboxItem) => item.readID ? raw(c, item.readProvider === "github" ? `${c.apiBase}/notifications/threads/${encodeURIComponent(item.readID)}` : `${c.apiBase}/todos/${encodeURIComponent(item.readID)}/mark_as_done`, item.readProvider === "github" ? "PATCH" : "POST") : Promise.resolve("");
