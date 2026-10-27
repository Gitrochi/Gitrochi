import { hubSafeURL, type HubAccess, type HubProjectRow, type InboxItem } from "@/entities/hosting";
import { t } from "@/shared/i18n";
import { projectKind, projectRepository } from "./project-workspace";

/** Project items may belong to a different repository on the same authenticated server. */
export function projectConversationContext(access: HubAccess, row: HubProjectRow): { access: HubAccess; item: InboxItem } {
  const kind = projectKind(row), repository = projectRepository(row), number = row.number;
  const reject = () => { throw new Error(t("Select an issue or pull request from this server.")); };
  if (access.local || !["issue", "pullRequest"].includes(kind) || !repository || !Number.isSafeInteger(number) || !number || number < 1 || !hubSafeURL(access, row.url)) return reject();
  const url = new URL(row.url), request = kind === "pullRequest";
  const path = "/" + repository.split("/").map(encodeURIComponent).join("/");
  const suffix = access.target.provider === "github" ? `/${request ? "pull" : "issues"}/${number}` : `/-/${request ? "merge_requests" : "issues"}/${number}`;
  if (url.hostname.toLocaleLowerCase() !== access.target.host.toLocaleLowerCase() || url.pathname.replace(/\/$/, "") !== path + suffix || repository.split("/").some((part) => !part || part === "." || part === "..")) return reject();
  return {
    access: { ...access, target: { ...access.target, path: repository } },
    item: { id: row.id, kind: request ? "review" : "issue", isRequest: request, number, title: row.title, body: row.body, url: row.url, state: row.state ?? "", updated: row.updatedAt ? Date.parse(row.updatedAt) / 1000 || null : null, author: row.author ?? "", unread: false },
  };
}
