import { createRoot } from "react-dom/client";
import type { ReactNode } from "react";
import { RepoStore } from "@/entities/repo";
import { RepositoryCodePanel, RevisionComparisonPanel, RebaseWorkbenchPanel, type RepositoryCodeSource } from "@/widgets/local-workbench";
import { t } from "@/shared/i18n";
const pause = () => new Promise<void>((resolve) => setTimeout(resolve, 40));
/** Exercises real controls with fixture data. No repository mutation or network request. */
export async function localWorkbenchSelfTest(): Promise<[boolean, string]> {
  const host = document.createElement("div"); host.hidden = true; document.body.append(host); let root = createRoot(host);
  const store = new RepoStore(), a = "a".repeat(40), b = "b".repeat(40);
  let comparisons = 0, reads = 0, rebases = 0;
  const check = (value: unknown, message: string) => { if (!value) throw new Error(message); };
  const waitFor = async (predicate: () => unknown, message: string) => { const deadline = performance.now() + 5000; while (!predicate()) { if (performance.now() >= deadline) throw new Error(message); await pause(); } };
  const click = async (label: string) => { const button = [...host.querySelectorAll<HTMLButtonElement>("button")].find((item) => item.textContent?.trim() === t(label) && !item.disabled); check(button, `Missing enabled button: ${label}`); button!.click(); await pause(); };
  const mount = async (view: ReactNode) => { root.render(view); await pause(); };
  const reset = () => { root.unmount(); host.replaceChildren(); root = createRoot(host); };
  try {
    store.localBranches = [{ name: "main", target: a, upstream: "origin/main", ahead: 1, behind: 0, upstreamGone: false, isCurrent: true, isRemote: false }, { name: "topic", target: b, upstream: null, ahead: 0, behind: 0, upstreamGone: false, isCurrent: false, isRemote: false }];
    store.remoteBranches = [{ ...store.localBranches[1], name: "origin/topic", isRemote: true }]; store.tags = [{ name: "v1", target: a }]; store.stashes = [{ ref: "stash@{0}", hash: b, message: "Saved fixture" }];
    store.loadRevisionComparison = async () => { comparisons++; const s = store.historyTools; s.comparison = { left: a, right: b, base: a, mergeBase: false, files: [], stats: {} }; store.changed(); };
    store.headBranch = "main";
    await mount(<RevisionComparisonPanel store={store}/>);
    check(host.querySelector(".compare-side") && host.querySelector(".compare-main") && host.textContent?.includes(t("Choose two revisions to compare")), "Compare page did not show its two columns and empty state");
    const refs = () => [...host.querySelectorAll<HTMLElement>(".compare-branch")].map((row) => row.dataset.ref).join(",");
    check(refs() === "main,topic,origin/topic,v1", `Branch list order: ${refs()}`);
    const filter = host.querySelector<HTMLInputElement>(`input[aria-label="${t("Filter branches and tags")}"]`)!;
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(filter, "top"); filter.dispatchEvent(new Event("input", { bubbles: true })); await pause();
    check(refs() === "topic,origin/topic", `Filtered branch list: ${refs()}`);
    host.querySelector<HTMLButtonElement>('.compare-branch[data-ref="topic"] button')!.click(); await pause();
    check(comparisons === 1 && store.historyTools.left === "main" && store.historyTools.right === "topic", "The row's Compare did not compare the current branch with that branch");
    check(host.querySelector('.compare-branch[data-ref="topic"]')?.classList.contains("on") && host.querySelector(".compare-result") && !host.querySelector('[role="dialog"]'), "The compared branch is not highlighted or the result is not on the page");
    await click("Compare"); check(comparisons === 2, "The main Compare button did not run the comparison");
    check(!host.querySelector("h1, h2"), "Compare must not show a large page title");
    reset(); store.path = "C:/gitrochi-workbench-fixture";
    const source: RepositoryCodeSource = { tree: async () => ({ revision: a, entries: [{ path: "src/fixture.ts", mode: "100644", oid: b, size: 17, kind: "file" }], truncated: false }), blob: async () => ({ text: "const fixture = 1;\n" }), read: async (args) => { reads++; return args[0] === "blame" ? "fixture blame" : args[0] === "log" ? "fixture history" : "+fixture changes"; } };
    await mount(<RepositoryCodePanel store={store} source={source}/>);
    await waitFor(() => host.querySelector("pre")?.textContent?.includes("const fixture"), "Code first screen did not preview a safe source file");
    check(!host.querySelector("h1, h2"), "Code must not show a large page title");
    await click("fixture.ts"); await waitFor(() => host.querySelector("pre")?.textContent?.includes("const fixture"), "Code tree did not display the blob");
    await click("File history"); await waitFor(() => host.querySelector("pre")?.textContent?.includes("fixture history"), "File history missing");
    await click("Blame"); await waitFor(() => host.querySelector("pre")?.textContent?.includes("fixture blame"), "Blame missing");
    await click("Working changes"); await waitFor(() => reads === 3 && host.querySelector("pre")?.textContent?.includes("+fixture changes"), "Working-change preview missing");
    await click("Source");
    await waitFor(() => host.querySelector(".source-keyword")?.textContent === "const" && host.querySelector(".source-line-number")?.getAttribute("aria-hidden") === "true", "Source colors or accessible line gutter missing");
    const find = host.querySelector<HTMLInputElement>(`input[aria-label="${t("Find in file")}"]`)!;
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(find, "fixture"); find.dispatchEvent(new Event("input", { bubbles: true })); await pause();
    check(host.querySelectorAll("mark").length === 1 && host.querySelector("mark.active")?.textContent === "fixture", "Literal in-file search did not highlight source");
    const control = async (label: string) => { const button = host.querySelector<HTMLButtonElement>(`button[aria-label="${t(label)}"]`); check(button && !button.disabled, `Missing reader control: ${label}`); button!.click(); await pause(); };
    await control("Wrap lines"); check(host.querySelector("pre")?.classList.contains("wrap"), "Wrap control did not update the source");
    await control("Increase font size"); check(host.querySelector("pre")?.style.fontSize === "14px", "Reader font size did not change");
    await control("Hide file explorer"); check(!host.querySelector(".code-explorer"), "Focus control did not hide the explorer");
    await control("Show file explorer"); check(host.querySelector(".code-explorer"), "Focus control did not restore the explorer");
    check(host.querySelector(".code-status-bar")?.textContent?.includes(t("{0} lines", "1")), "Reader line count missing");
    reset();
    const codeFiles: Record<string, string> = {
      "src/first.ts": "export function first() {\r\n  return 1;\r\n}\r\n\r\nexport function second() { return 2; }\r\n",
      "src/second.ts": "export const second = () => 2;\n",
      "src/large.ts": "line\n".repeat(6000) + "export function tail() {}\n",
    };
    let deferSecond = false, releaseSecond: ((value: { text: string }) => void) | undefined;
    const navigationSource: RepositoryCodeSource = {
      tree: async () => ({ revision: a, entries: Object.entries(codeFiles).map(([path, text]) => ({ path, mode: "100644", oid: b, size: text.length, kind: "file" })), truncated: false }),
      blob: async (_repo, entry) => { if (deferSecond && entry.path === "src/second.ts") return new Promise<{ text: string }>((resolve) => { releaseSecond = resolve; }); return { text: codeFiles[entry.path] }; },
      read: async () => "fixture file history",
    };
    const setInputValue = async (field: HTMLInputElement, value: string) => { Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(field, value); field.dispatchEvent(new Event("input", { bubbles: true })); await pause(); };
    const quickSelect = async (query: string) => {
      await click("Quick open");
      const field = host.querySelector<HTMLInputElement>(`input[aria-label="${t("Search files by name or path")}"]`)!;
      await setInputValue(field, query);
      await waitFor(() => host.querySelectorAll('.code-quick-results [role="option"]').length === 1, "Quick open did not rank the requested file");
      field.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true })); await pause();
    };
    await mount(<RepositoryCodePanel store={store} source={navigationSource}/>);
    await waitFor(() => host.querySelector("pre")?.textContent?.includes("function first"), "Navigation fixture did not open its first file");
    check([...host.querySelectorAll(".source-line-text")].map((line) => line.textContent).join("") === codeFiles["src/first.ts"], "Reader changed original CRLF or final newline");
    await quickSelect("second.ts");
    await waitFor(() => host.querySelector("pre")?.textContent?.includes("const second"), "Quick open Enter did not open the selected result");
    check(!host.querySelector('[role="dialog"]') && host.querySelectorAll(".code-file-tab").length === 2, "Quick open did not close or preserve open tabs");
    await click("Recent files");
    check(host.querySelector(".code-file-list .code-file-row")?.textContent?.includes("src/second.ts"), "Recent files are not in reading order");
    await control("Navigate back"); await waitFor(() => host.querySelector("pre")?.textContent?.includes("function first"), "Back did not restore the previous file");
    await click("File history"); await waitFor(() => host.querySelector("pre")?.textContent?.includes("fixture file history"), "File history fixture did not load");
    await control("Navigate back"); await waitFor(() => host.querySelector("pre")?.textContent?.includes("function first"), "Back did not preserve source mode");
    await control("Navigate forward"); await waitFor(() => host.querySelector("pre")?.textContent?.includes("fixture file history"), "Forward did not preserve history mode");
    await click("Source"); await waitFor(() => host.querySelector("pre")?.textContent?.includes("function first"), "Source did not restore after history");
    const lineField = host.querySelector<HTMLInputElement>(`input[aria-label="${t("Line number")}"]`)!;
    await setInputValue(lineField, "0"); await click("Go to line");
    check(lineField.getAttribute("aria-invalid") === "true" && host.querySelector(".code-line-error"), "Go to line accepted an invalid number");
    await setInputValue(lineField, "5"); await click("Go to line");
    await waitFor(() => host.querySelector('[data-line-jump="5"]')?.textContent?.includes("function second"), "Go to line did not target the actual source line");
    host.querySelector<HTMLElement>(".code-outline summary")!.click(); await pause();
    check(host.querySelectorAll(".code-outline-list button").length === 2, "Outline did not list function declarations");
    host.querySelector<HTMLButtonElement>(".code-outline-list button")!.click(); await pause();
    check(host.querySelector('[data-line-jump="1"]')?.textContent?.includes("function first"), "Outline did not jump to its declaration");
    await quickSelect("large.ts"); await waitFor(() => host.querySelector("pre.large"), "Large source did not use bounded rendering");
    await setInputValue(host.querySelector<HTMLInputElement>(`input[aria-label="${t("Line number")}"]`)!, "6001"); await click("Go to line");
    await waitFor(() => [...host.querySelectorAll('[data-line-jump="6001"]')].map((part) => part.textContent).join("") === "export function tail() {}\n", "Large-file line navigation did not target the actual text");
    check(host.querySelector(".source-large-text")?.textContent === codeFiles["src/large.ts"], "Large-file line decoration changed source text");
    host.querySelector<HTMLButtonElement>(".code-file-tab.on .code-close-file")!.click(); await pause();
    await waitFor(() => host.querySelector("pre")?.textContent?.includes("const second"), "Closing the selected tab did not activate its neighbor");
    deferSecond = true;
    await control("Navigate back"); await waitFor(() => host.querySelector("pre.large"), "History did not reopen the closed large file");
    await quickSelect("second.ts"); await waitFor(() => host.querySelector(".code-loading"), "Delayed tab fixture did not wait");
    host.querySelector<HTMLButtonElement>(".code-file-tab.on .code-close-file")!.click(); await pause();
    await waitFor(() => host.querySelector("pre.large"), "Closing a pending tab did not activate its adjacent file");
    check(releaseSecond, "Delayed tab fixture did not start"); releaseSecond!({ text: "stale tab preview" }); await pause();
    check(host.querySelector("pre.large"), "Closed tab replaced the current preview after loading");
    await control("Close all files");
    check(!host.querySelector(".code-file-tab") && host.textContent?.includes(t("Choose a file")), "Close all files did not clear the reader");
    reset();
    let releaseBlame: ((value: { text: string }) => void) | undefined, staleReads = 0, blobReads = 0;
    const delayedSource: RepositoryCodeSource = {
      tree: async (_repo, ref) => ({ revision: ref === "HEAD" ? a : b, entries: [{ path: ref === "HEAD" ? "src/fixture.ts" : "src/fresh.ts", mode: "100644", oid: b, size: 20, kind: "file" }], truncated: false }),
      blob: async (_repo, entry) => { blobReads++; if (blobReads === 2) return new Promise<{ text: string }>((resolve) => { releaseBlame = resolve; }); return { text: entry.path.includes("fresh") ? "const fresh = 2;\n" : "const fixture = 1;\n" }; },
      read: async () => { staleReads++; return "stale blame"; },
    };
    await mount(<RepositoryCodePanel store={store} source={delayedSource}/>); await waitFor(() => host.querySelector("pre"), "Delayed fixture did not load"); await click("Blame");
    check(host.querySelector(".code-loading")?.textContent?.includes(t("Loading…")), "Pending file request must show its loading state");
    const revision = host.querySelector<HTMLInputElement>(`input[aria-label="${t("Revision")}"]`)!;
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(revision, "topic"); revision.dispatchEvent(new Event("input", { bubbles: true })); await pause(); await click("Load revision");
    await waitFor(() => host.querySelector("pre")?.textContent?.includes("const fresh"), "Revision switch did not show its source");
    check(host.querySelectorAll(".code-file-tab").length === 1 && host.querySelector<HTMLButtonElement>(`button[aria-label="${t("Navigate back")}"]`)?.disabled, "Revision switch did not reset tabs and reading history");
    check(releaseBlame, "Blame fixture did not wait for its source"); releaseBlame!({ text: "const stale = 3;\n" }); await pause();
    check(staleReads === 0 && host.querySelector("pre")?.textContent?.includes("const fresh"), "Stale blame issued another Git read or replaced the current file");
    reset(); store.headHash=a;store.headBranch="topic";store.repoState="clean";
    let previewReads=0;const summary=async()=>{previewReads++;return{base:b,head:a,incoming:3,replay:2,commits:[{id:a,subject:"Newest fixture commit"},{id:b,subject:"Oldest fixture commit"}]};};
    await mount(<RebaseWorkbenchPanel store={store} previewSource={summary}/>);await new Promise(resolve=>setTimeout(resolve,350));
    check(previewReads===1&&host.textContent?.includes("Newest fixture commit")&&host.textContent?.includes(t("{0} commits to replay",2)),"Rebase first screen did not load its branch summary");
    check(!host.querySelector("h1, h2.workbench-heading, .workbench-heading") && host.textContent?.includes(t("Current branch")), "Rebase must keep its current branch line without a large page title");
    check(host.querySelectorAll(".workbench-rebase-candidates button").length===2&&!store.confirm,"Opening rebase must only preview commits");
    reset(); store.repoState = "rebasing"; store.continueOperation = async () => { rebases++; }; await mount(<RebaseWorkbenchPanel store={store}/>); await click("Continue"); check(rebases === 1 && host.textContent?.includes(t("Abort…")), "In-progress rebase controls missing");
    return [true, "Compare controls, safe Code preview, source colors and exact newlines, find/wrap/font/focus, quick open, tabs and recents, back/forward view history, outline and large-file line navigation, closed-tab and stale-blame cancellation, revision reset and rebase controls rendered"];
  } catch (error) { return [false, error instanceof Error ? error.message : String(error)]; }
  finally { root.unmount(); host.remove(); store.cancelHistoryTools(); }
}
