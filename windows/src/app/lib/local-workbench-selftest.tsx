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
  const click = async (label: string) => { const button = [...host.querySelectorAll<HTMLButtonElement>("button")].find((item) => item.textContent?.trim() === t(label) && !item.disabled); check(button, `Missing enabled button: ${label}`); button!.click(); await pause(); };
  const mount = async (view: ReactNode) => { root.render(view); await pause(); };
  const reset = () => { root.unmount(); host.replaceChildren(); root = createRoot(host); };
  try {
    store.localBranches = [{ name: "main", target: a, upstream: "origin/main", ahead: 1, behind: 0, upstreamGone: false, isCurrent: true, isRemote: false }, { name: "topic", target: b, upstream: null, ahead: 0, behind: 0, upstreamGone: false, isCurrent: false, isRemote: false }];
    store.remoteBranches = [{ ...store.localBranches[1], name: "origin/topic", isRemote: true }]; store.tags = [{ name: "v1", target: a }]; store.stashes = [{ ref: "stash@{0}", hash: b, message: "Saved fixture" }];
    store.loadRevisionComparison = async () => { comparisons++; const s = store.historyTools; s.comparison = { left: a, right: b, base: a, mergeBase: false, files: [], stats: {} }; store.changed(); };
    await mount(<RevisionComparisonPanel store={store}/>); await click("Compare"); check(comparisons === 1 && !host.querySelector('[role="dialog"]'), "Comparison was not embedded");
    reset(); store.path = "C:/gitrochi-workbench-fixture";
    const source: RepositoryCodeSource = { tree: async () => ({ revision: a, entries: [{ path: "src/fixture.ts", mode: "100644", oid: b, size: 17, kind: "file" }], truncated: false }), blob: async () => ({ text: "const fixture = 1;\n" }), read: async (args) => { reads++; return args[0] === "blame" ? "fixture blame" : args[0] === "log" ? "fixture history" : "+fixture changes"; } };
    await mount(<RepositoryCodePanel store={store} source={source}/>); await pause(); check(host.querySelector("pre")?.textContent?.includes("const fixture"), "Code first screen did not preview a safe source file"); await click("fixture.ts"); check(host.querySelector("pre")?.textContent?.includes("const fixture"), "Code tree did not display the blob"); await click("File history"); check(host.querySelector("pre")?.textContent?.includes("fixture history"), "File history missing"); await click("Blame"); check(host.querySelector("pre")?.textContent?.includes("fixture blame"), "Blame missing"); await click("Working changes"); check(reads === 3 && host.querySelector("pre")?.textContent?.includes("+fixture changes"), "Working-change preview missing");
    reset(); store.headHash=a;store.headBranch="topic";store.repoState="clean";
    let previewReads=0;const summary=async()=>{previewReads++;return{base:b,head:a,incoming:3,replay:2,commits:[{id:a,subject:"Newest fixture commit"},{id:b,subject:"Oldest fixture commit"}]};};
    await mount(<RebaseWorkbenchPanel store={store} previewSource={summary}/>);await new Promise(resolve=>setTimeout(resolve,350));
    check(previewReads===1&&host.textContent?.includes("Newest fixture commit")&&host.textContent?.includes(t("{0} commits to replay",2)),"Rebase first screen did not load its branch summary");
    check(host.querySelectorAll(".workbench-rebase-candidates button").length===2&&!store.confirm,"Opening rebase must only preview commits");
    reset(); store.repoState = "rebasing"; store.continueOperation = async () => { rebases++; }; await mount(<RebaseWorkbenchPanel store={store}/>); await click("Continue"); check(rebases === 1 && host.textContent?.includes(t("Abort…")), "In-progress rebase controls missing");
    return [true, "Embedded comparison, automatic safe Code preview, immutable rebase summary, folder/source/history/blame/change previews and rebase continue rendered"];
  } catch (error) { return [false, error instanceof Error ? error.message : String(error)]; }
  finally { root.unmount(); host.remove(); store.cancelHistoryTools(); }
}
