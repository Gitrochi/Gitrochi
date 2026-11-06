import { createRoot } from "react-dom/client";
import { RepoPage } from "@/pages/repo";
import { accounts, type PullRequestReview, reviewRepositoryKey, workStateTitle } from "@/entities/hosting";
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

/**
 * The Pull requests page: the list column and its one Hide list / Show list control kept across tabs, the one-line
 * composer that is disabled while empty, Split disabled with its reason on a narrow diff, and the unsent comment and
 * edited fields that survive tab switches and file review. No real setting, account or server is touched.
 */
export async function prConversationSelfTest(): Promise<[boolean, string]> {
  const original = { get: settings.get, set: settings.set, accounts: accounts.accounts, run: ipc.run, http: ipc.http };
  const host = document.createElement("div"); // wide enough for the one-row Changed files header beside the page list and the request list
  host.style.cssText = "position:fixed;left:-10000px;top:0;width:1480px;height:800px"; document.body.append(host);
  const root = createRoot(host);
  const memory = new Map<string, unknown>();
  const unexpected: string[] = [];
  const store = new RepoStore(), head = "a".repeat(40), base = "b".repeat(40);
  const button = (label: string) => [...host.querySelectorAll<HTMLButtonElement>("button")].find((item) => item.textContent?.trim() === t(label));
  const composer = () => host.querySelector<HTMLTextAreaElement>(`.pr-composer textarea[placeholder="${t("Write a comment…")}"]`);
  const labelled = (label: string) => host.querySelector<HTMLButtonElement>(`button[aria-label="${t(label)}"]`);
  // menus open in the app's menu host, outside this fixture's root
  const menuItem = (label: string) => [...document.querySelectorAll<HTMLElement>(".menu .menu-item")].find((item) => item.querySelector(".label")?.textContent === t(label));
  const titleInput = () => [...host.querySelectorAll("label")].find((label) => label.textContent?.startsWith(t("Title")))?.querySelector("input");
  const enter = (input: HTMLInputElement | HTMLTextAreaElement, value: string) => {
    const prototype = input instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    Object.getOwnPropertyDescriptor(prototype, "value")!.set!.call(input, value);
    input.dispatchEvent(new Event("input", { bubbles: true }));
  };
  try {
    settings.get = <T,>(key: string, fallback: T): T => (memory.has(key) ? memory.get(key) : fallback) as T;
    // the fixture keeps settings in memory, and still tells the views that one changed
    settings.set = (key, value) => { memory.set(key, value); (settings as unknown as { emit(): void }).emit(); };
    accounts.accounts = [];
    ipc.run = async () => { unexpected.push("process"); throw new Error("Fixture blocked process"); };
    ipc.http = async () => { unexpected.push("network"); throw new Error("Fixture blocked network"); };
    store.path = "C:/gitrochi-pr-conversation-fixture"; store.headHash = head; store.headBranch = "topic";
    store.target = { provider: "github", host: "github.example.invalid", path: "fixture/review", remote: "origin" };
    const pr = { number: 7, title: "Fixture review", author: "fixture", source: "topic", target: "main", url: "https://github.example.invalid/fixture/review/pull/7", isDraft: false, updated: null, body: "## Fixture description\n\n| Preview |\n| --- |\n| ![Screenshot](docs/preview.png) |", headSHA: head, fromFork: false };
    store.pullRequests = [pr, { ...pr, number: 8 }]; store.prState = { kind: "loaded" };
    const review: PullRequestReview = { number: 7, repositoryKey: reviewRepositoryKey(store.target), headSHA: head, baseSHA: base, startSHA: base, files: [{ path: "source.ts", oldPath: null, kind: "modified", additions: 1, deletions: 1, patch: "@@ -1 +1 @@\n-before\n+after" }], comments: [{ id: "event", author: "fixture", body: "Marked ready for review", date: null, kind: "system" }, { id: "approval", author: "reviewer", body: "Looks ready", date: 1792973000, kind: "approved" }], warnings: [], state: { approvedBy: [], changesRequestedBy: [], approvalsLeft: null, approvedByMe: false } };
    store.review = review; store.reviewDrafts = [];
    store.loadPullRequests = async () => {};
    const searches: string[] = [];
    store.filterPullRequests = async (scope, search) => { searches.push(`${scope}:${search}`); store.requestQuery = { scope, search, page: 1 }; store.changed(); };
    store.loadReview = async (number) => { store.review = { ...review, number }; store.changed(); };
    store.loadRequestLifecycle = async () => {};
    store.requestLifecycle = { conflicts: false, number: 7, headSHA: head, state: "open", title: pr.title, body: pr.body, base: "main", reviewers: [], methods: ["merge"], blockers: [], checks: "Fixture only", policy: "Fixture only", canEdit: true, canRebase: false, squashRequired: false };
    store.selection = { kind: "pullRequest", number: 7 }; store.navigate("pullRequests", false);
    root.render(<RepoPage store={store} openSettings={() => { unexpected.push("settings"); }} />);
    if (!await until(() => !!composer() && !!labelled("More pull request actions"))) return [false, "PR conversation did not mount"];
    const image = host.querySelector<HTMLImageElement>(".request-description .md table img");
    const segments = [...host.querySelectorAll<HTMLButtonElement>(".pr-list .segmented button")].map((item) => item.textContent?.trim());
    if (!image || !image.src.includes(`/raw/${head}/docs/preview.png`) || !host.querySelector(".request-checks") || !host.querySelector(`.pr-list .pr-list-search input[aria-label="${t("Search pull requests")}"]`) || !labelled("Sort") || segments.length !== 3 || segments[2] !== t("Mine")) return [false, `PR screenshots, checks or list controls did not render: image=${image?.getAttribute("src") ?? "missing"}; checks=${!!host.querySelector(".request-checks")}; search=${!!host.querySelector(".pr-list .pr-list-search input")}; sort=${!!labelled("Sort")}; filter=${segments.join("|")}`];
    if (host.querySelectorAll(".pr-list .pr-row").length !== 2 || host.querySelector(".pr-list .pr-row.selected")?.getAttribute("data-request") !== "7") return [false, "The list did not show both requests with the open one selected"];
    // search on Enter, the three filters as segments, and Closed and Merged in the Sort menu
    const field = host.querySelector<HTMLInputElement>(".pr-list .pr-list-search input")!;
    enter(field, "fixture"); field.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
    [...host.querySelectorAll<HTMLButtonElement>(".pr-list .segmented button")][2].click();
    labelled("Sort")!.click();
    if (!await until(() => !!menuItem("Newest") && !!menuItem("Most commented"))) return [false, "The Sort menu did not open with its orders"];
    [...document.querySelectorAll<HTMLElement>(".menu .menu-item")].find((item) => item.querySelector(".label")?.textContent === workStateTitle("merged"))?.click();
    if (!await until(() => searches.join("|") === "open:fixture|mine:fixture|merged:fixture")) return [false, `Search, the Mine segment and the menu's Merged filter did not reach the list: ${searches.join("|")}`];
    await store.filterPullRequests("open", "");
    const tab = (id: string) => host.querySelector<HTMLButtonElement>(`#request-tab-${id}`)!;
    if (host.querySelectorAll(".request-event").length !== 2 || !host.querySelector(".event-approved") || !host.querySelector(".event-system")) return [false, "Server activity did not render as a timeline"];
    if (host.querySelector(".event-approved time")?.getAttribute("datetime") !== new Date(1792973000 * 1000).toISOString()) return [false, "Timeline date did not preserve the server timestamp"];
    // the composer is one 36px line, and Comment waits for text and says why
    const originalComposer = composer()!;
    const send = () => host.querySelector<HTMLButtonElement>(".pr-composer-send button");
    if (getComputedStyle(originalComposer).height !== "36px" || !send()?.disabled || host.querySelector(".pr-composer-send")?.getAttribute("data-tip") !== t("A comment needs text")) return [false, `An empty composer must be one 36px line with Comment disabled and its reason: height=${getComputedStyle(originalComposer).height}; disabled=${send()?.disabled}`];
    enter(originalComposer, "Fixture unsent review comment");
    if (!await until(() => send()?.disabled === false && getComputedStyle(originalComposer).height === "96px")) return [false, "Typing did not enable Comment or expand the composer"];
    labelled("More pull request actions")!.click();
    if (!await until(() => !!menuItem("Edit request…"))) return [false, "The More menu did not offer Edit request"];
    if (!menuItem("Open in browser") || !menuItem("Copy link") || !menuItem("Check out branch")?.classList.contains("disabled")) return [false, "The More menu must offer Open in browser and Copy link, and disable Check out branch for the checked-out branch"];
    menuItem("Edit request…")!.click();
    if (!await until(() => !!titleInput())) return [false, "Request metadata editor did not mount"];
    enter(titleInput()!, "Fixture unsaved title");
    await pause(25);
    // one Hide list / Show list control; the choice is the same on every tab
    labelled("Hide pull request list")!.click();
    if (!await until(() => !host.querySelector(".pr-list") && !!host.querySelector(".pr-list-strip") && !!labelled("Show pull request list"))) return [false, "Hide list did not leave the strip with Show list"];
    if (memory.get("pullRequestListHidden") !== true) return [false, "The list choice was not stored"];
    tab("conversation").dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true }));
    if (!await until(() => tab("files").getAttribute("aria-selected") === "true" && document.activeElement === tab("files"))) return [false, "Request tabs did not support keyboard navigation"];
    if (host.querySelector(".pr-head")?.getAttribute("data-row") !== "true" || host.querySelector<HTMLElement>(".pr-head")!.getBoundingClientRect().height !== 44) return [false, "Changed files must have a one-row 44px header"];
    if (!labelled("Show pull request list") || host.querySelector(".pr-list")) return [false, "Changed files brought the list back on its own"];
    tab("checks").click();
    if (!await until(() => !host.querySelector<HTMLElement>("#request-panel-checks")!.hidden && host.querySelector<HTMLElement>("#request-panel-files")!.hidden)) return [false, "Request tabs did not isolate check content"];
    if (!labelled("Show pull request list") || host.querySelector(".pr-list")) return [false, "Checks did not keep the list hidden"];
    labelled("Show pull request list")!.click();
    if (!await until(() => !!host.querySelector(".pr-list") && !host.querySelector(".pr-list-strip") && memory.get("pullRequestListHidden") === false)) return [false, "Show list did not bring the list back"];
    tab("conversation").click();
    if (!await until(() => titleInput()?.value === "Fixture unsaved title")) return [false, "Tab switches discarded request metadata edits"];
    for (let cycle = 0; cycle < 2; cycle++) {
      tab("files").click();
      // the first file opens beside the tree; with the list shown the tree is 280px and the two links live in the More menu
      if (!await until(() => !!host.querySelector(".pr-diff-head") && host.querySelector(".pr-tree .review-file")?.getAttribute("aria-current") === "true")) return [false, "Changed files did not open the first file beside the tree"];
      const split = host.querySelector<HTMLButtonElement>(".pr-diff-layout .pr-split button");
      if (!split?.disabled || host.querySelector(".pr-split")?.getAttribute("data-tip") !== t("Split needs a diff at least 1000 px wide") || host.querySelector(".pr-diff-layout button.on")?.textContent !== t("Unified")) return [false, "Split must be disabled with its reason on a diff narrower than 1000px"];
      if (host.querySelector<HTMLElement>(".pr-tree")!.getBoundingClientRect().width !== 280 || button("Open in browser") || !button("Review…")) return [false, "With the list shown the tree must be 280px and only Review… and More stay in the header"];
      const whitespace = labelled("Hide whitespace")!;
      whitespace.click();
      if (!await until(() => whitespace.getAttribute("aria-pressed") === "true" && whitespace.classList.contains("on"))) return [false, "Hide whitespace did not show its on state"];
      whitespace.click();
      tab("conversation").click();
      if (!await until(() => composer()?.value === "Fixture unsent review comment" && titleInput()?.value === "Fixture unsaved title")) return [false, "Opening a review file discarded an unsent comment or metadata edit"];
      if (composer() !== originalComposer) return [false, "Conversation input was remounted when returning from a file"];
    }
    store.select({ kind: "pullRequest", number: 8 });
    if (!await until(() => composer()?.value === "" && !titleInput())) return [false, "Draft state leaked to another pull request"];
    return [unexpected.length === 0, JSON.stringify({ screenshotsRendered: true, checksRendered: true, listControls: true, listChoiceKept: true, composerOneLine: true, splitReason: true, reviewRoundTrips: 2, commentRetained: true, metadataRetained: true, timelineRendered: true, keyboardTabs: true, otherRequestReset: true, unexpected })];
  } finally {
    root.unmount(); await pause(25); host.remove();
    settings.get = original.get; settings.set = original.set; accounts.accounts = original.accounts;
    ipc.run = original.run; ipc.http = original.http;
  }
}
