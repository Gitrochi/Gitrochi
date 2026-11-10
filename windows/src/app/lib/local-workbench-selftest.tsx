import { createRoot } from "react-dom/client";
import type { ReactNode } from "react";
import { RepoStore } from "@/entities/repo";
import { RepositoryCodePanel, RevisionComparisonPanel, RebaseWorkbenchPanel, type RepositoryCodeSource, type RepositoryEditorSource } from "@/widgets/local-workbench";
import { t } from "@/shared/i18n";
import { codePreviewSelfTest } from "./code-preview-selftest";
const pause = () => new Promise<void>((resolve) => setTimeout(resolve, 40));
/** Exercises real controls with fixture data. No repository mutation or network request. */
export async function localWorkbenchSelfTest(): Promise<[boolean, string]> {
  const host = document.createElement("div"); host.hidden = true; document.body.append(host); let root = createRoot(host);
  const store = new RepoStore(), a = "a".repeat(40), b = "b".repeat(40);
  let comparisons = 0, rebases = 0;
  const check = (value: unknown, message: string) => { if (!value) throw new Error(message); };
  const waitFor = async (predicate: () => unknown, message: string) => { const deadline = performance.now() + 5000; while (!predicate()) { if (performance.now() >= deadline) throw new Error(message); await pause(); } };
  const click = async (label: string) => { const button = [...host.querySelectorAll<HTMLButtonElement>("button")].find((item) => item.textContent?.trim() === t(label) && !item.disabled); check(button, `Missing enabled button: ${label}`); button!.click(); await pause(); };
  const mount = async (view: ReactNode) => { root.render(view); await pause(); };
  const reset = () => { root.unmount(); host.replaceChildren(); root = createRoot(host); };
  try {
    await codePreviewSelfTest();
    store.localBranches = [{ name: "main", target: a, upstream: "origin/main", ahead: 1, behind: 0, upstreamGone: false, isCurrent: true, isRemote: false }, { name: "topic", target: b, upstream: null, ahead: 0, behind: 0, upstreamGone: false, isCurrent: false, isRemote: false }];
    store.remoteBranches = [{ ...store.localBranches[1], name: "origin/topic", isRemote: true }]; store.tags = [{ name: "v1", target: a }]; store.stashes = [{ ref: "stash@{0}", hash: b, message: "Saved fixture" }];
    // The Compare page compares by itself: the usual base against the current branch on arrival, then on every change
    let opened: boolean | undefined;
    const comparedFiles = [{ path: "src/b.ts", oldPath: null, kind: "modified" as const, staged: false }, { path: "src/a.ts", oldPath: "src/old.ts", kind: "renamed" as const, staged: false }];
    store.loadRevisionComparison = async (openFirst = true) => {
      comparisons++; opened = openFirst; const s = store.historyTools;
      s.comparison = { left: b, right: a, base: b, mergeBase: s.useMergeBase, files: comparedFiles, stats: { "src/b.ts": { added: 3, deleted: 1 } }, commits: [{ id: a, author: "Fixture Author", date: Math.floor(Date.now() / 1000), subject: "Fixture commit" }] };
      store.changed();
    };
    store.headBranch = "main"; store.path = "C:/gitrochi-compare-fixture";
    const compareReads: string[][] = [];
    const compareRead = async (args: string[]) => { compareReads.push(args); return args[0] === "diff" ? `diff --git a/${args.at(-1)} b/${args.at(-1)}\n--- a/${args.at(-1)}\n+++ b/${args.at(-1)}\n@@ -1 +1 @@\n-old\n+new\n` : "new\n"; };
    const workingChecks: string[] = [], compareEditors = { list: async () => [{ id: "system" as const, name: "System default", available: true, supportsFolders: true }], open: async () => {} };
    await mount(<RevisionComparisonPanel store={store} read={compareRead} editorSource={compareEditors} exists={async (_repo, path) => { workingChecks.push(path); return true; }}/>);
    check(host.querySelector(".compare-column") && host.querySelector(".compare-main") && !host.querySelector("h1, h2"), "Compare page did not show its list column and comparison without a large title");
    await waitFor(() => comparisons === 1, "Compare did not compare on arrival");
    check(opened === false && store.historyTools.left === "topic" && store.historyTools.right === "main" && store.historyTools.useMergeBase, `Compare did not start with the usual base against the current branch: ${store.historyTools.left} → ${store.historyTools.right}`);
    const refs = () => [...host.querySelectorAll<HTMLElement>(".compare-refs .compare-ref")].map((row) => row.dataset.ref).join(",");
    check(refs() === "topic,origin/topic,v1", `Branch list order (the current branch left out): ${refs()}`);
    check(host.querySelector('.compare-ref[data-ref="topic"]')?.classList.contains("on") && host.querySelector('.compare-ref[data-ref="topic"]')?.getAttribute("aria-current") === "true", "The branch compared now is not tinted");
    const filter = host.querySelector<HTMLInputElement>(`input[aria-label="${t("Filter branches and tags")}"]`)!;
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(filter, "top"); filter.dispatchEvent(new Event("input", { bubbles: true })); await pause();
    check(refs() === "topic,origin/topic", `Filtered branch list: ${refs()}`);
    host.querySelector<HTMLButtonElement>('.compare-ref[data-ref="origin/topic"]')!.click();
    await waitFor(() => comparisons === 2, "Choosing a branch did not compare it with the current branch");
    check(store.historyTools.left === "origin/topic" && store.historyTools.right === "main" && !host.querySelector('[role="dialog"]'), "The row did not make the branch From and the current branch To");
    await waitFor(() => host.querySelector(".code-changes-count")?.textContent === "1 / 2", "The first file's diff did not open with its position");
    check(compareReads.some((args) => args[0] === "diff" && args.includes(b) && args.includes(a) && args.at(-1) === "src/b.ts"), "The diff was not read between the base and To");
    check(workingChecks.includes("src/b.ts"), "Open in editor did not check the open file in the working tree");
    check([...host.querySelectorAll(".compare-tab")].map((tab) => tab.textContent).join("|") === `${t("Files")}2|${t("Commits")}1`, "The tabs do not own their counts");
    document.body.dispatchEvent(new KeyboardEvent("keydown", { key: "j", bubbles: true }));
    await waitFor(() => host.querySelector(".code-changes-count")?.textContent === "2 / 2", "J did not step to the next file");
    check(compareReads.some((args) => args[0] === "diff" && args.at(-2) === "src/old.ts" && args.at(-1) === "src/a.ts"), "A renamed file's diff did not include its old path");
    host.querySelectorAll<HTMLButtonElement>(".compare-tab")[1].click(); await pause(); check(host.querySelectorAll(".compare-commit").length === 1 && host.textContent?.includes("Fixture commit"), "The Commits tab did not list To's commits");
    host.querySelector<HTMLButtonElement>(`button[aria-label="${t("Swap From and To")}"]`)!.click();
    await waitFor(() => comparisons === 3, "Swapping did not compare again");
    check(store.historyTools.left === "main" && store.historyTools.right === "origin/topic", "Swap did not exchange From and To");
    store.historyTools.left = "HEAD~1"; store.historyTools.right = "HEAD"; store.historyTools.useMergeBase = false; store.historyTools.comparison = null; store.historyTools.comparisonKey = "";
    reset(); store.path = "C:/gitrochi-workbench-fixture";
    // The formats the Code page asks Git for: the history list, a porcelain blame and a patch
    const stamp = Math.floor(Date.now() / 1000), fixtureText = ["const fixture = 1;", "const second = 2;", "const third = 3;", "const fourth = 4;", "const fifth = 5;", "const sixth = 6;"].join("\n") + "\n";
    const historyText = (path: string) => [["Reword the fixture", a, b], ["Add the fixture", b, ""]].map(([subject, id, parent]) => `\x1e${[id, parent, "Fixture Author", "fixture@example.invalid", stamp, subject].join("\x1f")}\0\n${path}\0`).join("");
    const blameText = (text: string) => text.trimEnd().split("\n").map((line, index) => `${index ? b : a} ${index + 1} ${index + 1}\n${index < 2 ? `author Fixture Author\nauthor-mail <fixture@example.invalid>\nauthor-time ${stamp}\nsummary ${index ? "Add the fixture" : "Reword the fixture"}\nfilename fixture\n` : ""}\t${line}\n`).join("");
    const patchText = (path: string, body: string) => `diff --git a/${path} b/${path}\n--- a/${path}\n+++ b/${path}\n${body}`;
    const treeRefs: string[] = [], readKinds: string[] = [];
    const source: RepositoryCodeSource = {
      tree: async (_repo, ref) => { treeRefs.push(ref); return { revision: ref === "HEAD" ? a : b, entries: [{ path: "src/fixture.ts", mode: "100644", oid: b, size: fixtureText.length, kind: "file" }], truncated: false }; },
      blob: async () => ({ text: fixtureText }),
      read: async (args) => {
        readKinds.push(args[0]);
        return args[0] === "log" ? historyText("src/fixture.ts") : args[0] === "blame" ? blameText(fixtureText) : args[0] === "cat-file" ? fixtureText : args[0] === "rev-list" ? a + "\n"
          : args[0] === "show" ? patchText("src/fixture.ts", "@@ -1,2 +1,2 @@\n-const fixture = 0;\n+const fixture = 1;\n const second = 2;\n")
          : patchText("src/fixture.ts", "@@ -1,2 +1,3 @@\n const fixture = 1;\n+const working = true;\n const second = 2;\n");
      },
    };
    const tab = async (view: string) => { const button = host.querySelector<HTMLButtonElement>(`.code-view-tabs button[data-view="${view}"]`); check(button && !button.disabled, `Missing view tab: ${view}`); button!.click(); await pause(); };
    const status = () => host.querySelector(".code-status-bar")?.textContent ?? "";
    let revealed = ""; store.reveal = (sha) => { revealed = sha; };
    await mount(<RepositoryCodePanel store={store} source={source}/>);
    await waitFor(() => host.querySelector("pre")?.textContent?.includes("const fixture"), "Code first screen did not preview a safe source file");
    check(!host.querySelector("h1, h2"), "Code must not show a large page title");
    check(host.querySelector(".code-bar") && !host.querySelector(".code-revision-summary, .code-document-heading, .code-mode-bar") && !host.querySelector(".code-open-files"), "Code must show one bar and one tab row above the content, without counts or a file heading");
    check(host.querySelector(".code-revision > button")?.textContent === a.slice(0, 7) + "·main", "The revision button must show the short hash and the branch, nothing else");
    await click("fixture.ts"); await waitFor(() => host.querySelector("pre")?.textContent?.includes("const fixture"), "Code tree did not display the blob");
    await waitFor(() => host.querySelector('.code-view-tabs [data-view="History"] .status-pill')?.textContent === "2", "The History tab did not show its count");
    await tab("History");
    await waitFor(() => host.querySelectorAll(".code-history-row").length === 2 && host.querySelector(".code-diff-line.added .code")?.textContent === "const fixture = 1;", "History did not list the commits and the first one's change");
    check(host.querySelector(".code-history-row.on")?.textContent?.includes("Reword the fixture") && host.querySelectorAll(".code-changes-head").length === 1, "History must select the newest commit and show one header over its change");
    await waitFor(() => host.querySelector(".code-diff-fold"), "The unchanged lines after the hunk were not folded");
    check(status().includes(t("Changes in {0} against its parent", a.slice(0, 7))) && status().includes(t("{0} lines", "6")) && status().includes(t("Read only")), `History status bar: ${status()}`);
    const rows = host.querySelectorAll(".code-diff-line").length;
    host.querySelector<HTMLButtonElement>(".code-diff-fold button")!.click(); await pause();
    check(!host.querySelector(".code-diff-fold") && host.querySelectorAll(".code-diff-line").length === rows + 4 && [...host.querySelectorAll(".code-diff-line .code")].at(-1)?.textContent === "const sixth = 6;", "Unfolding did not show the unchanged lines of the file");
    host.querySelectorAll<HTMLButtonElement>(".code-history-row")[1].click(); await pause();
    check(host.querySelector(".code-history-row.on")?.textContent?.includes("Add the fixture") && status().includes(t("As of commit {0}", b.slice(0, 7))), "Choosing an older commit did not move the selection or the status bar");
    await tab("Blame");
    await waitFor(() => host.querySelectorAll(".code-blame-group").length === 2 && host.querySelectorAll(".code-blame-line").length === 6, "Blame did not group the lines by commit");
    check(host.querySelectorAll(".code-blame-commit").length === 2 && host.querySelector(".code-blame-commit")?.textContent?.includes("Reword the fixture"), "Each blame group must name its commit once");
    check(status().includes(t("Blame of the revision shown · uncommitted changes not shown")) && status().includes(t("{0} lines", "6")), `Blame status bar: ${status()}`);
    host.querySelectorAll<HTMLButtonElement>(".code-blame-commit")[1].click(); await pause();
    check(host.querySelector(".code-blame-card")?.textContent?.includes("Add the fixture") && !host.querySelector(".code-blame-card")?.textContent?.includes(t("Blame before this change")), "The oldest commit's card must not offer an earlier blame");
    await click("Show commit"); check(revealed === b && !host.querySelector(".code-blame-card"), "Show commit did not reveal the group's commit");
    host.querySelector<HTMLButtonElement>(".code-blame-commit")!.click(); await pause();
    await click("Blame before this change");
    await waitFor(() => treeRefs.at(-1) === b && host.querySelectorAll(".code-blame-group").length === 2, "Blame before this change did not blame the file at the commit's parent");
    await tab("Working changes");
    await waitFor(() => readKinds.includes("diff") && host.querySelector(".code-diff-line.added .code")?.textContent === "const working = true;", "Working-change preview missing");
    check(status().includes(t("Uncommitted changes against HEAD")) && !host.querySelector(".code-history-list"), "Working changes must show the change alone, with its own status");
    await tab("Source");
    await waitFor(() => host.querySelector(".source-keyword")?.textContent === "const" && host.querySelector(".source-line-number")?.getAttribute("aria-hidden") === "true", "Source colors or accessible line gutter missing");
    const find = host.querySelector<HTMLInputElement>(`input[aria-label="${t("Find in file")}"]`)!;
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(find, "fixture"); find.dispatchEvent(new Event("input", { bubbles: true })); await pause();
    check(host.querySelectorAll("mark").length === 1 && host.querySelector("mark.active")?.textContent === "fixture", "Literal in-file search did not highlight source");
    const control = async (label: string) => { const button = host.querySelector<HTMLButtonElement>(`button[aria-label="${t(label)}"]`); check(button && !button.disabled, `Missing reader control: ${label}`); button!.click(); await pause(); };
    await control("Wrap lines"); check(host.querySelector("pre")?.classList.contains("wrap"), "Wrap control did not update the source");
    await control("Increase font size"); check(host.querySelector("pre")?.style.fontSize === "14px", "Reader font size did not change");
    check(status().includes(t("{0} lines", "6")) && status().includes(t("As of commit {0}", b.slice(0, 7))), "Reader line count or revision missing");
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
      read: async (args) => args[0] === "log" ? historyText(args.at(-1)!) : args[0] === "show" ? patchText(args.at(-1)!, "@@ -1 +1 @@\n-before\n+after\n") : "",
    };
    const setInputValue = async (field: HTMLInputElement, value: string) => { Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(field, value); field.dispatchEvent(new Event("input", { bubbles: true })); await pause(); };
    const quickSelect = async (query: string) => {
      await control("Quick open");
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
    await control("Quick open");
    check(host.querySelector('.code-quick-results [role="option"]')?.textContent?.includes("src/second.ts"), "Recent files are not in reading order");
    await control("Close quick open");
    await control("Navigate back"); await waitFor(() => host.querySelector("pre")?.textContent?.includes("function first"), "Back did not restore the previous file");
    await tab("History"); await waitFor(() => host.querySelectorAll(".code-history-row").length === 2, "File history fixture did not load");
    await control("Navigate back"); await waitFor(() => host.querySelector("pre")?.textContent?.includes("function first"), "Back did not preserve source mode");
    await control("Navigate forward"); await waitFor(() => host.querySelectorAll(".code-history-row").length === 2, "Forward did not preserve history mode");
    await tab("Source"); await waitFor(() => host.querySelector("pre")?.textContent?.includes("function first"), "Source did not restore after history");
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
      read: async (args) => { if (args[0] === "blame") staleReads++; return args[0] === "log" ? historyText(args.at(-1)!) : ""; },
    };
    await mount(<RepositoryCodePanel store={store} source={delayedSource}/>); await waitFor(() => host.querySelector("pre"), "Delayed fixture did not load"); await tab("Blame");
    check(host.querySelector(".code-loading")?.textContent?.includes(t("Loading…")), "Pending file request must show its loading state");
    host.querySelector<HTMLButtonElement>(".code-revision > button")!.click(); await pause();
    const revision = host.querySelector<HTMLInputElement>(`input[aria-label="${t("Revision")}"]`)!;
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(revision, "topic"); revision.dispatchEvent(new Event("input", { bubbles: true })); await pause(); await click("Load revision");
    await waitFor(() => host.querySelector("pre")?.textContent?.includes("const fresh"), "Revision switch did not show its source");
    check(!host.querySelector(".code-file-tab, .code-revision-list") && host.querySelector<HTMLButtonElement>(`button[aria-label="${t("Navigate back")}"]`)?.disabled, "Revision switch did not reset tabs and reading history");
    check(host.querySelector(".code-revision > button")?.textContent === b.slice(0, 7) + "·topic", "The revision button did not name the loaded revision");
    check(releaseBlame, "Blame fixture did not wait for its source"); releaseBlame!({ text: "const stale = 3;\n" }); await pause();
    check(staleReads === 0 && host.querySelector("pre")?.textContent?.includes("const fresh"), "Stale blame issued another Git read or replaced the current file");
    reset();
    const previewFiles: Record<string, string> = {
      "src/Card.tsx": "export function Card() { return <div>Card</div>; }\n",
      "src/util.ts": "export const value = 1;\n",
      "pages/index.html": '<html><head><link rel="stylesheet" href="site.css"></head><body><h1 class="hero">Working HTML preview</h1><script>parent.gitrochiPreviewRan = true</script><a href="https://example.invalid" target="_top">Link</a></body></html>',
      "pages/site.css": ".hero { color: rgb(23, 45, 67); }",
      "README.md": "# Preview documentation\n\nRendered documentation.\n",
    };
    const previewSource: RepositoryCodeSource = {
      tree: async () => ({ revision: a, entries: Object.entries(previewFiles).map(([path, text]) => ({ path, size: text.length, oid: b, mode: "100644", kind: "file" })), truncated: false }),
      blob: async (_repo, entry) => ({ text: previewFiles[entry.path] }), read: async () => "",
    };
    let listCalls = 0, delayEditors = false;
    const availableEditors: Awaited<ReturnType<RepositoryEditorSource["list"]>> = [{ id: "system", name: "System default", available: true, supportsFolders: true }, { id: "vscode", name: "Visual Studio Code", available: true, supportsFolders: true }, { id: "notepad", name: "Notepad", available: false, supportsFolders: false }];
    let releaseEditors: ((value: typeof availableEditors) => void) | undefined;
    const launches: { repo: string; editor: string; file?: string }[] = [];
    const editorSource: RepositoryEditorSource = {
      list: async () => { listCalls++; return delayEditors ? new Promise<typeof availableEditors>((resolve) => { releaseEditors = resolve; }) : availableEditors; },
      open: async (repo, editor, file) => { launches.push({ repo, editor, file }); },
    };
    await mount(<RepositoryCodePanel store={store} source={previewSource} editorSource={editorSource}/>);
    await waitFor(() => host.querySelector("pre")?.textContent?.includes("Preview documentation"), "Language/editor fixture did not open its README");
    await quickSelect("Card.tsx"); await waitFor(() => status().includes("TypeScript"), "The status bar did not normalize TSX to its language");
    await click("Languages");
    const languageButton = [...host.querySelectorAll<HTMLButtonElement>(".code-language-legend button")].find((button) => button.querySelector("span")?.textContent === "TypeScript");
    check(languageButton?.textContent?.includes("40"), "Language composition was not counted by tracked files"); languageButton!.click(); await pause();
    check(host.querySelectorAll(".code-file-row.folder").length === 1 && host.querySelector(".code-file-row.folder")?.textContent === "src", "Language filter did not derive its folders from matching files");
    [...host.querySelectorAll<HTMLButtonElement>(".code-file-row.folder")].find((row) => row.textContent === "src")!.click(); await pause(); check(host.querySelectorAll(".code-file-row:not(.folder)").length === 2, "Language filter did not show matching source files");
    host.querySelector<HTMLButtonElement>(".code-file-row.parent")!.click(); await pause();
    check(!host.querySelector(".code-file-row.parent") && host.querySelector(".code-file-row.folder")?.textContent === "src", "The .. row did not go up to the parent folder");
    await click("All languages"); check([...host.querySelectorAll(".code-file-row.folder")].some((folder) => folder.textContent === "pages"), "All languages did not clear the file filter");
    host.querySelector<HTMLElement>(".code-external-editors summary")!.click();
    await waitFor(() => host.querySelectorAll(".code-editor-section").length === 2 && host.querySelector(".code-editor-section")?.querySelectorAll("button").length === availableEditors.length && !host.querySelector(".code-editor-menu .spinner"), "Editor discovery did not render file and repository choices");
    const appButton = (sectionIndex: number) => [...host.querySelectorAll(".code-editor-section")][sectionIndex]?.querySelectorAll<HTMLButtonElement>("button") ?? [];
    const fileChoices = [...appButton(0)];
    check(fileChoices.find((button) => button.textContent?.includes("Notepad"))?.disabled, "Unavailable editor must remain disabled");
    fileChoices.find((button) => button.textContent?.trim() === "Visual Studio Code")!.click(); await pause();
    check(launches[0]?.repo === store.path && launches[0]?.file === "src/Card.tsx" && launches[0]?.editor === "vscode", "Open file did not send the current working-copy path to the native adapter");
    host.querySelector<HTMLElement>(".code-external-editors summary")!.click(); await pause();
    [...appButton(1)].find((button) => button.textContent?.trim() === "Visual Studio Code")!.click(); await pause();
    check(launches[1]?.file === undefined && launches[1]?.repo === store.path, "Open repository incorrectly sent a preview file");
    host.querySelector<HTMLElement>(".code-external-editors summary")!.click(); await click("Refresh applications");
    check(listCalls === 2, "Refresh applications did not query native availability again");
    delayEditors = true; await click("Refresh applications");
    check(host.querySelector(".code-editor-menu .spinner"), "Delayed application refresh did not show loading");
    await quickSelect("index.html"); await waitFor(() => host.querySelector("pre")?.textContent?.includes("Working HTML preview"), "HTML source did not load");
    host.querySelector<HTMLElement>(".code-external-editors summary")!.click(); await pause();
    check(!host.querySelector(".code-editor-menu .spinner") && appButton(0).length === 3, "Changing files left editor discovery stuck loading");
    check(releaseEditors, "Delayed editor fixture did not start"); releaseEditors!([]); await pause();
    check(appButton(0).length === 3, "Stale editor discovery replaced the current choices");
    host.querySelector<HTMLElement>(".code-external-editors summary")!.click();
    await tab("Preview");
    await waitFor(() => host.querySelector<HTMLIFrameElement>(".code-html-preview iframe")?.srcdoc.includes("Working HTML preview"), "HTML Preview did not assemble a rendered document");
    const frame = host.querySelector<HTMLIFrameElement>(".code-html-preview iframe")!;
    check(frame.getAttribute("sandbox") === "" && frame.referrerPolicy === "no-referrer", "HTML Preview must remain opaque and script-free");
    const rendered = new DOMParser().parseFromString(frame.srcdoc, "text/html");
    check(!rendered.querySelector("script, a[href]") && rendered.querySelector("style")?.textContent?.includes("rgb(23, 45, 67)"), "HTML Preview did not isolate scripts/navigation or include committed CSS");
    await control("Navigate back"); await waitFor(() => host.querySelector("pre")?.textContent?.includes("Working HTML preview"), "History did not preserve HTML source mode");
    await control("Navigate forward"); await waitFor(() => host.querySelector(".code-html-preview iframe"), "History did not preserve HTML Preview mode");
    await quickSelect("README.md"); await waitFor(() => host.querySelector("pre")?.textContent?.includes("Preview documentation"), "Markdown source did not open");
    await tab("Preview"); await waitFor(() => host.querySelector(".code-markdown-preview h1")?.textContent === "Preview documentation", "Markdown Preview did not render the document");
    reset(); store.headHash=a;store.headBranch="topic";store.repoState="clean";
    let previewReads=0;const summary=async()=>{previewReads++;return{base:b,head:a,incoming:3,replay:2,commits:[{id:a,subject:"Newest fixture commit"},{id:b,subject:"Oldest fixture commit"}]};};
    const fixtureBases=async()=>[{name:"main",kind:"branch" as const,incoming:3},{name:"v1.0",kind:"tag" as const,incoming:0}];
    await mount(<RebaseWorkbenchPanel store={store} previewSource={summary} basesSource={fixtureBases}/>);await new Promise(resolve=>setTimeout(resolve,350));
    check(previewReads===1&&host.textContent?.includes("Newest fixture commit")&&host.textContent?.includes(t("{0} commits replay on top of {1}, newest first.",2,"main")),"Rebase first screen did not load the commits that replay");
    check(!host.querySelector("h1, h2.workbench-heading, .workbench-heading") && host.querySelector(".rebase-route strong")?.textContent==="topic", "Rebase must name the current branch in its bar without a page title");
    const options=[...host.querySelectorAll<HTMLButtonElement>(".rebase-option")];
    check(options.length===2&&options[0].getAttribute("aria-selected")==="true"&&options[0].textContent?.includes(t("{0} new commits",3))&&options[1].disabled&&options[1].textContent?.includes(t("Already in this branch")),"Rebase must list the bases with their new commits and disable what is already in the branch");
    check(host.querySelectorAll(".rebase-commits li").length===2&&!store.confirm,"Opening rebase must only preview commits");
    // the commit clean-up sheet caps its own list; the page's column must not share that rule
    check(getComputedStyle(host.querySelector(".rebase-column")!).maxHeight==="none","The Rebase list column must fill the page height");
    reset(); store.repoState = "rebasing"; store.continueOperation = async () => { rebases++; }; await mount(<RebaseWorkbenchPanel store={store}/>); await click("Continue"); check(rebases === 1 && host.textContent?.includes(t("Abort…")), "In-progress rebase controls missing");
    return [true, "Compare, source reading/navigation, immutable language composition/filtering, injected working-copy editors, isolated HTML/CSS/raster and Markdown previews, DOM security/resource budgets, stale requests, revision resets and rebase controls rendered"];
  } catch (error) { return [false, error instanceof Error ? error.message : String(error)]; }
  finally { root.unmount(); host.remove(); store.cancelHistoryTools(); }
}
