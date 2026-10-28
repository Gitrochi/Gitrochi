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
    check(releaseBlame, "Blame fixture did not wait for its source"); releaseBlame!({ text: "const stale = 3;\n" }); await pause();
    check(staleReads === 0 && host.querySelector("pre")?.textContent?.includes("const fresh"), "Stale blame issued another Git read or replaced the current file");
    reset(); store.headHash=a;store.headBranch="topic";store.repoState="clean";
    let previewReads=0;const summary=async()=>{previewReads++;return{base:b,head:a,incoming:3,replay:2,commits:[{id:a,subject:"Newest fixture commit"},{id:b,subject:"Oldest fixture commit"}]};};
    await mount(<RebaseWorkbenchPanel store={store} previewSource={summary}/>);await new Promise(resolve=>setTimeout(resolve,350));
    check(previewReads===1&&host.textContent?.includes("Newest fixture commit")&&host.textContent?.includes(t("{0} commits to replay",2)),"Rebase first screen did not load its branch summary");
    check(!host.querySelector("h1, h2.workbench-heading, .workbench-heading") && host.textContent?.includes(t("Current branch")), "Rebase must keep its current branch line without a large page title");
    check(host.querySelectorAll(".workbench-rebase-candidates button").length===2&&!store.confirm,"Opening rebase must only preview commits");
    reset(); store.repoState = "rebasing"; store.continueOperation = async () => { rebases++; }; await mount(<RebaseWorkbenchPanel store={store}/>); await click("Continue"); check(rebases === 1 && host.textContent?.includes(t("Abort…")), "In-progress rebase controls missing");
    return [true, "Two-column Compare page with branch list, filter and row action, automatic safe Code preview, source colors, line numbers, find, wrapping, font sizing, explorer focus, stale blame cancellation, immutable rebase summary and rebase continue rendered"];
  } catch (error) { return [false, error instanceof Error ? error.message : String(error)]; }
  finally { root.unmount(); host.remove(); store.cancelHistoryTools(); }
}
