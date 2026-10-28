import type { ProjectTaskReference, RepoTarget } from "@/entities/git";
import type { InboxItem } from "../api/collaboration";

/** Issue handoffs stay on the current repository (macOS: Core/IssueWorkflow.swift). */
export function issueTaskReference(target: RepoTarget | null, item: Pick<InboxItem, "number" | "title" | "url" | "kind" | "isRequest">): ProjectTaskReference | null {
  if (!target || item.kind !== "issue" || item.isRequest || !Number.isSafeInteger(item.number) || item.number <= 0) return null;
  const canonical = `https://${target.host}/${target.path}/${target.provider === "gitlab" ? "-/" : ""}issues/${item.number}`;
  try { const url = new URL(item.url), expected = new URL(canonical); if (url.origin !== expected.origin || (target.provider === "github" ? url.pathname.replace(/\/$/, "").toLowerCase() !== expected.pathname.toLowerCase() : url.pathname.replace(/\/$/, "") !== expected.pathname) || url.username || url.password) return null; }
  catch { return null; }
  return { id: `issue:${target.provider}:${target.host}/${target.path}#${item.number}`, number: item.number, title: item.title, url: canonical, repository: target.path, host: target.host };
}
export function issueBranchName(task: ProjectTaskReference): string {
  const slug = task.title.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 60).replace(/-$/, "");
  return `feature/${task.number}-${slug || "issue"}`;
}
export function issueRequestBody(task: ProjectTaskReference): string { return `Closes #${task.number}\n\n${task.url}`; }
export function quoteIssueComment(author: string, body: string): string { return `@${author}\n\n${body.split(/\r?\n/).map(line => `> ${line}`).join("\n")}\n\n`; }
