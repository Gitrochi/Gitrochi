import { createRoot } from "react-dom/client";
import { RepoPage } from "@/pages/repo";
import { accounts, type PullRequestReview, reviewRepositoryKey } from "@/entities/hosting";
import { RepoStore } from "@/entities/repo";
import { ipc } from "@/shared/api";
import { settings } from "@/shared/config";
import { t } from "@/shared/i18n";

const pause = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));
const until = async (test: () => boolean) => {
  const end = Date.now() + 2500;
  while (Date.now() < end) { if (test()) return true; await pause(20); }
  return false;
};

/** PR 파일 검토가 대화의 미전송 입력을 지우지 않는지 확인하며 실제 설정·계정·서버는 변경하지 않는다. */
export async function prConversationSelfTest(): Promise<[boolean, string]> {
  const original = { get: settings.get, set: settings.set, accounts: accounts.accounts, run: ipc.run, http: ipc.http };
  const host = document.createElement("div"); host.hidden = true; document.body.append(host);
  const root = createRoot(host);
  const memory = new Map<string, unknown>();
  const unexpected: string[] = [];
  const store = new RepoStore(), head = "a".repeat(40), base = "b".repeat(40);
  const button = (label: string) => [...host.querySelectorAll<HTMLButtonElement>("button")].find((item) => item.textContent?.trim() === t(label));
  const composer = () => host.querySelector<HTMLTextAreaElement>(`textarea[placeholder="${t("Comment · review feedback")}"]`);
  const titleInput = () => [...host.querySelectorAll("label")].find((label) => label.textContent?.startsWith(t("Title")))?.querySelector("input");
  const enter = (input: HTMLInputElement | HTMLTextAreaElement, value: string) => {
    const prototype = input instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    Object.getOwnPropertyDescriptor(prototype, "value")!.set!.call(input, value);
    input.dispatchEvent(new Event("input", { bubbles: true }));
  };
  try {
    settings.get = <T,>(key: string, fallback: T): T => (memory.has(key) ? memory.get(key) : fallback) as T;
    settings.set = (key, value) => { memory.set(key, value); };
    accounts.accounts = [];
    ipc.run = async () => { unexpected.push("process"); throw new Error("Fixture blocked process"); };
    ipc.http = async () => { unexpected.push("network"); throw new Error("Fixture blocked network"); };
    store.path = "C:/gitrochi-pr-conversation-fixture"; store.headHash = head; store.headBranch = "topic";
    store.target = { provider: "github", host: "github.example.invalid", path: "fixture/review", remote: "origin" };
    const pr = { number: 7, title: "Fixture review", author: "fixture", source: "topic", target: "main", url: "https://github.example.invalid/fixture/review/pull/7", isDraft: false, updated: null, body: "Fixture only", headSHA: head, fromFork: false };
    store.pullRequests = [pr, { ...pr, number: 8 }]; store.prState = { kind: "loaded" };
    const review: PullRequestReview = { number: 7, repositoryKey: reviewRepositoryKey(store.target), headSHA: head, baseSHA: base, startSHA: base, files: [{ path: "source.ts", oldPath: null, kind: "modified", additions: 1, deletions: 1, patch: "@@ -1 +1 @@\n-before\n+after" }], comments: [], warnings: [], state: { approvedBy: [], changesRequestedBy: [], approvalsLeft: null, approvedByMe: false } };
    store.review = review; store.reviewDrafts = [];
    store.loadPullRequests = async () => {};
    store.loadReview = async (number) => { store.review = { ...review, number }; store.changed(); };
    store.loadRequestLifecycle = async () => {};
    store.requestLifecycle = { number: 7, headSHA: head, state: "open", title: pr.title, body: pr.body, base: "main", reviewers: [], methods: ["merge"], blockers: [], checks: "Fixture only", policy: "Fixture only", canEdit: true, canRebase: false, squashRequired: false };
    store.selection = { kind: "pullRequest", number: 7 }; store.navigate("pullRequests", false);
    root.render(<RepoPage store={store} openSettings={() => { unexpected.push("settings"); }} />);
    if (!await until(() => !!composer() && !!button("Edit request…"))) return [false, "PR conversation did not mount"];
    const originalComposer = composer()!;
    enter(originalComposer, "Fixture unsent review comment");
    button("Edit request…")!.click();
    if (!await until(() => !!titleInput())) return [false, "Request metadata editor did not mount"];
    enter(titleInput()!, "Fixture unsaved title");
    await pause(25);
    for (let cycle = 0; cycle < 2; cycle++) {
      host.querySelector<HTMLElement>(".workspace-pr-detail .review-file")!.click();
      if (!await until(() => !!button("Back to conversation"))) return [false, "Review file did not open"];
      button("Back to conversation")!.click();
      if (!await until(() => composer()?.value === "Fixture unsent review comment" && titleInput()?.value === "Fixture unsaved title")) return [false, "Opening a review file discarded an unsent comment or metadata edit"];
      if (composer() !== originalComposer) return [false, "Conversation input was remounted when returning from a file"];
    }
    store.select({ kind: "pullRequest", number: 8 });
    if (!await until(() => composer()?.value === "" && !titleInput())) return [false, "Draft state leaked to another pull request"];
    return [unexpected.length === 0, JSON.stringify({ reviewRoundTrips: 2, commentRetained: true, metadataRetained: true, otherRequestReset: true, unexpected })];
  } finally {
    root.unmount(); await pause(25); host.remove();
    settings.get = original.get; settings.set = original.set; accounts.accounts = original.accounts;
    ipc.run = original.run; ipc.http = original.http;
  }
}
