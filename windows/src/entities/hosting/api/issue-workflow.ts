import { t } from "@/shared/i18n";
import type { ReviewAccess } from "./review";
import type { InboxItem, InboxDetail } from "./collaboration";
import { collaborationRepoURL } from "./collaboration";
import * as H from "./hosting";
export type InboxComment = InboxDetail["comments"][number];
export interface IssueLinkedRequest { id: string; number: number; title: string; url: string; state: string }
const check = (c: ReviewAccess) => { if (c.stillCurrent?.() === false) throw new Error(t("The repository or account changed. Reopen this action.")); };

/** Own comments are re-read before writes so another edit is never silently overwritten. */
export async function changeIssueComment(c: ReviewAccess, item: InboxItem, comment: InboxComment, body: string | null) {
  check(c);
  if (!/^[1-9]\d*$/.test(comment.id) || item.kind !== "issue" || item.isRequest || (body !== null && !body.trim())) throw new Error(t("Choose a loaded issue comment."));
  const repo = collaborationRepoURL(c), github = c.target.provider === "github";
  const url = github ? `${repo}/issues/comments/${comment.id}` : `${repo}/issues/${item.number}/notes/${comment.id}`;
  const fresh = await H.send<{ body: string; user?: { login: string }; author?: { username: string }; system?: boolean; issue_url?: string }>(c.target.provider, url, c.token);
  check(c);
  const author = fresh.user?.login ?? fresh.author?.username ?? "";
  if (fresh.system || author.toLowerCase() !== c.me.toLowerCase() || author.toLowerCase() !== comment.author.toLowerCase()) throw new Error(t("Only your own comments can be changed here."));
  if (fresh.body !== comment.body || (github && fresh.issue_url?.toLowerCase() !== `${repo}/issues/${item.number}`.toLowerCase())) throw new Error(t("This comment changed on the server. Refresh before saving."));
  await H.sendRaw(c.target.provider, url, c.token, body === null ? "DELETE" : github ? "PATCH" : "PUT", body === null ? undefined : { body });
  check(c);
}

/** GitHub timeline references and GitLab related MRs remain paginated and server scoped. */
export async function issueLinkedRequests(c: ReviewAccess, item: InboxItem, page = 1): Promise<{ items: IssueLinkedRequest[]; more: boolean }> {
  check(c);
  const github = c.target.provider === "github", base = collaborationRepoURL(c);
  const rows = await H.send<Record<string, unknown>[]>(c.target.provider, `${base}/issues/${item.number}/${github ? "timeline" : "related_merge_requests"}?per_page=30&page=${Math.max(1, page)}`, c.token);
  check(c);
  const items: IssueLinkedRequest[] = [];
  for (const row of rows) {
    const source = row.source as { issue?: Record<string, unknown> } | undefined;
    const value = github ? row.event === "cross-referenced" && source?.issue?.pull_request ? source.issue : null : row;
    if (!value) continue;
    const url = String(value.html_url ?? value.web_url ?? "");
    try {
      const parsed = new URL(url), origin = new URL(`https://${c.target.host}`);
      if (parsed.origin !== origin.origin || parsed.username || parsed.password || !(github ? /\/pull\/\d+\/?$/ : /\/(?:-\/)?merge_requests\/\d+\/?$/).test(parsed.pathname)) continue;
      const number = Number(github ? value.number : value.iid);
      if (!Number.isSafeInteger(number) || number <= 0 || items.some(item => item.id === url)) continue;
      items.push({ id: url, url, number, title: String(value.title ?? ""), state: String(value.state ?? "") });
    } catch { /* Invalid links never reach the browser. */ }
  }
  return { items, more: rows.length === 30 };
}
