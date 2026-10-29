import type { ReactNode } from "react";
import { createRoot } from "react-dom/client";
import { ai } from "@/entities/ai";
import { parseDiff, type PushReviewPlan } from "@/entities/git";
import { accounts, type PullRequestReview, type ReviewAccess, reviewRepositoryKey } from "@/entities/hosting";
import { RepoStore } from "@/entities/repo";
import { AskChangesSheet } from "@/features/ask-changes";
import { PushReviewSheet } from "@/features/push-review";
import { ipc } from "@/shared/api";
import { t } from "@/shared/i18n";
import { Inspector } from "@/widgets/inspector";

const pause = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));
async function until(test: () => boolean, timeout = 2500) {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    if (test()) return true;
    await pause(20);
  }
  return false;
}

/** 실제 화면과 이벤트를 거치되 AI·호스팅·Git은 가짜로 대체해 외부 계정이나 저장소를 건드리지 않는다. */
export async function reviewWorkflowsSelfTest(): Promise<[boolean, string]> {
  const original = { run: ipc.run, http: ipc.http, problem: ai.problem, complete: ai.complete, providerFor: ai.providerFor, environment: accounts.gitEnvironment };
  const savedDrafts = localStorage.getItem("gitrochi.reviewDrafts.v1");
  const host = document.createElement("div");
  host.hidden = true;
  host.dataset.selftest = "review-workflows";
  document.body.append(host);
  let root = createRoot(host);
  const mount = async (view: ReactNode) => { root.render(view); await pause(25); };
  const resetMount = async () => { root.unmount(); host.replaceChildren(); root = createRoot(host); await pause(10); };
  const button = (label: string) => [...host.querySelectorAll<HTMLButtonElement>("button")].find((element) => element.textContent?.trim() === t(label));
  const enter = (element: HTMLTextAreaElement, value: string) => {
    // React가 설치한 인스턴스 추적기를 우회해 실제 입력 이벤트와 같은 변경을 전달한다.
    Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value")!.set!.call(element, value);
    element.dispatchEvent(new Event("input", { bubbles: true }));
  };
  const ensure = (condition: boolean, detail: string) => { if (!condition) throw new Error(detail); };
  const details: string[] = [];
  const sha = "a".repeat(40), old = "b".repeat(40);
  const patch = "diff --git a/source.ts b/source.ts\n--- a/source.ts\n+++ b/source.ts\n@@ -1 +1 @@\n-before\n+after\n";
  const fixturePath = "C:/gitrochi-review-selftest-fixture";
  const stores: RepoStore[] = [];
  let aiCalls = 0, sentPrompt = "";
  const writes: { url: string; payload: Record<string, unknown> }[] = [];
  try {
    // 모든 외부 호출을 막는다. 예상 밖 호출도 실제 백엔드로 넘기지 않는다.
    ipc.run = async () => ({ status: 0, stdout: sha + "\n", stderr: "" });
    ipc.http = async (method, url, _headers, body) => {
      if (method !== "GET") { writes.push({ url, payload: body ? JSON.parse(body) as Record<string, unknown> : {} }); return { status: 200, body: "{}" }; }
      return { status: 200, body: JSON.stringify(url.includes("/reviews?") ? [] : { head: { sha }, base: { sha: old } }) };
    };
    ai.problem = () => null;
    ai.providerFor = () => "compatible";
    ai.complete = async (_system, prompt) => { aiCalls++; sentPrompt = prompt; return "SELFTEST_AI_ANSWER: inspect the supplied change."; };
    accounts.gitEnvironment = async () => ({});

    const questions = new RepoStore(); stores.push(questions);
    questions.path = fixturePath; questions.headHash = sha;
    questions.diffSource = { kind: "working", change: { path: "source.ts", oldPath: null, staged: true, kind: "modified" } };
    questions.diff = parseDiff(patch);
    await questions.openChangeQuestion();
    await mount(<AskChangesSheet store={questions} close={() => { questions.sheet = null; questions.changed(); }} />);
    ensure(await until(() => !!host.querySelector("details pre") && !!button("Send question")), "AI question preview did not mount");
    ensure(aiCalls === 0 && host.querySelector("details pre")!.textContent!.includes("+after"), "Opening the preview called AI or omitted the selected change");
    questions.diff = parseDiff(patch.replace("+after", "+later-selection"));
    const questionInput = host.querySelector<HTMLTextAreaElement>(`textarea[aria-label="${t("Question about this snapshot")}"]`);
    ensure(!!questionInput, "Question input is missing");
    enter(questionInput!, "What risks are visible in this change?");
    ensure(await until(() => button("Send question")?.disabled === false), "Typing did not enable Send question");
    button("Send question")!.click();
    ensure(await until(() => host.textContent?.includes("SELFTEST_AI_ANSWER") === true), "AI answer was not rendered");
    ensure(aiCalls === 1 && sentPrompt.includes("+after") && !sentPrompt.includes("later-selection"), "Send did not use exactly the previewed snapshot");
    details.push("AI: preview before request, input/Send, frozen snapshot and answer rendered");
    await resetMount();

    const access: ReviewAccess = { target: { provider: "github", host: "github.example.invalid", path: "selftest/review", remote: "origin" }, token: "selftest", apiBase: "https://github.example.invalid/api", me: "selftest" };
    const review: PullRequestReview = { number: 7, repositoryKey: reviewRepositoryKey(access.target), headSHA: sha, baseSHA: old, startSHA: old,
      files: [{ path: "source.ts", oldPath: null, kind: "modified", additions: 1, deletions: 1, patch: "@@ -1 +1 @@\n-before\n+after" }], comments: [], warnings: [],
      state: { approvedBy: [], changesRequestedBy: [], approvalsLeft: null, approvedByMe: false } };
    const reviews = new RepoStore(); stores.push(reviews);
    reviews.path = fixturePath; reviews.target = access.target; reviews.selection = { kind: "pullRequest", number: 7 }; reviews.review = review;
    reviews.pullRequests = [{ number: 7, title: "Self-test review", author: "selftest", source: "topic", target: "main", url: "https://github.example.invalid/selftest/review/pull/7", isDraft: false, updated: null, body: "", headSHA: sha, fromFork: false }];
    reviews.reviewDrafts = [];
    const accessStore = reviews as unknown as { reviewAccess(): Promise<ReviewAccess> };
    accessStore.reviewAccess = async () => access;
    reviews.loadReview = async () => { reviews.review = review; reviews.changed(); };
    reviews.diffSource = { kind: "review", number: 7, change: { path: "source.ts", oldPath: null, staged: false, kind: "modified" }, patch: review.files[0].patch! };
    reviews.addReviewDraft(7, "source.ts", 1, "LEFT");
    reviews.addReviewDraft(7, "source.ts", 1, "RIGHT");
    await mount(<Inspector store={reviews} />);
    const activePanel = () => host.querySelector<HTMLElement>('[role="tabpanel"]:not([hidden])');
    const lineInputs = () => [...(activePanel()?.querySelectorAll<HTMLTextAreaElement>(`textarea[aria-label="${t("Line comment")}"]`) ?? [])];
    ensure(await until(() => lineInputs().length === 2), "Pending PR line comment editors did not mount");
    enter(lineInputs()[0], "SELFTEST_REVIEW_COMMENT: cover the previous behavior.");
    ensure(await until(() => reviews.reviewDrafts[0]?.body.includes("SELFTEST_REVIEW_COMMENT") === true), "Editing a pending comment did not update the store");
    const remove = [...activePanel()!.querySelectorAll<HTMLButtonElement>("button")].filter((element) => element.dataset.tip === t("Remove draft"));
    ensure(remove.length === 2, "Remove draft buttons are missing");
    remove[1].click();
    ensure(await until(() => lineInputs().length === 1 && reviews.reviewDrafts.length === 1), "Removing a pending comment did not update the UI");
    host.querySelector<HTMLButtonElement>("#request-tab-files")!.click();
    ensure(await until(() => activePanel()?.id === "request-panel-files" && lineInputs().length === 1 && lineInputs()[0].value.includes("SELFTEST_REVIEW_COMMENT")), "The Files tab lost the edited pending line comment");
    host.querySelector<HTMLButtonElement>("#request-tab-conversation")!.click();
    ensure(await until(() => activePanel()?.id === "request-panel-conversation" && lineInputs().length === 1 && lineInputs()[0].value.includes("SELFTEST_REVIEW_COMMENT")), "The Conversation tab lost the edited pending line comment");
    ensure(button("Submit review")?.disabled === false, "Submit review is not enabled for the pending comment");
    button("Submit review")!.click();
    ensure(await until(() => writes.some((write) => write.url.endsWith("/pulls/7/reviews")) && reviews.reviewDrafts.length === 0), "Submitting the review did not call the fake hosting service and clear confirmed drafts");
    const reviewWrite = writes.find((write) => write.url.endsWith("/pulls/7/reviews"))!.payload;
    const comments = reviewWrite.comments as { path: string; line: number; side: string; body: string }[];
    ensure(reviewWrite.event === "COMMENT" && reviewWrite.commit_id === sha && comments.length === 1 && comments[0].path === "source.ts" && comments[0].side === "LEFT" && comments[0].line === 1 && comments[0].body.includes("SELFTEST_REVIEW_COMMENT"), "Submitted review payload does not match the edited retained line comment");
    details.push("PR: active-tab editors, retained drafts across tabs, remove button and batch submit preserve line/side/body");
    await resetMount();

    const pushes = new RepoStore(); stores.push(pushes);
    pushes.path = fixturePath; pushes.headBranch = "topic"; pushes.headHash = sha;
    const plan: PushReviewPlan = { repo: fixturePath, branch: "topic", sourceOID: sha, remote: "reviewed-origin", destination: "refs/heads/reviewed-topic", pushURL: "ssh://git@selftest.example.invalid/selftest/review.git", displayURL: "ssh://git@selftest.example.invalid/selftest/review.git",
      destinationOID: old, force: false, setUpstream: false, stamp: "selftest-stable-plan", author: "Self Test <selftest@example.invalid>", account: "selftest", credentialAccount: "selftest", preflight: { result: "OK", checks: [] },
      commits: [{ sha, author: "Self Test", email: "selftest@example.invalid", subject: "Self-test change" }], commitCount: 1, files: ["source.ts"], fileCount: 1, fileScope: "changes", comparisonBase: old };
    const pushStore = pushes as unknown as { buildPushReview(branch: string, force: boolean, remoteOverride?: string): Promise<PushReviewPlan> };
    pushStore.buildPushReview = async () => plan;
    const pushCalls: string[][] = [];
    pushes.run = async (_label, args) => { pushCalls.push([...args]); return true; };
    pushes.loadPullRequests = async () => {};
    pushes.ci.refreshBadges = async () => {};
    let cancelled: boolean | null = null;
    void pushes.requestPushReview("topic").then((result) => { cancelled = result; });
    await mount(<PushReviewSheet key="cancel" store={pushes} branch="topic" force={false} close={() => { pushes.sheet = null; pushes.changed(); }} />);
    ensure(await until(() => button("Confirm push")?.disabled === false), "Push review did not display its prepared plan");
    ensure(pushCalls.length === 0, "Push executed before confirmation");
    button("Cancel")!.click();
    ensure(await until(() => cancelled === false), "Cancel did not resume the push caller as false");
    ensure(pushCalls.length === 0, "Cancel executed a push");
    await resetMount();
    let confirmed: boolean | null = null;
    void pushes.requestPushReview("topic").then((result) => { confirmed = result; });
    await mount(<PushReviewSheet key="confirm" store={pushes} branch="topic" force={false} close={() => { pushes.sheet = null; pushes.changed(); }} />);
    ensure(await until(() => button("Confirm push")?.disabled === false), "Second push review did not become ready");
    button("Confirm push")!.click();
    ensure(await until(() => confirmed === true), "Confirm did not resume the push caller as true");
    ensure(pushCalls.length === 1 && pushCalls[0].at(-2) === "reviewed-origin" && pushCalls[0].at(-1) === `${sha}:refs/heads/reviewed-topic`, "Confirm did not execute exactly one push to the reviewed destination");
    details.push("Push: Cancel sends nothing; Confirm sends once to frozen remote/refspec");
    return [true, details.join("; ")];
  } catch (error) {
    return [false, [...details, error instanceof Error ? error.message : String(error)].join("; ")];
  } finally {
    root.unmount();
    for (const store of stores) { store.cancelChangeQuestion(); store.cancelPushReview(); }
    await pause(25);
    ipc.run = original.run; ipc.http = original.http;
    ai.problem = original.problem; ai.complete = original.complete; ai.providerFor = original.providerFor;
    accounts.gitEnvironment = original.environment;
    if (savedDrafts === null) localStorage.removeItem("gitrochi.reviewDrafts.v1"); else localStorage.setItem("gitrochi.reviewDrafts.v1", savedDrafts);
    host.remove();
  }
}
