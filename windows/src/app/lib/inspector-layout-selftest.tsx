import { createRoot } from "react-dom/client";
import { RepoStore } from "@/entities/repo";
import { Inspector } from "@/widgets/inspector";
import { ipc } from "@/shared/api";
import { settings } from "@/shared/config";
import { t } from "@/shared/i18n";
import { authorLineFits } from "./inspector-layout-geometry";

const pause = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));
const frames = () => new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve())));
const until = async (done: () => boolean, ms = 2500) => {
  const end = Date.now() + ms;
  while (!done() && Date.now() < end) await pause(20);
  return done();
};

/**
 * The commit inspector as the board's flat panel: a header as tall as the graph's (short SHA, copy, the commit menu under ⋯), the one-line
 * author with the committer on its hover, the trailer rows, parents as links, New branch… and Tag…, nothing the board does not draw (ref
 * chips, a committer line, line totals, an explanation caption), and long names, titles and parents kept inside a narrow panel.
 */
export async function inspectorLayoutSelfTest(): Promise<[boolean, string]> {
  const original = { get: settings.get, set: settings.set, run: ipc.run, http: ipc.http, openUrl: ipc.openUrl };
  const memory = new Map<string, unknown>([["avatarFetch", false], ["fileViewMode", "list"]]);
  const unexpected: string[] = [];
  const host = document.createElement("div");
  Object.assign(host.style, { position: "fixed", left: "-10000px", top: "0", width: "240px", height: "900px", display: "flex", visibility: "hidden" });
  document.body.append(host);
  const root = createRoot(host), store = new RepoStore(), sha = "a".repeat(40);
  const branch = "codex/" + "long-unbroken-feature-name-".repeat(12);
  const author = "긴 작성자 이름 Alexander Repository Contributor", email = "very-long-author-".repeat(12) + "@example.invalid";
  const summary = "커밋 제목 첫 글자를 보존합니다 — " + "Long summary for compact inspector validation. ".repeat(5);
  const parents = ["b".repeat(40), "c".repeat(40), "d".repeat(40), "e".repeat(40)];
  const widths: { width: number; bounded: boolean; authorLine: boolean; scrollbarWidth: number; scrollWidth: number; contentWidth: number }[] = [];
  const copied: string[] = [], revealed: string[] = [], openedPages: string[] = [];
  const coAuthor = { name: "Samantha Co-Author With A Very Long Display Name", email: "sam@example.invalid", line: "Co-authored-by: Samantha Co-Author With A Very Long Display Name <sam@example.invalid>" };
  const issueTitle = "Make workspace search easier to use in very narrow panels and long titles";
  const one = <T extends HTMLElement = HTMLElement>(selector: string) => host.querySelector<T>(selector);
  const button = (label: string) => [...host.querySelectorAll<HTMLButtonElement>(".commit-main button")].find((item) => item.textContent === label);
  const menu = () => document.querySelector<HTMLElement>(".menu");
  const closeMenu = () => window.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape" }));
  try {
    settings.get = <T,>(key: string, fallback: T): T => (memory.has(key) ? memory.get(key) : fallback) as T;
    settings.set = (key, value) => { memory.set(key, value); };
    ipc.run = async () => { unexpected.push("process"); throw new Error("Fixture blocked process"); };
    ipc.http = async () => { unexpected.push("network"); throw new Error("Fixture blocked network"); };
    ipc.openUrl = async (url) => { openedPages.push(url); };
    store.copy = (text) => { copied.push(text); };
    store.reveal = (target) => { revealed.push(target); };
    store.path = "C:/gitrochi-inspector-layout-fixture";
    store.selection = { kind: "commit", sha };
    store.detail = { sha, parents, author, email, date: 1792974000, committer: "VeryLongCommitter".repeat(30), committerEmail: "committer@example.invalid", commitDate: 1792977600, summary, body: "UnbrokenBodyIdentifier".repeat(50), prose: "UnbrokenBodyIdentifier".repeat(50),
      trailers: { issues: [{ keyword: "closes", number: 42 }, { keyword: "fixes", number: 7 }], coAuthors: [coAuthor] } };
    // no account: the issue rows have no title and nothing asks the server; the page they open is the server's
    store.target = { provider: "github", remote: "origin", host: "git.example.invalid", path: "o/r" };
    store.refsByCommit = new Map([[sha, [{ name: branch, kind: "local", isCurrent: true }, { name: "origin/" + branch, kind: "remote", isCurrent: false }]]]);
    store.explanations[sha] = "LongExplanationIdentifier".repeat(40);
    const path = "docs/" + "nested-long-folder/".repeat(8) + "report.md";
    store.detailFiles = [{ path, oldPath: null, staged: true, kind: "modified" }];
    store.detailStats = { [path]: { added: 123456, deleted: 98765 } };
    root.render(<Inspector store={store} />);
    if (!await until(() => !!one(".commit-detail .commit-head"))) return [false, "Commit detail did not mount"];

    for (const width of [240, 280, 320, 340]) {
      host.style.width = `${width}px`;
      await frames();
      const panel = one(".panel-scroll")!, bounds = host.getBoundingClientRect();
      const controls = [...host.querySelectorAll<HTMLElement>(".commit-head > *:not(.spacer), .commit-title, .commit-author, .commit-body, .commit-trailer, .commit-trailer > *, .panel-scroll button, .commit-files-head > *:not(.spacer), .file-row")];
      const bounded = controls.every((element) => { const rect = element.getBoundingClientRect(); return rect.width > 0 && rect.left >= bounds.left - 1 && rect.right <= bounds.right + 1; });
      const main = one(".commit-main")!, mainBounds = main.getBoundingClientRect(), mainStyle = getComputedStyle(main);
      const content = { left: mainBounds.left + Number.parseFloat(mainStyle.paddingLeft), right: mainBounds.right - Number.parseFloat(mainStyle.paddingRight) };
      const line = one(".commit-author")!;
      const authorLine = authorLineFits(content, line.querySelector(".avatar")!.getBoundingClientRect(), one(".commit-author-name")!.getBoundingClientRect(),
        one(".commit-author-when")!.getBoundingClientRect(), Number.parseFloat(getComputedStyle(line).columnGap));
      widths.push({ width, bounded, authorLine, scrollbarWidth: panel.offsetWidth - panel.clientWidth, scrollWidth: panel.scrollWidth, contentWidth: panel.clientWidth });
    }

    // the board's flat panel: no cards, a header as tall as the graph's (35 px with its divider) with 16 px sides, a 17 px semibold title
    const head = one(".commit-head")!, headStyle = getComputedStyle(head), titleStyle = getComputedStyle(one(".commit-title")!), mainStyle = getComputedStyle(one(".commit-main")!);
    const flat = !one(".commit-detail .card") && Math.round(head.getBoundingClientRect().height) === 35 && headStyle.paddingLeft === "16px" && headStyle.paddingRight === "16px"
      && titleStyle.fontSize === "17px" && titleStyle.fontWeight === "600" && mainStyle.padding === "14px 16px 16px";
    const headWords = one(".commit-head h2")?.textContent === t("Merge commit") && one(".commit-head-sha")?.textContent === sha.slice(0, 7);

    // what the board does not draw is gone: the commit's refs are on its graph row, the totals on the file rows
    const boardOnly = !one(".commit-ref, .commit-refs, .commit-committer, .commit-files-totals, .commit-explanation-by") && !host.textContent?.includes(branch);
    // the email and the exact date stay one hover away, and so does a committer who is not the author: no line of its own
    const name = one(".commit-author-name"), when = one(".commit-author-when");
    const identityAvailable = name?.textContent === author && !!name.title.includes(email) && !!when?.title && when.scrollWidth <= when.clientWidth
      && when.title.includes("VeryLongCommitter") && when.title.includes("committer@example.invalid") && when.dataset.tip === when.title
      && one(".commit-author")?.nextElementSibling?.classList.contains("commit-body") === true;

    // the board's trailer rows, 24 px each and 4 apart, between the body and the parents
    const group = one(".commit-trailers"), rows = [...host.querySelectorAll<HTMLElement>(".commit-trailer")];
    const issueRows = [...host.querySelectorAll<HTMLButtonElement>(".commit-trailer-issue")], authorRow = one(".commit-trailer-author");
    const rowBoxes = rows.map((row) => row.getBoundingClientRect());
    const trailerRows = group?.getAttribute("role") === "group" && group.getAttribute("aria-label") === t("Trailers") && rows.length === 3
      && rowBoxes.every((box) => Math.round(box.height) === 24) && rowBoxes.slice(1).every((box, index) => Math.round(box.top - rowBoxes[index].bottom) === 4)
      && group.previousElementSibling?.matches(".commit-body, .commit-text-button") === true && group.nextElementSibling?.classList.contains("commit-parents") === true
      && getComputedStyle(group).marginTop === "12px";
    const issueWords = issueRows.length === 2 && issueRows[0].querySelector(".commit-trailer-verb")?.textContent === t("Closes")
      && issueRows[1].querySelector(".commit-trailer-verb")?.textContent === t("Fixes")
      && issueRows[0].querySelector(".commit-trailer-number")?.textContent === "#42" && !issueRows[0].querySelector(".commit-trailer-title");
    const coAuthorRow = authorRow?.title === coAuthor.line && authorRow.querySelector(".ellipsis")?.textContent === coAuthor.name
      && authorRow.querySelector(".status-pill")?.textContent === t("Co-author") && Math.round(authorRow.querySelector(".avatar")!.getBoundingClientRect().width) === 16;
    issueRows[0]?.click();
    const issueOpens = openedPages.join() === "https://git.example.invalid/o/r/issues/42";
    // a title that was read: cut with an ellipsis inside the row, whole on hover; one for another commit's issue is never shown
    const known = store.trailerIssue;
    store.trailerIssue = (number) => number === 42 ? { id: "issue-42", kind: "issue", number: 42, title: issueTitle, url: "", body: "", state: "open", updated: null, author: "", unread: false } : null;
    store.changed();
    await frames();
    const titled = host.querySelector<HTMLButtonElement>(".commit-trailer-issue"), titleBox = titled?.querySelector<HTMLElement>(".commit-trailer-title");
    const issueTitled = titleBox?.textContent === issueTitle && titled?.title === issueTitle && titleBox.scrollWidth > titleBox.clientWidth
      && titled.getBoundingClientRect().right <= host.getBoundingClientRect().right + 1 && !!titled.querySelector("svg.commit-trailer-open")
      && host.querySelectorAll(".commit-trailer-title").length === 1;
    store.trailerIssue = known;
    store.changed();
    await frames();
    const titleAvailable = one(".commit-title")?.textContent === summary;
    const parentLinks = [...host.querySelectorAll<HTMLButtonElement>(".commit-parent")];
    parentLinks[1]?.click();
    const parentsAvailable = parentLinks.length === 4 && parentLinks.every((link, index) => link.textContent === parents[index].slice(0, 7))
      && one(".commit-parents .commit-caption")?.textContent === t("Parents") && revealed.join() === parents[1];

    one<HTMLButtonElement>(`.commit-head [aria-label="${t("Copy commit SHA")}"]`)?.click();
    const copyWorks = copied.join() === sha;
    // ⋯ is the graph row's own menu, and Escape puts it away again
    const more = one<HTMLButtonElement>(`.commit-head [aria-label="${t("More commit actions")}"]`);
    more?.click();
    const opened = await until(() => !!menu());
    const labels = [...document.querySelectorAll(".menu .menu-item .label")].map((item) => item.textContent);
    const menuItems = [t("New branch from here…"), t("Tag here…"), t("Cherry-pick"), t("Copy SHA"), t("Copy message")].every((label) => labels.includes(label));
    closeMenu();
    const menuWorks = more?.getAttribute("aria-haspopup") === "menu" && opened && menuItems && await until(() => !menu());

    button(t("New branch…"))?.click();
    await frames();
    const branchSheet = store.sheet?.kind === "newBranch" && store.sheet.start === sha;
    button(t("Tag…"))?.click();
    await frames();
    const tagSheet = store.sheet?.kind === "tag" && store.sheet.sha === sha;
    store.sheet = null;
    // a running command blocks both buttons, and their tip says which
    store.busy = "Fixture command";
    store.changed();
    await frames();
    const blocked = [t("New branch…"), t("Tag…")].every((label) => button(label)?.disabled === true && button(label)?.dataset.tip === "Fixture command");
    store.busy = null;
    store.changed();
    await frames();
    const actionsWork = branchSheet && tagSheet && blocked && button(t("New branch…"))?.disabled === false;

    // the explanation: under "Explain again" in the body's type with no caption, and a failure in the shared block
    const again = button(t("Explain again")), shown = one(".commit-explanation");
    const explanationShown = !!shown?.textContent?.startsWith("LongExplanationIdentifier") && !!again && !button(t("Explain with AI…"))
      && !!(again.compareDocumentPosition(shown) & Node.DOCUMENT_POSITION_FOLLOWING) && getComputedStyle(shown).fontSize === "13px";
    store.explainFailures = { [sha]: "Fixture failure" };
    store.changed();
    await frames();
    const failureShown = one(".commit-explain-failure")?.getAttribute("role") === "alert" && !!one(".commit-explain-failure")?.textContent?.includes(t("Couldn't explain this commit"))
      && !button(t("Explain again"));
    store.explainFailures = {};
    store.explanations = {};
    store.changed();
    await frames();
    const explainOffered = !!button(t("Explain with AI…")) && !one(".commit-explanation");

    const ok = widths.every((item) => item.bounded && item.authorLine && item.scrollWidth <= item.contentWidth + 1) && flat && headWords && boardOnly && identityAvailable
      && trailerRows && issueWords && coAuthorRow && issueOpens && issueTitled && titleAvailable && parentsAvailable && copyWorks && menuWorks && actionsWork && explanationShown && failureShown && explainOffered && unexpected.length === 0;
    return [ok, JSON.stringify({ widths, flat, headWords, boardOnly, identityAvailable, trailerRows, issueWords, coAuthorRow, issueOpens, openedPages, issueTitled, titleAvailable, parentsAvailable, copyWorks, menuWorks, opened, menuItems, branchSheet, tagSheet, blocked, explanationShown, failureShown, explainOffered, unexpected })];
  } finally {
    // an open menu would take the keyboard from every later step
    if (menu()) { closeMenu(); await until(() => !menu(), 500); }
    root.unmount(); await pause(20); host.remove();
    settings.get = original.get; settings.set = original.set; ipc.run = original.run; ipc.http = original.http; ipc.openUrl = original.openUrl;
  }
}
