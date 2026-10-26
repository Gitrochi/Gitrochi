import type { ReviewAccess } from "./review";
import { send, sendRaw } from "./hosting";
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
  url: string;
  number: number;
  state: string;
  author: string;
  unread: boolean;
  readID?: string;
  origin: string;
}
interface RecordItem {
  id?: number | string;
  number?: number;
  iid?: number;
  title?: string;
  state?: string;
  html_url?: string;
  web_url?: string;
  target_url?: string;
  repository_url?: string;
  repository?: { full_name: string };
  subject?: { title: string; url?: string; type: string };
  user?: { login?: string };
  author?: { username?: string };
  unread?: boolean;
  project?: { path_with_namespace: string };
  target?: { iid?: number; title?: string };
  target_type?: string;
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
  return {
    id: `${kind}-${r.id ?? number}-${repository}`,
    origin: accountWorkOrigin(c, accountID),
    title: r.title ?? r.subject?.title ?? r.target?.title ?? "",
    repository,
    host,
    url: parsed.href,
    number: Number.isFinite(number) ? number : 0,
    state: r.state ?? r.target_type ?? r.subject?.type ?? "",
    author: r.user?.login ?? r.author?.username ?? "",
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
