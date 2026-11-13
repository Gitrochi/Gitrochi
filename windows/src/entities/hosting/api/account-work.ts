import type { Provider } from "@/entities/git";
import type { ReviewAccess } from "./review";
import { avatarURL, send, sendRaw } from "./hosting";
import { t } from "@/shared/i18n";
export type AccountWorkKind =
  | "inbox"
  | "mine"
  | "assignedRequests"
  | "review"
  | "issues"
  | "myIssues";
export interface AccountWorkItem {
  id: string;
  title: string;
  repository: string;
  host: string;
  provider?: Provider;
  url: string;
  number: number;
  state: string;
  author: string;
  authorAvatarURL?: string | null;
  unread: boolean;
  readID?: string;
  origin: string;
  /** What the item is about; only requests and issues can open on a page of the app */
  kind: "request" | "issue" | "other";
  /** Why the server put it in the inbox, as it says it (`review_requested`, `mentioned` ...); empty in My work */
  reason: string;
  /** Who caused the notification, when the server names them */
  actor: string;
  actorUsername?: string;
  actorAvatarURL?: string | null;
  /** Seconds since 1970, or null when the list carries no time */
  updated: number | null;
  /** open, draft, merged or closed; empty when the list does not say */
  status: "open" | "draft" | "merged" | "closed" | "";
  body: string;
  /** A request's branches, when the list carries them */
  source: string;
  target: string;
}
interface WorkUser { login?: string; username?: string; name?: string; avatar_url?: string | null }
/** What a list says about its subject; a GitLab to-do carries it in `target` */
interface Subject {
  user?: WorkUser;
  author?: WorkUser;
  iid?: number;
  title?: string;
  state?: string;
  draft?: boolean;
  work_in_progress?: boolean;
  body?: string | null;
  description?: string | null;
  source_branch?: string;
  target_branch?: string;
}
interface RecordItem extends Subject {
  id?: number | string;
  number?: number;
  html_url?: string;
  web_url?: string;
  target_url?: string;
  repository_url?: string;
  repository?: { full_name: string };
  subject?: { title: string; url?: string; type: string };
  unread?: boolean;
  project?: { path_with_namespace: string };
  target?: Subject;
  target_type?: string;
  reason?: string;
  action_name?: string;
  updated_at?: string;
  created_at?: string;
}
const current = (c: ReviewAccess) => {
  if (c.stillCurrent?.() === false)
    throw new Error(
      t("The repository or account changed. Reopen this action."),
    );
};
/** Notifications belong to a specific account, even when several accounts share one server. */
export const accountWorkOrigin = (c: ReviewAccess, accountID = "") =>
  JSON.stringify([
    c.target.provider,
    c.apiBase.replace(/\/+$/, ""),
    c.me.toLowerCase(),
    accountID,
  ]);
const query = (kind: AccountWorkKind, me: string) =>
  kind === "mine"
    ? `is:pr is:open author:${me}`
    : kind === "assignedRequests"
      ? `is:pr is:open assignee:${me}`
      : kind === "review"
        ? `is:pr is:open review-requested:${me}`
        : kind === "myIssues"
          ? `is:issue is:open author:${me}`
          : `is:issue is:open assignee:${me}`;
function item(
  c: ReviewAccess,
  r: RecordItem,
  kind: AccountWorkKind,
  accountID: string,
): AccountWorkItem | null {
  const server = new URL(c.apiBase),
    host = c.target.host;
  let repository =
      r.repository?.full_name ?? r.project?.path_with_namespace ?? "",
    number =
      r.number ??
      r.iid ??
      r.target?.iid ??
      Number(r.subject?.url?.split("/").pop() ?? 0),
    url = r.html_url ?? r.web_url ?? r.target_url ?? "";
  if (c.target.provider === "github") {
    if (!repository && r.repository_url) {
      try {
        const p = new URL(r.repository_url);
        if (p.origin !== server.origin) return null;
        repository = p.pathname.replace(/^\/repos\//, "");
      } catch {
        return null;
      }
    }
    if (
      kind === "inbox" &&
      !["Issue", "PullRequest"].includes(r.subject?.type ?? "")
    )
      number = 0;
    if (!url && repository)
      url = `https://github.com/${repository}${number ? `/${r.subject?.type === "PullRequest" ? "pull" : "issues"}/${number}` : ""}`;
  }
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return null;
  }
  const expected = c.target.provider === "github" ? "github.com" : server.host;
  if (
    parsed.protocol !== server.protocol ||
    parsed.host !== expected ||
    parsed.username ||
    parsed.password
  )
    return null;
  if (!repository) {
    const base = server.pathname.replace(/\/api\/v4\/?$/, "");
    const path = parsed.pathname.startsWith(base)
      ? parsed.pathname.slice(base.length)
      : parsed.pathname;
    repository = path.split("/-/")[0].replace(/^\//, "");
  }
  if (!repository) return null;
  // What the list already carries about the subject; nothing more is requested for a row
  const type = r.subject?.type ?? r.target_type ?? "";
  const details: Subject = kind === "inbox" ? (r.target ?? {}) : r;
  const state = details.state ?? "";
  const author = details.user ?? details.author ?? r.user ?? r.author;
  const time = Date.parse(r.updated_at || r.created_at || "");
  return {
    kind:
      kind === "inbox"
        ? type === "PullRequest" || type === "MergeRequest"
          ? "request"
          : type === "Issue"
            ? "issue"
            : "other"
        : kind === "issues" || kind === "myIssues"
          ? "issue"
          : "request",
    reason: kind === "inbox" ? r.reason || r.action_name || "" : "",
    actor: kind === "inbox" ? r.author?.name || r.author?.username || "" : "",
    actorUsername: kind === "inbox" ? r.author?.username ?? r.author?.login ?? "" : "",
    actorAvatarURL: kind === "inbox" ? avatarURL(c, r.author?.avatar_url) : null,
    updated: Number.isFinite(time) ? time / 1000 : null,
    status:
      state === "open" || state === "opened"
        ? details.draft || details.work_in_progress
          ? "draft"
          : "open"
        : state === "merged" || state === "closed"
          ? state
          : "",
    body: details.body || details.description || "",
    source: details.source_branch ?? "",
    target: details.target_branch ?? "",
    id: `${kind}-${r.id ?? number}-${repository}`,
    origin: accountWorkOrigin(c, accountID),
    title: r.title ?? r.subject?.title ?? r.target?.title ?? "",
    repository,
    host,
    provider: c.target.provider,
    url: parsed.href,
    number: Number.isFinite(number) ? number : 0,
    state: r.state ?? r.target_type ?? r.subject?.type ?? "",
    author: author?.login ?? author?.username ?? "",
    authorAvatarURL: avatarURL(c, author?.avatar_url),
    unread: kind === "inbox" && (c.target.provider === "gitlab" || !!r.unread),
    readID: kind === "inbox" && r.id !== undefined ? String(r.id) : undefined,
  };
}
export async function accountWorkPage(
  c: ReviewAccess,
  kind: AccountWorkKind,
  page = 1,
  accountID = "",
): Promise<{ items: AccountWorkItem[]; more: boolean }> {
  current(c);
  const n = Math.max(1, Math.floor(page));
  let records: RecordItem[], more: boolean;
  if (c.target.provider === "github") {
    if (kind === "inbox") {
      records = await send<RecordItem[]>(
        "github",
        `${c.apiBase}/notifications?all=true&per_page=30&page=${n}`,
        c.token,
      );
      more = records.length === 30;
    } else {
      const r = await send<{ items: RecordItem[]; total_count: number }>(
        "github",
        `${c.apiBase}/search/issues?${new URLSearchParams({ q: query(kind, c.me), per_page: "30", page: String(n), sort: "updated", order: "desc" })}`,
        c.token,
      );
      records = r.items;
      more = n * 30 < Math.min(r.total_count, 1000);
    }
  } else {
    const p = new URLSearchParams({
      per_page: "30",
      page: String(n),
      state: kind === "inbox" ? "pending" : "opened",
      order_by: "updated_at",
      sort: "desc",
    });
    let path = "";
    if (kind === "inbox") path = "todos";
    else if (kind === "issues" || kind === "myIssues") {
      path = "issues";
      p.set("scope", kind === "issues" ? "assigned_to_me" : "created_by_me");
    } else {
      path = "merge_requests";
      p.set(
        "scope",
        kind === "mine"
          ? "created_by_me"
          : kind === "assignedRequests"
            ? "assigned_to_me"
            : "all",
      );
      if (kind === "review") p.set("reviewer_username", c.me);
    }
    records = await send<RecordItem[]>(
      "gitlab",
      `${c.apiBase}/${path}?${p}`,
      c.token,
    );
    more = records.length === 30;
  }
  current(c);
  return {
    items: records
      .map((r) => item(c, r, kind, accountID))
      .filter((r): r is AccountWorkItem => r !== null),
    more,
  };
}
export async function markAccountWorkRead(
  c: ReviewAccess,
  item: AccountWorkItem,
  accountID = "",
) {
  current(c);
  if (
    item.origin !== accountWorkOrigin(c, accountID) ||
    !item.readID ||
    item.host !== c.target.host ||
    !/^\d+$/.test(item.readID)
  )
    throw new Error(t("Invalid notification."));
  await sendRaw(
    c.target.provider,
    c.target.provider === "github"
      ? `${c.apiBase}/notifications/threads/${item.readID}`
      : `${c.apiBase}/todos/${item.readID}/mark_as_done`,
    c.token,
    c.target.provider === "github" ? "PATCH" : "POST",
  );
  current(c);
}
