import { createRoot } from "react-dom/client";
import { RepoStore } from "@/entities/repo";
import { IssueDetail } from "@/widgets/inspector";
import { CreatePullRequestSheet } from "@/features/create-pull-request";
import { ipc } from "@/shared/api";
import { t } from "@/shared/i18n";
import { accounts, type InboxItem } from "@/entities/hosting";

/** Exercises real issue controls and PR prefilling against isolated server responses. */
export async function issueWorkflowSelfTest(): Promise<[boolean, string]> {
  const http = ipc.http, accountRevision = accounts.revision, host = document.createElement("div"); host.hidden = true; document.body.append(host);
  const root = createRoot(host), store = new RepoStore();
  const pause = () => new Promise(resolve => setTimeout(resolve, 35));
  const ensure = (value: unknown, message: string) => { if (!value) throw new Error(message); };
  const button = (text: string) => [...host.querySelectorAll<HTMLButtonElement>("button")].find(value => value.textContent?.trim() === t(text));
  const enter = (input: HTMLTextAreaElement, value: string) => { Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value")!.set!.call(input, value); input.dispatchEvent(new Event("input", { bubbles: true })); };
  let commentBody = "The **search** checklist is ready.", writes = 0;
  try {
    store.path = "C:/issue-workflow-fixture"; store.target = { provider: "github", host: "github.com", path: "sample-studio/desktop", remote: "origin" }; store.headHash = "fixture-head"; store.headBranch = "feature/search";
    const access = { target: store.target, token: "fixture", apiBase: "https://api.github.com", me: "reader" };
    Object.assign(store, { reviewAccess: async () => access, workspaceAccess: async () => access });
    const item: InboxItem = { id: "issue-7", kind: "issue", number: 7, title: "Improve workspace search", body: "## Search improvements\n\n- [ ] Faster navigation", state: "open", author: "reader", updated: null, unread: false, url: "https://github.com/sample-studio/desktop/issues/7" };
    ipc.http = async (method, url, _headers, body) => {
      let result: unknown;
      if (method === "PATCH") { writes++; commentBody = JSON.parse(body!).body; result = {}; }
      else if (method === "POST") { writes++; result = {}; }
      else if (method === "DELETE") { writes++; result = {}; }
      else if (url.includes("/timeline?")) result = [{ event: "cross-referenced", source: { issue: { number: 9, title: "Search implementation", state: "open", html_url: "https://github.com/sample-studio/desktop/pull/9", pull_request: {} } } }];
      else if (url.includes("/issues/comments/12")) result = { body: commentBody, user: { login: "reader" }, issue_url: "https://api.github.com/repos/sample-studio/desktop/issues/7" };
      else if (url.includes("/comments?")) result = [{ id: 12, body: commentBody, user: { login: "reader" }, created_at: "2026-10-28T09:00:00Z" }];
      else result = { title: item.title, body: item.body, state: "open" };
      return { status: 200, body: JSON.stringify(result) };
    };
    await store.openInboxItem(item);
    root.render(<IssueDetail store={store} detail={store.inboxDetail!}/>); await pause();
    button("Create branch")!.click(); await pause(); ensure(store.sheet?.kind === "newBranch", "Issue branch dialog missing"); store.sheet = null;
    button("Create pull request")!.click(); await pause(); ensure(store.newPullRequestDraft?.body.includes("Closes #7"), "Issue closing reference missing"); store.sheet = null;
    button("Load linked requests")!.click(); await pause(); ensure(host.textContent?.includes("Search implementation"), "Server-linked request missing");
    button("Quote reply")!.click(); await pause(); const composer = host.querySelector<HTMLTextAreaElement>(".issue-composer textarea")!; ensure(composer.value.includes("> The **search**"), "Quote reply missing");
    button("Preview")!.click(); await pause(); ensure(host.querySelector(".issue-comment-preview strong")?.textContent === "search", "Comment preview missing"); button("Write")!.click(); await pause(); ensure(composer.value.includes("@reader"), "Preview lost the draft");
    const quoted = composer.value;
    accounts.revision++; store.changed(); await pause();
    ensure(host.querySelector<HTMLTextAreaElement>(".issue-composer textarea")?.value === quoted, "Credential refresh discarded the comment draft");
    accounts.revision = accountRevision;
    button("Edit")!.click(); await pause(); const edit = host.querySelector<HTMLTextAreaElement>(`textarea[aria-label="${t("Edit comment")}"]`)!; enter(edit, "Updated **search** checklist"); await pause(); button("Save comment")!.click(); await pause(); await pause(); ensure(writes === 1 && commentBody.includes("Updated"), "Own comment edit failed");
    root.render(<IssueDetail store={store} detail={store.inboxDetail!}/>); await pause(); button("Delete")!.click(); await pause(); ensure(store.confirm?.title === t("Delete comment?"), "Delete confirmation missing"); store.confirm = null; ensure(writes === 1, "Cancelled deletion wrote to the server");
    store.defaultBaseBranch = async () => "main"; store.pullRequestBaseCandidates = () => ["main"];
    root.render(<CreatePullRequestSheet store={store} close={() => {}}/>); await pause(); ensure(host.querySelector<HTMLTextAreaElement>("textarea")?.value.includes("Closes #7"), "PR editor lost the issue reference");
    return [true, "issue branch/PR handoff, linked requests, comment timestamps/quote/preview/edit and delete cancellation"];
  } catch (error) { return [false, error instanceof Error ? error.message : String(error)]; }
  finally { root.unmount(); host.remove(); ipc.http = http; accounts.revision = accountRevision; }
}
