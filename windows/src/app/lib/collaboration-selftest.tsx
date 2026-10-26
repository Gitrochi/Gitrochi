import { createRoot } from "react-dom/client";
import { RepoStore } from "@/entities/repo";
import { Inspector } from "@/widgets/inspector";
import { CollaborationInboxSheet } from "@/features/collaboration-inbox";
import { t } from "@/shared/i18n";
const pause = () => new Promise<void>((done) => setTimeout(done, 60));
/** 실제 React 폼과 버튼을 사용하며 서버 호출은 전부 가짜로 대체한다. */
export async function collaborationSelfTest(): Promise<[boolean, string]> {
  const host = document.createElement("div"); host.hidden = true; host.dataset.selftest = "collaboration"; document.body.append(host);
  let root = createRoot(host); const store = new RepoStore();
  const button = (label: string) => [...host.querySelectorAll<HTMLButtonElement>("button")].find((b) => b.textContent?.trim() === t(label));
  const ensure = (value: unknown, detail: string) => { if (!value) throw new Error(detail); };
  let saves = 0, comments = 0, reads = 0;
  try {
    store.target = { provider: "github", host: "github.example.invalid", path: "fixture/repo", remote: "origin" };
    store.selection = { kind: "pullRequest", number: 1 };
    store.pullRequests = [{ number: 1, title: "Fixture request", body: "Body", author: "fixture", source: "work", target: "main", headSHA: "a".repeat(40), isDraft: false, updated: null, url: "https://github.example.invalid/fixture/repo/pull/1", fromFork: false }];
    store.loadReview = async () => {};
    store.loadRequestLifecycle = async () => {
      store.requestLifecycle = { number: 1, title: "Fixture request", body: "Body", base: "main", headSHA: "a".repeat(40), state: "open", reviewers: [], methods: ["merge", "squash"], blockers: [], checks: "clean", policy: "Fixture policy", canEdit: true, canRebase: false, squashRequired: false }; store.changed();
    };
    store.saveRequestMetadata = async () => { saves++; return true; };
    root.render(<Inspector store={store} />); await pause();
    button("Merge…")?.click(); await pause(); ensure(store.confirm?.title.includes("1"), "Merge did not ask to confirm the reviewed request");
    store.confirm = null; button("Edit request…")?.click(); await pause(); ensure(host.querySelector("input")?.value === "Fixture request", "Request metadata did not populate");
    button("Save request")?.click(); await pause(); ensure(saves === 1, "Request metadata save did not execute");
    root.unmount(); host.replaceChildren(); root = createRoot(host);
    const item = { id: "mention-9", kind: "mention" as const, number: 1, title: "Fixture mention", body: "Mention body", url: "https://github.example.invalid/fixture/repo/pull/1", author: "fixture", state: "PullRequest", updated: null, unread: true, readID: "9", isRequest: true };
    store.loadInbox = async (kind = "mention") => { store.inboxKind = kind; store.inboxItems = [item]; store.changed(); };
    store.openInboxItem = async () => { store.inboxDetail = { item, comments: [{ id: "one", author: "fixture", body: "Conversation" }].map((x) => ({ ...x, date: null })), more: false, page: 1 }; store.changed(); };
    store.inboxAction = async (_item, kind) => { if (kind === "read") reads++; else if (kind === "comment") comments++; return true; };
    root.render(<CollaborationInboxSheet store={store} close={() => {}} />); await pause();
    const row = host.querySelector<HTMLButtonElement>(".inbox-item"); row?.click(); await pause();
    ensure(host.textContent?.includes("Conversation"), "Inbox detail did not display the conversation"); button("Mark as read")?.click(); await pause(); ensure(reads === 1, "Read action did not execute");
    const textarea = host.querySelector<HTMLTextAreaElement>("textarea")!;
    Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value")!.set!.call(textarea, "Fixture reply"); textarea.dispatchEvent(new Event("input", { bubbles: true })); await pause();
    button("Comment")?.click(); await pause(); ensure(comments === 1, "Inbox reply did not execute");
    return [true, "PR merge confirmation, metadata form, inbox conversation/read/reply passed"];
  } catch (error) { return [false, error instanceof Error ? error.message : String(error)]; }
  finally { root.unmount(); host.remove(); }
}
