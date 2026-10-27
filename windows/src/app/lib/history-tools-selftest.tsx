import type { ReactNode } from "react";
import { createRoot } from "react-dom/client";
import { RepoStore } from "@/entities/repo";
import { CompareRevisionsSheet, BatchCommitsSheet, LineHistorySheet } from "@/features/history-tools";
import { t } from "@/shared/i18n";

const pause = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));
/** 외부 호출 없이 실제 React 버튼과 파일 선택 흐름을 검사한다. */
export async function historyToolsSelfTest(): Promise<[boolean, string]> {
  const host = document.createElement("div"); host.hidden = true; host.dataset.selftest = "history-tools"; document.body.append(host);
  let root = createRoot(host);
  const store = new RepoStore(), s = store.historyTools;
  const a = "a".repeat(40), b = "b".repeat(40);
  const button = (label: string) => [...host.querySelectorAll<HTMLButtonElement>("button")].find((element) => element.textContent?.trim() === t(label));
  const ensure = (condition: unknown, detail: string) => { if (!condition) throw new Error(detail); };
  const mount = async (view: ReactNode) => { root.render(view); await pause(40); };
  const reset = async () => { root.unmount(); host.replaceChildren(); root = createRoot(host); };
  let comparisons = 0, selections = 0, batches = 0, traces = 0;
  try {
    store.loadRevisionComparison = async () => {
      comparisons++;
      s.comparison = { left: a, right: b, base: a, mergeBase: false, files: [{ path: "source.ts", oldPath: null, kind: "modified", staged: false }, { path: "test.ts", oldPath: null, kind: "added", staged: false }], stats: {} };
      s.comparisonPath = "source.ts"; s.comparisonPatch = "-before\n+after"; store.changed();
    };
    store.selectComparisonFile = async (file) => { selections++; s.comparisonPath = file.path; s.comparisonPatch = "+selected-test"; store.changed(); };
    store.localBranches = [{ name: "topic", target: b, upstream: null, ahead: 0, behind: 0, upstreamGone: false, isCurrent: false, isRemote: false }];
    await mount(<CompareRevisionsSheet store={store} close={() => {}} />);
    // the list beside the From field fills it and then shows its prompt again
    const picker = host.querySelector<HTMLSelectElement>(`select[aria-label="${t("Choose a branch or tag")}: ${t("From revision")}"]`);
    ensure(picker && [...picker.options].some((option) => option.value === "topic"), "The From revision list does not offer the local branch");
    Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, "value")!.set!.call(picker, "topic"); picker!.dispatchEvent(new Event("change", { bubbles: true })); await pause(30);
    ensure(s.left === "topic" && host.querySelector<HTMLInputElement>(`input[aria-label="${t("From revision")}"]`)?.value === "topic" && picker!.value === "", "Picking a branch did not fill the From revision field");
    ensure(comparisons === 0, "Comparison ran before the user requested it"); button("Compare")?.click(); await pause(30);
    ensure(comparisons === 1 && host.querySelector("pre")?.textContent?.includes("+after"), "Comparison did not render the frozen patch");
    const file = [...host.querySelectorAll<HTMLButtonElement>(".history-tools-file")].find((element) => element.textContent?.includes("test.ts")); file?.click(); await pause(30);
    ensure(selections === 1 && host.querySelector("pre")?.textContent?.includes("+selected-test"), "Selecting another comparison file did not render its patch");
    await reset();
    s.batch = [{ sha: a, parents: [b], subject: "First", author: "Fixture", message: "First" }, { sha: b, parents: [], subject: "Second", author: "Fixture", message: "Second" }];
    s.batchHead = a; s.batchBranch = "refs/heads/topic";
    store.executeBatchCommits = async () => { batches++; };
    await mount(<BatchCommitsSheet store={store} close={() => {}} />);
    const move = [...host.querySelectorAll<HTMLButtonElement>("button")].find((element) => element.dataset.tip === t("Run later")); move?.click(); await pause(30);
    ensure(s.batch[0].sha === b, "The batch execution order did not change");
    button("Apply selected commits")?.click(); await pause(30); ensure(batches === 1, "The batch confirmation button did not execute");
    await reset();
    s.linePath = "source.ts"; s.lineRevision = a;
    store.loadLineHistory = async () => { traces++; s.lineEntries = [{ sha: a, subject: "Trace fixture", author: "Fixture", date: "2026-01-01", patch: "+historic-line" }]; s.lineSelected = a; store.changed(); };
    await mount(<LineHistorySheet store={store} close={() => {}} />); button("Trace history")?.click(); await pause(30);
    ensure(traces === 1 && host.querySelector("pre")?.textContent?.includes("+historic-line"), "Line history did not render its patch");
    return [true, "Compare request/file selection, batch order/confirmation and line-history request rendered"];
  } catch (error) { return [false, error instanceof Error ? error.message : String(error)]; }
  finally { root.unmount(); host.remove(); store.cancelHistoryTools(); }
}
