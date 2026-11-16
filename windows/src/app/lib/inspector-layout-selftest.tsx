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
 * The commit inspector as the flat panel: the 44 px header (short SHA, copy, the commit menu under ⋯), the one-line
 * author, parents as links, New branch… and Tag…, and long references, names and parents kept inside a narrow panel.
 */
export async function inspectorLayoutSelfTest(): Promise<[boolean, string]> {
  const original = { get: settings.get, set: settings.set, run: ipc.run, http: ipc.http };
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
  const copied: string[] = [], revealed: string[] = [];
  const one = <T extends HTMLElement = HTMLElement>(selector: string) => host.querySelector<T>(selector);
  const button = (label: string) => [...host.querySelectorAll<HTMLButtonElement>(".commit-main button")].find((item) => item.textContent === label);
  const menu = () => document.querySelector<HTMLElement>(".menu");
  const closeMenu = () => window.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape" }));
  try {
    settings.get = <T,>(key: string, fallback: T): T => (memory.has(key) ? memory.get(key) : fallback) as T;
    settings.set = (key, value) => { memory.set(key, value); };
    ipc.run = async () => { unexpected.push("process"); throw new Error("Fixture blocked process"); };
    ipc.http = async () => { unexpected.push("network"); throw new Error("Fixture blocked network"); };
    store.copy = (text) => { copied.push(text); };
    store.reveal = (target) => { revealed.push(target); };
    store.path = "C:/gitrochi-inspector-layout-fixture";
    store.selection = { kind: "commit", sha };
    store.detail = { sha, parents, author, email, date: 1792974000, committer: "VeryLongCommitter".repeat(30), committerEmail: email, commitDate: 1792977600, summary, body: "UnbrokenBodyIdentifier".repeat(50) };
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
      const controls = [...host.querySelectorAll<HTMLElement>(".commit-head > *:not(.spacer), .commit-ref, .commit-title, .commit-author, .commit-committer, .commit-body, .panel-scroll button, .commit-files-head > *:not(.spacer), .file-row")];
      const bounded = controls.every((element) => { const rect = element.getBoundingClientRect(); return rect.width > 0 && rect.left >= bounds.left - 1 && rect.right <= bounds.right + 1; });
      const main = one(".commit-main")!, mainBounds = main.getBoundingClientRect(), mainStyle = getComputedStyle(main);
      const content = { left: mainBounds.left + Number.parseFloat(mainStyle.paddingLeft), right: mainBounds.right - Number.parseFloat(mainStyle.paddingRight) };
      const line = one(".commit-author")!;
      const authorLine = authorLineFits(content, line.querySelector(".avatar")!.getBoundingClientRect(), one(".commit-author-name")!.getBoundingClientRect(),
        one(".commit-author-when")!.getBoundingClientRect(), Number.parseFloat(getComputedStyle(line).columnGap));
      widths.push({ width, bounded, authorLine, scrollbarWidth: panel.offsetWidth - panel.clientWidth, scrollWidth: panel.scrollWidth, contentWidth: panel.clientWidth });
    }

    // the board's flat panel: no cards, a 44 px header with 16 px sides, a 17 px semibold title
    const head = one(".commit-head")!, headStyle = getComputedStyle(head), titleStyle = getComputedStyle(one(".commit-title")!), mainStyle = getComputedStyle(one(".commit-main")!);
    const flat = !one(".commit-detail .card") && Math.round(head.getBoundingClientRect().height) === 44 && headStyle.paddingLeft === "16px" && headStyle.paddingRight === "16px"
      && titleStyle.fontSize === "17px" && titleStyle.fontWeight === "600" && mainStyle.padding === "12px 16px 16px";
    const headWords = one(".commit-head h2")?.textContent === t("Merge commit") && one(".commit-head-sha")?.textContent === sha.slice(0, 7);

    const refs = [...host.querySelectorAll<HTMLElement>(".commit-ref")];
    const refNames = [branch, "origin/" + branch];
    const fullNamesAvailable = refs.length === 2 && refs.every((element, index) => element.title === refNames[index] && element.dataset.tip === refNames[index]);
    // the email and the exact date stay one hover away; the committer has its own quiet line
    const name = one(".commit-author-name"), when = one(".commit-author-when");
    const identityAvailable = name?.textContent === author && !!name.title.includes(email) && !!when?.title && when.scrollWidth <= when.clientWidth
      && !!one(".commit-committer")?.textContent?.includes("VeryLongCommitter");
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

    // the explanation: shown under the provider's name with "Explain again", and a failure in the shared block
    const explanationShown = !!one(".commit-explanation")?.textContent?.includes("LongExplanationIdentifier") && !!button(t("Explain again")) && !button(t("Explain with AI…"));
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

    const ok = widths.every((item) => item.bounded && item.authorLine && item.scrollWidth <= item.contentWidth + 1) && flat && headWords && fullNamesAvailable && identityAvailable
      && titleAvailable && parentsAvailable && copyWorks && menuWorks && actionsWork && explanationShown && failureShown && explainOffered && unexpected.length === 0;
    return [ok, JSON.stringify({ widths, flat, headWords, fullNamesAvailable, identityAvailable, titleAvailable, parentsAvailable, copyWorks, menuWorks, opened, menuItems, branchSheet, tagSheet, blocked, explanationShown, failureShown, explainOffered, unexpected })];
  } finally {
    // an open menu would take the keyboard from every later step
    if (menu()) { closeMenu(); await until(() => !menu(), 500); }
    root.unmount(); await pause(20); host.remove();
    settings.get = original.get; settings.set = original.set; ipc.run = original.run; ipc.http = original.http;
  }
}
