import { ipc } from "@/shared/api";
import type { RemoteRepo } from "@/entities/git";
import { t } from "@/shared/i18n";
import { collaborationRepoURL, type InboxItem } from "./collaboration";
import { send, sendRaw, date } from "./hosting";
import type { ReviewAccess } from "./review";

export type IssueScope = "open" | "closed" | "all";
const current = (c: ReviewAccess) => {
  if (c.stillCurrent?.() === false)
    throw new Error(
      t("The repository or account changed. Reopen this action."),
    );
};
interface IssueRecord {
  number?: number;
  iid?: number;
  title: string;
  body?: string;
  description?: string;
  html_url?: string;
  web_url?: string;
  state: string;
  updated_at?: string;
  user?: { login?: string };
  author?: { username?: string };
  pull_request?: unknown;
}
export const workspaceIssue = (i: IssueRecord): InboxItem => ({
  id: `issue-${i.number ?? i.iid}`,
  kind: "issue",
  number: i.number ?? i.iid ?? 0,
  title: i.title,
  body: i.body ?? i.description ?? "",
  url: i.html_url ?? i.web_url ?? "",
  state: i.state,
  updated: date(i.updated_at),
  author: i.user?.login ?? i.author?.username ?? "",
  unread: false,
});
export async function issuePage(
  c: ReviewAccess,
  scope: IssueScope,
  search = "",
  page = 1,
): Promise<{ items: InboxItem[]; more: boolean }> {
  current(c);
  const n = Math.max(1, Math.floor(page));
  if (c.target.provider === "github" && search.trim()) {
    const text = search.trim().replace(/["\\]/g, " ");
    const q = `repo:${c.target.path} is:issue ${scope === "all" ? "" : `is:${scope}`} "${text}"`;
    const result = await send<{ items: IssueRecord[]; total_count: number }>(
      c.target.provider,
      `${c.apiBase}/search/issues?${new URLSearchParams({ q, sort: "updated", order: "desc", per_page: "30", page: String(n) })}`,
      c.token,
    );
    return {
      items: result.items.map(workspaceIssue),
      more: n * 30 < Math.min(result.total_count, 1000),
    };
  }
  // newest activity first; GitHub sorts with sort/direction, GitLab with order_by/sort (sort only takes asc or desc)
  const q = new URLSearchParams({
    state:
      c.target.provider === "gitlab" && scope === "open" ? "opened" : scope,
    per_page: "30",
    page: String(n),
    ...(c.target.provider === "gitlab"
      ? { order_by: "updated_at", sort: "desc" }
      : { sort: "updated", direction: "desc" }),
  });
  if (search.trim()) q.set("search", search.trim());
  const items = await send<IssueRecord[]>(
    c.target.provider,
    `${collaborationRepoURL(c)}/issues?${q}`,
    c.token,
  );
  return {
    items: items.filter((i) => !i.pull_request).map(workspaceIssue),
    more: items.length === 30,
  };
}
export async function saveWorkspaceIssue(
  c: ReviewAccess,
  title: string,
  body: string,
  number?: number,
): Promise<InboxItem> {
  current(c);
  if (!title.trim()) throw new Error(t("A title is required."));
  if (number !== undefined && (!Number.isSafeInteger(number) || number < 1))
    throw new Error(t("Invalid issue number."));
  const payload =
    c.target.provider === "github"
      ? { title: title.trim(), body }
      : { title: title.trim(), description: body };
  const result = await sendRaw(
    c.target.provider,
    `${collaborationRepoURL(c)}/issues${number ? `/${number}` : ""}`,
    c.token,
    number ? (c.target.provider === "github" ? "PATCH" : "PUT") : "POST",
    payload,
  );
  return workspaceIssue(JSON.parse(result));
}
export async function searchWorkspaceRepositories(
  c: ReviewAccess,
  search: string,
  page = 1,
): Promise<{ items: RemoteRepo[]; more: boolean }> {
  current(c);
  const n = Math.max(1, Math.floor(page));
  if (c.target.provider === "github") {
    if (search.trim()) {
      const r = await send<{
        items: {
          full_name: string;
          clone_url: string;
          private: boolean;
          description?: string;
        }[];
        total_count: number;
      }>(
        c.target.provider,
        `${c.apiBase}/search/repositories?${new URLSearchParams({ q: search.trim(), per_page: "30", page: String(n), sort: "updated" })}`,
        c.token,
      );
      return {
        items: r.items.map((i) => ({
          fullName: i.full_name,
          cloneURL: i.clone_url,
          isPrivate: i.private,
          summary: i.description ?? null,
        })),
        more: n * 30 < Math.min(1000, r.total_count),
      };
    }
    const r = await send<
      {
        full_name: string;
        clone_url: string;
        private: boolean;
        description?: string;
      }[]
    >(
      c.target.provider,
      `${c.apiBase}/user/repos?per_page=30&page=${n}&sort=updated`,
      c.token,
    );
    return {
      items: r.map((i) => ({
        fullName: i.full_name,
        cloneURL: i.clone_url,
        isPrivate: i.private,
        summary: i.description ?? null,
      })),
      more: r.length === 30,
    };
  }
  const q = new URLSearchParams({
    per_page: "30",
    page: String(n),
    order_by: "last_activity_at",
    sort: "desc",
  });
  if (search.trim()) q.set("search", search.trim());
  else q.set("membership", "true");
  const r = await send<
    {
      path_with_namespace: string;
      http_url_to_repo: string;
      visibility: string;
      description?: string;
    }[]
  >(c.target.provider, `${c.apiBase}/projects?${q}`, c.token);
  return {
    items: r.map((i) => ({
      fullName: i.path_with_namespace,
      cloneURL: i.http_url_to_repo,
      isPrivate: i.visibility !== "public",
      summary: i.description ?? null,
    })),
    more: r.length === 30,
  };
}

export function redactWorkspaceLog(body: string, token = ""): string {
  const plain = body.replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "");
  return (token ? plain.split(token).join("[redacted]") : plain)
    .replace(
      /-----BEGIN [A-Z ]*PRIVATE KEY(?: BLOCK)?-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY(?: BLOCK)?-----|$)/gi,
      "[redacted private key]",
    )
    .replace(
      /(\b[\w-]*(?:authorization|token|password|secret|api[_-]?key)\b["']?\s*[:=]\s*")(?:\\.|[^"\\\r\n])*(")/gi,
      "$1[redacted]$2",
    )
    .replace(
      /(\b[\w-]*(?:authorization|token|password|secret|api[_-]?key)\b["']?\s*[:=]\s*')(?:\\.|[^'\\\r\n])*(')/gi,
      "$1[redacted]$2",
    )
    .replace(
      /(\b[\w-]*(?:authorization|token|password|secret|api[_-]?key)\b["']?\s*[:=]\s*)(?:Bearer\s+)?[^"'\s,;}]+/gi,
      "$1[redacted]",
    )
    .replace(
      /\b(?:gh[pousr]_[A-Za-z0-9_]{16,}|github_pat_[A-Za-z0-9_]{16,}|glpat-[A-Za-z0-9_-]{12,})\b/g,
      "[redacted]",
    );
}
export async function workspaceJobLog(
  c: ReviewAccess,
  jobID: number,
): Promise<{ body: string; truncated: boolean }> {
  current(c);
  if (!Number.isSafeInteger(jobID) || jobID < 1)
    throw new Error(t("Invalid CI log request."));
  const result = await ipc.ciLog(
    c.target.provider,
    c.apiBase,
    c.target.path,
    jobID,
    c.token,
  );
  current(c);
  return {
    body: redactWorkspaceLog(result.body, c.token),
    truncated: result.truncated,
  };
}
